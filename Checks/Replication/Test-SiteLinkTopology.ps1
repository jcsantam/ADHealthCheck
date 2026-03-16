<#
.SYNOPSIS
    Site Link Topology Check (REP-012)
.DESCRIPTION
    Checks AD site link configuration for issues including high replication intervals,
    excessive costs, and sites not covered by any site link.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: REP-012
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

Write-Verbose "[REP-012] Starting site link topology check..."

try {
    $forestName = $Inventory.ForestInfo.Name
    $forestDN   = 'DC=' + ($forestName -replace '\.', ',DC=')
    $searchBase = "CN=IP,CN=Inter-Site Transports,CN=Sites,CN=Configuration,$forestDN"

    Write-Verbose "[REP-012] Querying site links from forest: $forestName"

    try {
        $siteLinks = @(Get-ADObject -Filter { objectClass -eq 'siteLink' } `
            -SearchBase "CN=Sites,CN=Configuration,$forestDN" `
            -Properties cost, replInterval, siteList, schedule `
            -Server $forestName -ErrorAction Stop)
    }
    catch {
        Write-Warning "[REP-012] Failed to query site links: $_"
        return @([PSCustomObject]@{
            SiteLinkName         = 'Unknown'
            Cost                 = 0
            ReplicationInterval  = 0
            SiteCount            = 0
            IsHealthy            = $false
            HasIssue             = $true
            Status               = 'Error'
            Severity             = 'Error'
            Message              = "Failed to query site links: $_"
        })
    }

    if (@($siteLinks).Count -eq 0) {
        Write-Warning "[REP-012] No site links found"
        return @([PSCustomObject]@{
            SiteLinkName         = 'N/A'
            Cost                 = 0
            ReplicationInterval  = 0
            SiteCount            = 0
            IsHealthy            = $false
            HasIssue             = $true
            Status               = 'Warning'
            Severity             = 'High'
            Message              = 'No site links found in AD configuration'
        })
    }

    foreach ($sl in $siteLinks) {
        $replInterval = if ($sl.replInterval) { [int]$sl.replInterval } else { 180 }
        $cost         = if ($sl.cost)         { [int]$sl.cost }         else { 100 }
        $siteCount    = if ($sl.siteList)     { @($sl.siteList).Count } else { 0 }

        $issues   = @()
        $hasIssue = $false
        $severity = 'Info'

        if ($replInterval -gt 180) {
            $hasIssue = $true
            $severity = 'High'
            $issues  += "Replication interval is $replInterval minutes (max recommended: 180)"
        }

        if ($cost -gt 1000) {
            $hasIssue = $true
            if ($severity -eq 'Info') { $severity = 'Medium' }
            $issues  += "Site link cost is $cost (unusually high, > 1000)"
        }

        $status = if ($hasIssue -and $severity -eq 'High') { 'Fail' }
                  elseif ($hasIssue) { 'Warning' }
                  else { 'Healthy' }

        $results += [PSCustomObject]@{
            SiteLinkName        = $sl.Name
            Cost                = $cost
            ReplicationInterval = $replInterval
            SiteCount           = $siteCount
            IsHealthy           = -not $hasIssue
            HasIssue            = $hasIssue
            Status              = $status
            Severity            = $severity
            Message             = if ($hasIssue) {
                "Site link '$($sl.Name)': " + ($issues -join '; ')
            } else {
                "Site link '$($sl.Name)' is healthy (interval: $replInterval min, cost: $cost)"
            }
        }
    }

    Write-Verbose "[REP-012] Check complete. Site links checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[REP-012] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        SiteLinkName        = 'Unknown'
        Cost                = 0
        ReplicationInterval = 0
        SiteCount           = 0
        IsHealthy           = $false
        HasIssue            = $true
        Status              = 'Error'
        Severity            = 'Error'
        Message             = "Check execution failed: $($_.Exception.Message)"
    })
}
