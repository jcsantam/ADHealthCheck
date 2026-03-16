<#
.SYNOPSIS
    Time Correction Rate / Phase Offset Check (TIME-008)

.DESCRIPTION
    Checks the current phase offset (time correction pending) on each reachable
    domain controller using w32tm /query /status. A large phase offset indicates
    the clock is significantly out of sync and W32Time is working to correct it.

    If the offset exceeds 60 seconds, Kerberos authentication is at risk.
    If the offset exceeds 1 second, it is worth investigating.

    Checks:
    - |PhaseOffset| > 1 second → Warning (Medium)
    - |PhaseOffset| > 60 seconds → Fail (High)

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-TimeCorrectionRate.ps1 -Inventory $inventory

.OUTPUTS
    Array of phase offset results per DC

.NOTES
    Check ID: TIME-008
    Category: Time
    Severity: High
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[TIME-008] Starting time correction rate (phase offset) check..."

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[TIME-008] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[TIME-008] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[TIME-008] Checking phase offset on: $dcName"

        try {
            $w32tmStatus = w32tm /query /computer:$dcName /status 2>&1

            # Parse Phase Offset
            # w32tm outputs phase offset in seconds with decimal, e.g. "Phase Offset: 0.1234567s"
            # It may also show nanoseconds notation on some OS versions
            $phaseOffsetSeconds = $null
            $offsetLine = $w32tmStatus | Where-Object { $_ -match 'Phase Offset:' }
            if ($offsetLine -match 'Phase Offset:\s*([-+]?[\d.]+)\s*s') {
                $phaseOffsetSeconds = [double]$matches[1]
            }
            elseif ($offsetLine -match 'Phase Offset:\s*([-+]?[\d.]+)\s*ns') {
                # Convert nanoseconds to seconds
                $phaseOffsetSeconds = [double]$matches[1] / 1000000000.0
            }
            elseif ($offsetLine -match 'Phase Offset:\s*([-+]?[\d.]+)') {
                # Assume seconds if no unit
                $phaseOffsetSeconds = [double]$matches[1]
            }

            # Parse ReferenceId
            $referenceId = 'Unknown'
            $refLine = $w32tmStatus | Where-Object { $_ -match 'ReferenceId:' }
            if ($refLine -match 'ReferenceId:\s*(.+)') {
                $referenceId = $matches[1].Trim()
            }

            # Parse Root Delay
            $rootDelaySeconds = $null
            $rootDelayLine = $w32tmStatus | Where-Object { $_ -match 'Root Delay:' }
            if ($rootDelayLine -match 'Root Delay:\s*([-+]?[\d.]+)\s*s') {
                $rootDelaySeconds = [double]$matches[1]
            }
            elseif ($rootDelayLine -match 'Root Delay:\s*([-+]?[\d.]+)') {
                $rootDelaySeconds = [double]$matches[1]
            }

            if ($phaseOffsetSeconds -eq $null) {
                # Phase Offset line is absent when the DC is a primary time source (stratum 1 / local clock)
                # This is normal — treat as zero offset
                $sourceLine = $w32tmStatus | Where-Object { $_ -match '^Source:' }
                $isLocalClock = ($sourceLine -match 'Local CMOS|LOCL|Free-running')
                if ($isLocalClock -or $referenceId -match 'LOCL') {
                    $phaseOffsetSeconds = 0.0
                } else {
                    $results += [PSCustomObject]@{
                        DomainController   = $dcName
                        PhaseOffsetSeconds = $null
                        ReferenceId        = $referenceId
                        RootDelaySeconds   = $rootDelaySeconds
                        HasIssue           = $false
                        Status             = 'Pass'
                        Severity           = 'Info'
                        IsHealthy          = $true
                        Message            = "DC $dcName - Phase Offset not reported by w32tm (source: $referenceId)"
                    }
                    continue
                }
            }

            $absOffset = [math]::Abs($phaseOffsetSeconds)
            $hasIssue = $false
            $status = 'Pass'
            $severity = 'Info'
            $message = ''

            if ($absOffset -gt 60) {
                $hasIssue = $true
                $status = 'Fail'
                $severity = 'High'
                $message = "DC $dcName phase offset is $([math]::Round($phaseOffsetSeconds, 4))s -exceeds 60s threshold; Kerberos authentication may fail"
            }
            elseif ($absOffset -gt 1) {
                $hasIssue = $true
                $status = 'Warning'
                $severity = 'Medium'
                $message = "DC $dcName phase offset is $([math]::Round($phaseOffsetSeconds, 4))s -exceeds 1s; monitor for further drift"
            }
            else {
                $message = "DC $dcName phase offset is $([math]::Round($phaseOffsetSeconds, 4))s -within acceptable range"
            }

            $results += [PSCustomObject]@{
                DomainController   = $dcName
                PhaseOffsetSeconds = [math]::Round($phaseOffsetSeconds, 6)
                ReferenceId        = $referenceId
                RootDelaySeconds   = $rootDelaySeconds
                HasIssue           = $hasIssue
                Status             = $status
                Severity           = $severity
                IsHealthy          = -not $hasIssue
                Message            = $message
            }
        }
        catch {
            Write-Warning "[TIME-008] Failed to query phase offset on DC ${dcName}: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController   = $dcName
                PhaseOffsetSeconds = $null
                ReferenceId        = 'Unknown'
                RootDelaySeconds   = $null
                HasIssue           = $true
                Status             = 'Error'
                Severity           = 'Error'
                IsHealthy          = $false
                Message            = "Failed to query phase offset: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[TIME-008] Check complete. DCs checked: $($results.Count)"
    return $results
}
catch {
    Write-Error "[TIME-008] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController   = 'Unknown'
        PhaseOffsetSeconds = $null
        ReferenceId        = 'Unknown'
        RootDelaySeconds   = $null
        HasIssue           = $true
        Status             = 'Error'
        Severity           = 'Error'
        IsHealthy          = $false
        Message            = "Check execution failed: $($_.Exception.Message)"
    })
}
