<#
.SYNOPSIS
    Site Topology Validation Check (SITE-001)

.DESCRIPTION
    Validates Active Directory site topology configuration.
    Checks for sites without DCs, subnet assignments, and site link configuration.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: SITE-001
    Category: Operational
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

Write-Verbose "[SITE-001] Starting site topology validation check..."

try {
    $forestInfo = $Inventory.ForestInfo
    
    if (-not $forestInfo) {
        Write-Warning "[SITE-001] No forest info found"
        return @()
    }
    
    Write-Verbose "[SITE-001] Checking site topology for forest: $($forestInfo.Name)"
    
    try {
        # Get all sites
        $configDN = "CN=Configuration,$((Get-ADRootDSE).defaultNamingContext)"
        $sites = Get-ADObject -Filter {objectClass -eq 'site'} -SearchBase "CN=Sites,$configDN" -Properties siteObjectBL, location -ErrorAction Stop
        
        # Get all subnets
        $subnets = Get-ADReplicationSubnet -Filter * -ErrorAction Stop
        
        # Get all site links
        $siteLinks = Get-ADReplicationSiteLink -Filter * -ErrorAction Stop
        
        # Analyze topology
        $totalSites = $sites.Count
        $sitesWithDCs = 0
        $sitesWithoutDCs = 0
        $sitesWithoutSubnets = 0
        $orphanedSites = @()
        
        foreach ($site in $sites) {
            $siteName = $site.Name
            
            # Check if site has DCs
            $hasDCs = $false
            try {
                $dcCount = Get-ADDomainController -Filter {Site -eq $siteName} -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count
                $hasDCs = ($dcCount -gt 0)
            }
            catch {
                $hasDCs = $false
            }
            
            if ($hasDCs) {
                $sitesWithDCs++
            }
            else {
                $sitesWithoutDCs++
                $orphanedSites += $siteName
            }
            
            # Check if site has subnets
            $siteSubnets = $subnets | Where-Object { $_.Site -eq "CN=$siteName,CN=Sites,$configDN" }
            if (-not $siteSubnets -or $siteSubnets.Count -eq 0) {
                $sitesWithoutSubnets++
            }
        }
        
        # Check for subnets not assigned to sites
        $unassignedSubnets = ($subnets | Where-Object { -not $_.Site }).Count
        
        # Check site links
        $totalSiteLinks = $siteLinks.Count
        $siteLinkIssues = 0
        
        foreach ($siteLink in $siteLinks) {
            # Check for reasonable replication interval (not too long)
            if ($siteLink.ReplicationFrequencyInMinutes -gt 180) {
                $siteLinkIssues++
            }
        }
        
        # Determine status
        $hasIssue = ($sitesWithoutDCs -gt 0 -or $sitesWithoutSubnets -gt 0 -or $unassignedSubnets -gt 0)
        $severity = if ($sitesWithoutDCs -gt 3 -or $unassignedSubnets -gt 5) { 'High' }
                   elseif ($hasIssue) { 'Medium' }
                   else { 'Info' }
        
        $result = [PSCustomObject]@{
            Forest = $forestInfo.Name
            TotalSites = $totalSites
            SitesWithDCs = $sitesWithDCs
            SitesWithoutDCs = $sitesWithoutDCs
            SitesWithoutSubnets = $sitesWithoutSubnets
            UnassignedSubnets = $unassignedSubnets
            TotalSiteLinks = $totalSiteLinks
            SiteLinkIssues = $siteLinkIssues
            OrphanedSitesList = if ($orphanedSites.Count -gt 0) {
                ($orphanedSites -join ", ")
            } else {
                "None"
            }
            Severity = $severity
            Status = if ($sitesWithoutDCs -gt 3) { 'Warning' }
                    elseif ($hasIssue) { 'Info' }
                    else { 'Healthy' }
            IsHealthy = -not $hasIssue
            HasIssue = $hasIssue
            Message = if ($sitesWithoutDCs -gt 3) {
                "WARNING: $sitesWithoutDCs sites have no domain controllers"
            }
            elseif ($sitesWithoutDCs -gt 0) {
                "$sitesWithoutDCs site(s) without DCs, $sitesWithoutSubnets without subnets"
            }
            elseif ($sitesWithoutSubnets -gt 0) {
                "$sitesWithoutSubnets site(s) without subnet assignments"
            }
            elseif ($unassignedSubnets -gt 0) {
                "$unassignedSubnets subnet(s) not assigned to sites"
            }
            else {
                "Site topology properly configured ($totalSites sites, $totalSiteLinks links)"
            }
        }
        
        $results += $result
    }
    catch {
        Write-Warning "[SITE-001] Failed to check site topology: $_"
        
        $results += [PSCustomObject]@{
            Forest = $forestInfo.Name
            TotalSites = 0
            SitesWithDCs = 0
            SitesWithoutDCs = 0
            SitesWithoutSubnets = 0
            UnassignedSubnets = 0
            TotalSiteLinks = 0
            SiteLinkIssues = 0
            OrphanedSitesList = "Unknown"
            Severity = 'Error'
            Status = 'Error'
            IsHealthy = $false
            HasIssue = $true
            Message = "Failed to query site topology: $_"
        }
    }
    
    Write-Verbose "[SITE-001] Check complete"
    
    return $results
}
catch {
    Write-Error "[SITE-001] Check failed: $_"
    
    return @([PSCustomObject]@{
        Forest = "Unknown"
        TotalSites = 0
        SitesWithDCs = 0
        SitesWithoutDCs = 0
        SitesWithoutSubnets = 0
        UnassignedSubnets = 0
        TotalSiteLinks = 0
        SiteLinkIssues = 0
        OrphanedSitesList = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
