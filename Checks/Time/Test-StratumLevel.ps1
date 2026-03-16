<#
.SYNOPSIS
    Stratum Level Check (TIME-006)

.DESCRIPTION
    Checks the NTP stratum level reported by each domain controller.
    Stratum 16 indicates the clock is unsynchronized. The PDC Emulator
    should sync directly from a stratum 1-2 source making it stratum 2-3.
    Non-PDC DCs sync from the PDC, so stratum <= 5 is acceptable.

    Checks:
    - Stratum 16 on any DC (unsynchronized) → Critical
    - PDC Emulator stratum > 3 → High warning
    - Non-PDC DC stratum > 5 → Medium warning

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-StratumLevel.ps1 -Inventory $inventory

.OUTPUTS
    Array of stratum level results per DC

.NOTES
    Check ID: TIME-006
    Category: Time
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[TIME-006] Starting stratum level check..."

try {
    $domainControllers = $Inventory.DomainControllers
    $domains = $Inventory.Domains

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[TIME-006] No domain controllers found in inventory"
        return @()
    }

    # Build PDC lookup
    $pdcNames = @{}
    foreach ($domain in $domains) {
        $pdcNames[$domain.PDCEmulator] = $domain.Name
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[TIME-006] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        $isPDC = $pdcNames.ContainsKey($dcName)

        Write-Verbose "[TIME-006] Checking stratum on: $dcName (IsPDC: $isPDC)"

        try {
            $w32tmStatus = w32tm /query /computer:$dcName /status 2>&1

            $stratum = $null
            $stratumLine = $w32tmStatus | Where-Object { $_ -match 'Stratum:' }
            if ($stratumLine -match 'Stratum:\s*(\d+)') {
                $stratum = [int]$matches[1]
            }

            if ($stratum -eq $null) {
                $results += [PSCustomObject]@{
                    DomainController = $dcName
                    IsPDC            = $isPDC
                    Stratum          = $null
                    IsStratum16      = $false
                    HasIssue         = $true
                    Status           = 'Error'
                    Severity         = 'Error'
                    IsHealthy        = $false
                    Message          = "Could not parse stratum from w32tm output on $dcName"
                }
                continue
            }

            $isStratum16 = ($stratum -eq 16)
            $hasIssue = $false
            $status = 'Pass'
            $severity = 'Info'
            $message = ''

            if ($isStratum16) {
                $hasIssue = $true
                $status = 'Fail'
                $severity = 'Critical'
                $message = "DC $dcName has stratum 16 - clock is unsynchronized"
            }
            elseif ($isPDC -and $stratum -gt 3) {
                $hasIssue = $true
                $status = 'Warning'
                $severity = 'High'
                $message = "PDC $dcName has stratum $stratum (expected <= 3 for a PDC synchronized to external source)"
            }
            elseif (-not $isPDC -and $stratum -gt 5) {
                $hasIssue = $true
                $status = 'Warning'
                $severity = 'Medium'
                $message = "DC $dcName has stratum $stratum (expected <= 5 for a domain-synced DC)"
            }
            else {
                if ($isPDC) {
                    $message = "PDC $dcName has acceptable stratum $stratum"
                }
                else {
                    $message = "DC $dcName has acceptable stratum $stratum"
                }
            }

            $results += [PSCustomObject]@{
                DomainController = $dcName
                IsPDC            = $isPDC
                Stratum          = $stratum
                IsStratum16      = $isStratum16
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                IsHealthy        = -not $hasIssue
                Message          = $message
            }
        }
        catch {
            Write-Warning "[TIME-006] Failed to query stratum on DC ${dcName}: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController = $dcName
                IsPDC            = $isPDC
                Stratum          = $null
                IsStratum16      = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to query stratum level: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[TIME-006] Check complete. DCs checked: $($results.Count)"
    return $results
}
catch {
    Write-Error "[TIME-006] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        IsPDC            = $false
        Stratum          = $null
        IsStratum16      = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
