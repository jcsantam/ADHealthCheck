<#
.SYNOPSIS
    Time Zone Consistency Check (TIME-009)

.DESCRIPTION
    Verifies that all reachable domain controllers are configured with the same
    time zone. Mixed time zones across DCs can cause log correlation issues and
    confuse administrators reviewing event timestamps.

    Best practice is to configure all DCs to use UTC (Coordinated Universal Time,
    Bias=0) to avoid any daylight saving time complications.

    Checks:
    - All DCs share the same time zone (consistency)
    - DCs are configured to UTC (best practice advisory)

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-TimeZoneConsistency.ps1 -Inventory $inventory

.OUTPUTS
    Array of time zone results per DC

.NOTES
    Check ID: TIME-009
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

Write-Verbose "[TIME-009] Starting time zone consistency check..."

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[TIME-009] No domain controllers found in inventory"
        return @()
    }

    # First pass: collect time zone info for all reachable DCs
    $tzData = @()

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[TIME-009] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[TIME-009] Querying time zone on: $dcName"

        try {
            $tz = Get-WmiObject -Class Win32_TimeZone -ComputerName $dc.Name -ErrorAction SilentlyContinue

            if (-not $tz) {
                $tzData += [PSCustomObject]@{
                    DomainController = $dcName
                    TimeZone         = 'Unknown'
                    Bias             = $null
                    IsUTC            = $false
                    QueryOk          = $false
                }
                continue
            }

            $isUTC = ($tz.Bias -eq 0)

            $tzData += [PSCustomObject]@{
                DomainController = $dcName
                TimeZone         = $tz.StandardName
                Bias             = $tz.Bias
                IsUTC            = $isUTC
                QueryOk          = $true
            }
        }
        catch {
            Write-Warning "[TIME-009] Failed to query time zone on DC ${dcName}: $($_.Exception.Message)"
            $tzData += [PSCustomObject]@{
                DomainController = $dcName
                TimeZone         = 'Unknown'
                Bias             = $null
                IsUTC            = $false
                QueryOk          = $false
            }
        }
    }

    if ($tzData.Count -eq 0) {
        Write-Warning "[TIME-009] No DC time zone data collected"
        return @()
    }

    # Determine if time zones are consistent across DCs (only among successfully queried DCs)
    $successfulData = $tzData | Where-Object { $_.QueryOk -eq $true }
    $uniqueTimeZones = $successfulData | Select-Object -ExpandProperty TimeZone -Unique
    $timeZonesConsistent = ($uniqueTimeZones.Count -le 1)

    # Second pass: build result objects with consistency information
    foreach ($entry in $tzData) {
        if (-not $entry.QueryOk) {
            $results += [PSCustomObject]@{
                DomainController = $entry.DomainController
                TimeZone         = 'Unknown'
                Bias             = $null
                IsUTC            = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to retrieve time zone information from $($entry.DomainController)"
            }
            continue
        }

        $hasIssue = $false
        $status = 'Pass'
        $severity = 'Info'
        $message = ''

        if (-not $timeZonesConsistent) {
            $hasIssue = $true
            $status = 'Fail'
            $severity = 'High'
            $message = "DC $($entry.DomainController) has time zone '$($entry.TimeZone)' -DCs have inconsistent time zones ($($uniqueTimeZones -join ', '))"
        }
        elseif (-not $entry.IsUTC) {
            $hasIssue = $true
            $status = 'Warning'
            $severity = 'Low'
            $message = "DC $($entry.DomainController) time zone is '$($entry.TimeZone)' (Bias: $($entry.Bias) min) -best practice is UTC (Bias=0)"
        }
        else {
            $message = "DC $($entry.DomainController) is configured to UTC -recommended configuration"
        }

        $results += [PSCustomObject]@{
            DomainController = $entry.DomainController
            TimeZone         = $entry.TimeZone
            Bias             = $entry.Bias
            IsUTC            = $entry.IsUTC
            HasIssue         = $hasIssue
            Status           = $status
            Severity         = $severity
            IsHealthy        = -not $hasIssue
            Message          = $message
        }
    }

    Write-Verbose "[TIME-009] Check complete. DCs checked: $($results.Count). Time zones consistent: $timeZonesConsistent"
    return $results
}
catch {
    Write-Error "[TIME-009] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        TimeZone         = 'Unknown'
        Bias             = $null
        IsUTC            = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
