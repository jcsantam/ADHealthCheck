<#
.SYNOPSIS
    ISTG Election Health Check (REP-016)

.DESCRIPTION
    Verifies the Inter-Site Topology Generator (ISTG) is properly elected in
    each AD site. The ISTG is responsible for creating inter-site connection
    objects. If the ISTG is missing or not reachable, inter-site replication
    topology cannot be automatically maintained.

    Checks:
    - Each site has an ISTG elected (attribute interSiteTopologyGenerator)
    - The elected ISTG DC is reachable
    - ISTG is consistent with known domain controllers

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ISTGHealth.ps1 -Inventory $inventory

.OUTPUTS
    Array of ISTG health results per site

.NOTES
    Check ID: REP-016
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

Write-Verbose "[REP-016] Starting ISTG election health check..."

try {
    $sites = $Inventory.Sites
    $domainControllers = $Inventory.DomainControllers

    if (-not $sites -or $sites.Count -eq 0) {
        Write-Verbose "[REP-016] No sites found in inventory"
        return @([PSCustomObject]@{
            Site        = 'Unknown'
            ISTGServer  = 'Unknown'
            IsReachable = $false
            HasIssue    = $true
            Status      = 'Warning'
            Severity    = 'Medium'
            IsHealthy   = $false
            Message     = "No AD sites found in inventory"
        })
    }

    # Use first reachable DC as query target
    $queryDC = ($domainControllers | Where-Object { $_.IsReachable } | Select-Object -First 1)
    if (-not $queryDC) {
        Write-Warning "[REP-016] No reachable DCs available"
        return @([PSCustomObject]@{
            Site        = 'Unknown'
            ISTGServer  = 'Unknown'
            IsReachable = $false
            HasIssue    = $true
            Status      = 'Error'
            Severity    = 'Error'
            IsHealthy   = $false
            Message     = "No reachable DCs available for ISTG query"
        })
    }

    $domainName = ($Inventory.Domains | Select-Object -First 1).Name
    $forestDN   = 'DC=' + ($Inventory.ForestInfo.RootDomain -replace '\.', ',DC=')
    $sitesDN    = "CN=Sites,CN=Configuration,$forestDN"

    foreach ($site in $sites) {
        $siteName = $site.Name
        Write-Verbose "[REP-016] Checking ISTG for site: $siteName"

        try {
            $siteObj = Get-ADObject -Filter "Name -eq '$siteName' -and objectClass -eq 'site'" `
                -SearchBase $sitesDN `
                -Server $queryDC.Name `
                -Properties interSiteTopologyGenerator `
                -ErrorAction SilentlyContinue

            $istgDN      = $null
            $istgServer  = 'Not elected'
            $isReachable = $false
            $issues      = @()

            if ($siteObj -and $siteObj.interSiteTopologyGenerator) {
                $istgDN = $siteObj.interSiteTopologyGenerator

                # Extract server name from DN: CN=<server>,CN=Servers,CN=<site>,...
                if ($istgDN -match '^CN=([^,]+)') {
                    $istgShortName = $matches[1]
                    # Try to find in inventory
                    $istgDC = $domainControllers | Where-Object {
                        $_.Name -like "$istgShortName*" -or $_.HostName -eq $istgShortName
                    } | Select-Object -First 1

                    if ($istgDC) {
                        $istgServer  = $istgDC.Name
                        $isReachable = $istgDC.IsReachable
                        if (-not $isReachable) {
                            $issues += "ISTG server $istgServer is not reachable - inter-site topology generation impaired"
                        }
                    } else {
                        $istgServer  = $istgShortName
                        $isReachable = $false
                        $issues += "ISTG server '$istgShortName' not found in DC inventory - may be stale or unreachable"
                    }
                }
            } else {
                $issues += "No ISTG elected for site $siteName - inter-site replication topology cannot be maintained automatically"
            }

            $hasIssue = ($issues.Count -gt 0)
            $status   = if ($hasIssue) { 'Fail' } else { 'Pass' }
            $severity = if (-not $siteObj -or -not $siteObj.interSiteTopologyGenerator) { 'High' } `
                        elseif (-not $isReachable) { 'High' } else { 'Info' }

            $message = if ($hasIssue) {
                "Site $siteName ISTG issues: $($issues -join '; ')"
            } else {
                "Site $siteName ISTG is healthy (server: $istgServer)"
            }

            $results += [PSCustomObject]@{
                Site        = $siteName
                ISTGServer  = $istgServer
                ISTGdn      = $istgDN
                IsReachable = $isReachable
                HasIssue    = $hasIssue
                Status      = $status
                Severity    = $severity
                IsHealthy   = -not $hasIssue
                Message     = $message
            }
        }
        catch {
            Write-Warning "[REP-016] Failed to check ISTG for site $siteName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Site        = $siteName
                ISTGServer  = 'Unknown'
                ISTGdn      = $null
                IsReachable = $false
                HasIssue    = $true
                Status      = 'Error'
                Severity    = 'Error'
                IsHealthy   = $false
                Message     = "Failed to check ISTG for site $siteName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[REP-016] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-016] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Site        = 'Unknown'
        ISTGServer  = 'Unknown'
        ISTGdn      = $null
        IsReachable = $false
        HasIssue    = $true
        Status      = 'Error'
        Severity    = 'Error'
        IsHealthy   = $false
        Message     = "Check execution failed: $($_.Exception.Message)"
    })
}
