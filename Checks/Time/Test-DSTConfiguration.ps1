<#
.SYNOPSIS
    Daylight Saving Time Configuration Check (TIME-010)

.DESCRIPTION
    Checks daylight saving time (DST) configuration across all reachable domain
    controllers. DCs configured for UTC have no DST (DaylightBias=0), which is
    the recommended configuration to avoid time jumps that can disrupt services.

    Inconsistent DST settings across DCs (e.g., some have DST, some do not) can
    cause confusing log timestamps and should be flagged.

    Checks:
    - DST settings are consistent across all DCs
    - DCs use UTC (no DST) -informational advisory if not

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-DSTConfiguration.ps1 -Inventory $inventory

.OUTPUTS
    Array of DST configuration results per DC

.NOTES
    Check ID: TIME-010
    Category: Time
    Severity: Medium
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[TIME-010] Starting DST configuration check..."

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[TIME-010] No domain controllers found in inventory"
        return @()
    }

    # First pass: collect DST info for all reachable DCs
    $dstData = @()

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[TIME-010] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[TIME-010] Querying DST configuration on: $dcName"

        try {
            $tz = Get-WmiObject -Class Win32_TimeZone -ComputerName $dc.Name -ErrorAction SilentlyContinue

            if (-not $tz) {
                $dstData += [PSCustomObject]@{
                    DomainController = $dcName
                    TimeZone         = 'Unknown'
                    DaylightName     = 'Unknown'
                    DaylightBias     = $null
                    DaylightDay      = $null
                    HasDST           = $false
                    IsUTC            = $false
                    QueryOk          = $false
                }
                continue
            }

            # HasDST: true if DaylightBias is non-zero or DaylightDay is non-zero
            # For UTC zones, DaylightBias=0 and DaylightDay=0 meaning no DST transition occurs
            $hasDST = $false
            if ($tz.DaylightBias -ne 0) {
                $hasDST = $true
            }
            elseif ($tz.DaylightDay -ne $null -and $tz.DaylightDay -ne 0) {
                $hasDST = $true
            }

            $isUTC = ($tz.Bias -eq 0 -and -not $hasDST)

            $dstData += [PSCustomObject]@{
                DomainController = $dcName
                TimeZone         = $tz.StandardName
                DaylightName     = $tz.DaylightName
                DaylightBias     = $tz.DaylightBias
                DaylightDay      = $tz.DaylightDay
                HasDST           = $hasDST
                IsUTC            = $isUTC
                QueryOk          = $true
            }
        }
        catch {
            Write-Warning "[TIME-010] Failed to query DST config on DC ${dcName}: $($_.Exception.Message)"
            $dstData += [PSCustomObject]@{
                DomainController = $dcName
                TimeZone         = 'Unknown'
                DaylightName     = 'Unknown'
                DaylightBias     = $null
                DaylightDay      = $null
                HasDST           = $false
                IsUTC            = $false
                QueryOk          = $false
            }
        }
    }

    if ($dstData.Count -eq 0) {
        Write-Warning "[TIME-010] No DC DST data collected"
        return @()
    }

    # Determine DST consistency across DCs (only among successfully queried DCs)
    $successfulData = $dstData | Where-Object { $_.QueryOk -eq $true }
    $uniqueDSTStates = $successfulData | Select-Object -ExpandProperty HasDST -Unique
    $dstConsistent = ($uniqueDSTStates.Count -le 1)

    # Second pass: build result objects
    foreach ($entry in $dstData) {
        if (-not $entry.QueryOk) {
            $results += [PSCustomObject]@{
                DomainController = $entry.DomainController
                TimeZone         = 'Unknown'
                DaylightName     = 'Unknown'
                DaylightBias     = $null
                HasDST           = $false
                IsUTC            = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to retrieve DST configuration from $($entry.DomainController)"
            }
            continue
        }

        $hasIssue = $false
        $status = 'Pass'
        $severity = 'Info'
        $message = ''

        if (-not $dstConsistent) {
            $hasIssue = $true
            $status = 'Fail'
            $severity = 'Medium'
            if ($entry.HasDST) {
                $message = "DC $($entry.DomainController) has DST enabled -inconsistent with other DCs that do not use DST"
            }
            else {
                $message = "DC $($entry.DomainController) has no DST -inconsistent with other DCs that have DST enabled"
            }
        }
        elseif (-not $entry.IsUTC -and $entry.HasDST) {
            # Consistent but non-UTC with DST -informational
            $hasIssue = $true
            $status = 'Warning'
            $severity = 'Low'
            $message = "DC $($entry.DomainController) uses '$($entry.TimeZone)' with DST (DaylightName: $($entry.DaylightName), Bias: $($entry.DaylightBias) min) -UTC is recommended for DCs to avoid DST-related time jumps"
        }
        elseif (-not $entry.IsUTC -and -not $entry.HasDST) {
            # Non-UTC but no DST -informational only
            $hasIssue = $false
            $status = 'Pass'
            $severity = 'Info'
            $message = "DC $($entry.DomainController) uses '$($entry.TimeZone)' without DST -UTC is recommended but this is acceptable"
        }
        else {
            $message = "DC $($entry.DomainController) is configured to UTC with no DST -recommended configuration"
        }

        $results += [PSCustomObject]@{
            DomainController = $entry.DomainController
            TimeZone         = $entry.TimeZone
            DaylightName     = $entry.DaylightName
            DaylightBias     = $entry.DaylightBias
            HasDST           = $entry.HasDST
            IsUTC            = $entry.IsUTC
            HasIssue         = $hasIssue
            Status           = $status
            Severity         = $severity
            IsHealthy        = -not $hasIssue
            Message          = $message
        }
    }

    Write-Verbose "[TIME-010] Check complete. DCs checked: $($results.Count). DST consistent: $dstConsistent"
    return $results
}
catch {
    Write-Error "[TIME-010] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        TimeZone         = 'Unknown'
        DaylightName     = 'Unknown'
        DaylightBias     = $null
        HasDST           = $false
        IsUTC            = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
