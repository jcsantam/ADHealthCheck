<#
.SYNOPSIS
    Cross-Site Replication Health (REP-020)

.DESCRIPTION
    Checks inter-site replication health by examining replication status between
    DCs in different AD sites. Cross-site replication failures are often the
    first indicator of WAN link problems, firewall changes, or ISTG issues.

    Examines repadmin /showrepl output focusing on cross-site partnerships,
    counting failures and measuring time since last successful cross-site sync.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-CrossSiteReplication.ps1 -Inventory $inventory

.OUTPUTS
    Array of cross-site replication health results

.NOTES
    Check ID: REP-020
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

Write-Verbose "[REP-020] Starting cross-site replication health check..."

try {
    $domainControllers = $Inventory.DomainControllers
    $reachableDCs      = @($domainControllers | Where-Object { $_.IsReachable })

    # Build a map of DC -> Site
    $dcSiteMap = @{}
    foreach ($dc in $domainControllers) {
        if ($dc.Site) { $dcSiteMap[$dc.Name] = $dc.Site }
    }

    # Find DCs that have partners in different sites
    $sites = @($domainControllers | Where-Object { $_.Site } | Select-Object -ExpandProperty Site -Unique)

    if ($sites.Count -lt 2) {
        Write-Verbose "[REP-020] Single-site environment - cross-site check not applicable"
        return @([PSCustomObject]@{
            DomainController   = 'N/A'
            PartnerDC          = 'N/A'
            SourceSite         = 'N/A'
            TargetSite         = 'N/A'
            LastSuccess        = 'N/A'
            ConsecFailures     = 0
            HasIssue           = $false
            Status             = 'Pass'
            Severity           = 'Info'
            IsHealthy          = $true
            Message            = "Single-site environment - cross-site replication check not applicable"
        })
    }

    foreach ($dc in $reachableDCs) {
        $dcName   = $dc.Name
        $dcSite   = if ($dc.Site) { $dc.Site } else { 'Unknown' }
        Write-Verbose "[REP-020] Checking cross-site replication from: $dcName (site: $dcSite)"

        try {
            $replOutput = & repadmin /showrepl $dcName /csv 2>$null

            if (-not $replOutput) {
                Write-Verbose "[REP-020] No repadmin output for $dcName"
                continue
            }

            $lines = $replOutput | Select-Object -Skip 1

            foreach ($line in $lines) {
                if (-not $line -or $line.Trim() -eq '') { continue }
                $cols = $line -split ','
                # CSV columns: ShowRepl_CSV,DestSite,DestDSA,NC,SrcSite,SrcDSA,Transport,NumFail,LastFailTime,LastFailStatus,LastSuccessTime
                if ($cols.Count -lt 11) { continue }

                $sourceDC    = ($cols[5] -replace '"', '').Trim()
                $sourceSiteR = ($cols[4] -replace '"', '').Trim()
                $lastSuccess = ($cols[10] -replace '"', '').Trim()
                $lastFailure = ($cols[8] -replace '"', '').Trim()
                $consecFails = 0
                $rawFail     = ($cols[7] -replace '"', '').Trim()
                if ($rawFail -match '^\d+$') { $consecFails = [int]$rawFail }

                if (-not $sourceDC) { continue }

                # Use site from CSV; fall back to inventory lookup
                $sourceSite = if ($sourceSiteR) { $sourceSiteR } else {
                    $found = $domainControllers | Where-Object {
                        $_.Name -like "$sourceDC*" -or $_.HostName -eq $sourceDC
                    } | Select-Object -First 1
                    if ($found -and $found.Site) { $found.Site } else { $null }
                }

                # Only care about cross-site partnerships
                if (-not $sourceSite -or $sourceSite -eq $dcSite) { continue }

                $issues = @()
                if ($consecFails -gt 0) {
                    $issues += "$consecFails consecutive failures replicating from $sourceDC ($sourceSite)"
                }

                $daysSince = $null
                if ($lastSuccess -and $lastSuccess -ne '') {
                    try {
                        $successDate = [datetime]::Parse($lastSuccess)
                        $daysSince   = [math]::Round(((Get-Date) - $successDate).TotalDays, 1)
                        if ($daysSince -gt 1) {
                            $issues += "Last successful cross-site sync from $sourceDC was ${daysSince} days ago"
                        }
                    } catch { }
                }

                $hasIssue = ($issues.Count -gt 0)
                $status   = if ($consecFails -gt 5) { 'Fail' } elseif ($hasIssue) { 'Warning' } else { 'Pass' }
                $severity = if ($consecFails -gt 5) { 'High' } elseif ($hasIssue) { 'Medium' } else { 'Info' }

                $message = if ($hasIssue) {
                    "Cross-site replication $dcName ($dcSite) <- $sourceDC ($sourceSite): $($issues -join '; ')"
                } else {
                    "Cross-site replication $dcName ($dcSite) <- $sourceDC ($sourceSite) is healthy (last success: $lastSuccess)"
                }

                $results += [PSCustomObject]@{
                    DomainController   = $dcName
                    PartnerDC          = $sourceDC
                    SourceSite         = $sourceSite
                    TargetSite         = $dcSite
                    LastSuccess        = $lastSuccess
                    ConsecFailures     = $consecFails
                    HasIssue           = $hasIssue
                    Status             = $status
                    Severity           = $severity
                    IsHealthy          = -not $hasIssue
                    Message            = $message
                }
            }
        }
        catch {
            Write-Warning "[REP-020] Failed to check cross-site replication on $dcName`: $($_.Exception.Message)"
        }
    }

    if ($results.Count -eq 0) {
        $results += [PSCustomObject]@{
            DomainController   = 'All DCs'
            PartnerDC          = 'N/A'
            SourceSite         = 'N/A'
            TargetSite         = 'N/A'
            LastSuccess        = 'N/A'
            ConsecFailures     = 0
            HasIssue           = $false
            Status             = 'Pass'
            Severity           = 'Info'
            IsHealthy          = $true
            Message            = "Cross-site replication partnerships evaluated - no issues detected"
        }
    }

    Write-Verbose "[REP-020] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-020] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController   = 'Unknown'
        PartnerDC          = 'Unknown'
        SourceSite         = 'Unknown'
        TargetSite         = 'Unknown'
        LastSuccess        = 'Unknown'
        ConsecFailures     = 0
        HasIssue           = $true
        Status             = 'Error'
        Severity           = 'Error'
        IsHealthy          = $false
        Message            = "Check execution failed: $($_.Exception.Message)"
    })
}
