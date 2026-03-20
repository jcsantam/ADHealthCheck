<#
.SYNOPSIS
    Change Notification Check (REP-019)

.DESCRIPTION
    Checks whether change notification is disabled on inter-site links.
    When change notification is disabled on a site link (the default for
    inter-site links), replication only occurs on the configured schedule
    (typically every 180 minutes). Enabling change notification on low-latency
    WAN links allows near-real-time replication like intra-site.

    The 'options' attribute on a siteLink object bit 1 (value 1) controls
    change notification:
    - Bit 0 (0x1) = Change notification enabled
    - Bit 2 (0x4) = Compression disabled

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ChangeNotification.ps1 -Inventory $inventory

.OUTPUTS
    Array of change notification results per site link

.NOTES
    Check ID: REP-019
    Category: Replication
    Severity: Low
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[REP-019] Starting change notification check..."

try {
    $domainControllers = $Inventory.DomainControllers
    $queryDC = ($domainControllers | Where-Object { $_.IsReachable } | Select-Object -First 1)

    if (-not $queryDC) {
        Write-Warning "[REP-019] No reachable DCs available"
        return @([PSCustomObject]@{
            SiteLink               = 'Unknown'
            ChangeNotification     = $false
            ReplicationInterval    = 0
            HasIssue               = $true
            Status                 = 'Error'
            Severity               = 'Error'
            IsHealthy              = $false
            Message                = "No reachable DCs available"
        })
    }

    $forestDN   = 'DC=' + ($Inventory.ForestInfo.RootDomain -replace '\.', ',DC=')
    $sitelinksDN = "CN=IP,CN=Inter-Site Transports,CN=Sites,CN=Configuration,$forestDN"

    $siteLinks = @(Get-ADObject `
        -Filter { objectClass -eq 'siteLink' } `
        -SearchBase $sitelinksDN `
        -Server $queryDC.Name `
        -Properties Name, options, replInterval, siteLinkList `
        -ErrorAction SilentlyContinue)

    if ($siteLinks.Count -eq 0) {
        Write-Verbose "[REP-019] No IP site links found (single-site environment)"
        return @([PSCustomObject]@{
            SiteLink               = 'N/A'
            ChangeNotification     = $false
            ReplicationInterval    = 0
            HasIssue               = $false
            Status                 = 'Pass'
            Severity               = 'Info'
            IsHealthy              = $true
            Message                = "No inter-site links found - single-site environment"
        })
    }

    foreach ($link in $siteLinks) {
        $linkName   = $link.Name
        $optionsVal = if ($link.options) { [int]$link.options } else { 0 }
        $interval   = if ($link.replInterval) { [int]$link.replInterval } else { 180 }

        # Bit 0 = change notification enabled
        $changeNotifyEnabled = (($optionsVal -band 1) -eq 1)

        $issues = @()

        # Only flag as an issue if interval is very long (>180 min) AND no change notification
        # This is informational - change notification on WAN links is optional but recommended for fast links
        if (-not $changeNotifyEnabled -and $interval -gt 180) {
            $issues += "Change notification disabled and replication interval is ${interval} minutes - replication convergence may be slow"
        }

        $hasIssue = ($issues.Count -gt 0)
        $status   = if ($hasIssue) { 'Warning' } else { 'Pass' }
        $severity = if ($hasIssue) { 'Low' } else { 'Info' }

        $notifyStatus = if ($changeNotifyEnabled) { 'Enabled' } else { 'Disabled (default)' }

        $message = if ($hasIssue) {
            "Site link '$linkName' issues: $($issues -join '; ')"
        } else {
            "Site link '$linkName' - change notification: $notifyStatus, interval: ${interval}min"
        }

        $results += [PSCustomObject]@{
            SiteLink               = $linkName
            ChangeNotification     = $changeNotifyEnabled
            ReplicationInterval    = $interval
            Options                = $optionsVal
            HasIssue               = $hasIssue
            Status                 = $status
            Severity               = $severity
            IsHealthy              = -not $hasIssue
            Message                = $message
        }
    }

    Write-Verbose "[REP-019] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-019] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        SiteLink               = 'Unknown'
        ChangeNotification     = $false
        ReplicationInterval    = 0
        Options                = 0
        HasIssue               = $true
        Status                 = 'Error'
        Severity               = 'Error'
        IsHealthy              = $false
        Message                = "Check execution failed: $($_.Exception.Message)"
    })
}
