<#
.SYNOPSIS
    KCC Error Detection (REP-011)
.DESCRIPTION
    Checks for Knowledge Consistency Checker (KCC) errors in the Directory Service
    event log on each reachable domain controller. KCC errors indicate replication
    topology problems that prevent automatic connection object management.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: REP-011
    Category: Replication
    Severity: High
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[REP-011] Starting KCC error check..."

# Single-DC guard
$dcCount = @($Inventory.DomainControllers).Count
if ($dcCount -eq 1) {
    return [PSCustomObject]@{
        IsHealthy = $true
        HasIssue  = $false
        Status    = 'Pass'
        Severity  = 'Info'
        Message   = 'Single-DC environment - check not applicable'
    }
}

# KCC-related event IDs
$kccEventIds = @(1311, 1265, 1925, 1926)
$cutoff = (Get-Date).AddHours(-24)

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[REP-011] No reachable DCs found"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-011] Checking KCC errors on: $($dc.Name)"

        try {
            $kccEvents = @()

            # Try Get-WinEvent first (2016+), fall back to Get-EventLog (2012 R2)
            try {
                $filterHash = @{
                    LogName   = 'Directory Service'
                    Id        = $kccEventIds
                    StartTime = $cutoff
                }
                $kccEvents = @(Get-WinEvent -ComputerName $dc.Name -FilterHashtable $filterHash -ErrorAction Stop)
            }
            catch [System.Exception] {
                if ($_.Exception.Message -like '*No events were found*' -or
                    $_.Exception.Message -like '*There is not an event log*') {
                    $kccEvents = @()
                }
                else {
                    # Fallback to Get-EventLog for 2012 R2
                    try {
                        $allEvents = @(Get-EventLog -LogName 'Directory Service' -ComputerName $dc.Name `
                            -After $cutoff -ErrorAction Stop)
                        $kccEvents = @($allEvents | Where-Object { $kccEventIds -contains $_.EventID })
                    }
                    catch {
                        Write-Warning "[REP-011] Could not query Directory Service log on $($dc.Name): $_"
                        $kccEvents = @()
                    }
                }
            }

            $kccErrorCount = @($kccEvents).Count
            $uniqueEventIds = ($kccEvents | Select-Object -ExpandProperty Id -Unique | Sort-Object) -join ','
            $lastErrorTime  = if ($kccErrorCount -gt 0) {
                ($kccEvents | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
            } else { $null }

            $hasIssue = $kccErrorCount -gt 0
            $severity = if ($kccErrorCount -gt 10) { 'Critical' }
                        elseif ($kccErrorCount -gt 0) { 'High' }
                        else { 'Info' }
            $status   = if ($kccErrorCount -gt 10) { 'Fail' }
                        elseif ($kccErrorCount -gt 0) { 'Warning' }
                        else { 'Healthy' }

            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                KCCErrorCount    = $kccErrorCount
                ErrorEventIds    = if ($uniqueEventIds) { $uniqueEventIds } else { '' }
                LastErrorTime    = $lastErrorTime
                IsHealthy        = -not $hasIssue
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                Message          = if ($kccErrorCount -gt 10) {
                    "CRITICAL: $kccErrorCount KCC errors in last 24h on $($dc.Name) (Event IDs: $uniqueEventIds)"
                } elseif ($kccErrorCount -gt 0) {
                    "WARNING: $kccErrorCount KCC errors in last 24h on $($dc.Name) (Event IDs: $uniqueEventIds)"
                } else {
                    "No KCC errors detected on $($dc.Name) in last 24 hours"
                }
            }
        }
        catch {
            Write-Warning "[REP-011] Failed to check KCC errors on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                KCCErrorCount    = 0
                ErrorEventIds    = ''
                LastErrorTime    = $null
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                Message          = "Failed to query KCC errors on $($dc.Name): $_"
            }
        }
    }

    Write-Verbose "[REP-011] Check complete. DCs checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[REP-011] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        KCCErrorCount    = 0
        ErrorEventIds    = ''
        LastErrorTime    = $null
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
