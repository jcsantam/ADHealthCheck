<#
.SYNOPSIS
    Bridgehead Server Health Check (REP-013)
.DESCRIPTION
    Checks if preferred bridgehead servers are configured in AD and verifies
    they are reachable. If no preferred bridgehead servers are configured,
    KCC auto-selection is used which is the normal/preferred behaviour.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: REP-013
    Category: Replication
    Severity: Medium
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[REP-013] Starting bridgehead server health check..."

try {
    $forestName = $Inventory.ForestInfo.Name
    $forestDN   = 'DC=' + ($forestName -replace '\.', ',DC=')

    Write-Verbose "[REP-013] Querying preferred bridgehead servers from forest: $forestName"

    try {
        $servers = @(Get-ADObject -Filter { objectClass -eq 'server' } `
            -SearchBase "CN=Sites,CN=Configuration,$forestDN" `
            -Properties bridgeheadTransportList, dNSHostName `
            -Server $forestName -ErrorAction Stop)
    }
    catch {
        Write-Warning "[REP-013] Failed to query server objects: $_"
        return @([PSCustomObject]@{
            Site              = 'Unknown'
            BridgeheadServer  = 'Unknown'
            IsConfigured      = $false
            IsReachable       = $false
            IsHealthy         = $false
            HasIssue          = $true
            Status            = 'Error'
            Severity          = 'Error'
            Message           = "Failed to query bridgehead server objects: $_"
        })
    }

    # Filter to servers with preferred bridgehead transport configured
    $bridgeheadServers = @($servers | Where-Object {
        $_.bridgeheadTransportList -and @($_.bridgeheadTransportList).Count -gt 0
    })

    if (@($bridgeheadServers).Count -eq 0) {
        # No preferred bridgehead servers - KCC auto-selects, which is normal
        return @([PSCustomObject]@{
            Site             = 'All'
            BridgeheadServer = 'None (KCC auto-select)'
            IsConfigured     = $false
            IsReachable      = $true
            IsHealthy        = $true
            HasIssue         = $false
            Status           = 'Pass'
            Severity         = 'Info'
            Message          = 'No preferred bridgehead servers configured - KCC auto-selection is active (recommended)'
        })
    }

    # Build a lookup of known reachable DC names
    $reachableDCNames = @{}
    foreach ($dc in $Inventory.DomainControllers) {
        if ($dc.IsReachable) {
            $reachableDCNames[$dc.Name.ToLower()] = $true
            if ($dc.HostName) {
                $reachableDCNames[$dc.HostName.ToLower()] = $true
            }
        }
    }

    foreach ($bh in $bridgeheadServers) {
        # Extract site name from DN: CN=ServerName,CN=Servers,CN=SiteName,CN=Sites,...
        $dnParts  = $bh.DistinguishedName -split ','
        $siteName = ($dnParts | Where-Object { $_ -match '^CN=.+' } | Select-Object -Index 2) -replace '^CN=', ''

        $serverFQDN = if ($bh.dNSHostName) { $bh.dNSHostName } else { $bh.Name }

        $isReachable = $reachableDCNames.ContainsKey($serverFQDN.ToLower()) -or
                       $reachableDCNames.ContainsKey($bh.Name.ToLower())

        $hasIssue = -not $isReachable

        $results += [PSCustomObject]@{
            Site             = $siteName
            BridgeheadServer = $serverFQDN
            IsConfigured     = $true
            IsReachable      = $isReachable
            IsHealthy        = -not $hasIssue
            HasIssue         = $hasIssue
            Status           = if ($hasIssue) { 'Warning' } else { 'Healthy' }
            Severity         = if ($hasIssue) { 'Medium' } else { 'Info' }
            Message          = if ($hasIssue) {
                "Preferred bridgehead server '$serverFQDN' in site '$siteName' is not reachable"
            } else {
                "Preferred bridgehead server '$serverFQDN' in site '$siteName' is reachable"
            }
        }
    }

    Write-Verbose "[REP-013] Check complete. Bridgehead servers checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[REP-013] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Site             = 'Unknown'
        BridgeheadServer = 'Unknown'
        IsConfigured     = $false
        IsReachable      = $false
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
