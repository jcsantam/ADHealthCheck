<#
.SYNOPSIS
    Up-To-Dateness Vector Analysis (REP-017)

.DESCRIPTION
    Analyzes the up-to-dateness (UTD) vectors reported by each domain controller
    to detect stale replication partners and replication gaps. A stale UTD vector
    means a DC has not received updates from a partner within the expected window,
    indicating a potential replication isolation or failure.

    Uses 'repadmin /showvector' output parsed via Invoke-Expression.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-UTDVectors.ps1 -Inventory $inventory

.OUTPUTS
    Array of UTD vector analysis results per DC

.NOTES
    Check ID: REP-017
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

Write-Verbose "[REP-017] Starting UTD vector analysis..."

$staleThresholdDays = 3

try {
    $domainControllers = $Inventory.DomainControllers
    $reachableDCs = @($domainControllers | Where-Object { $_.IsReachable })

    if ($reachableDCs.Count -lt 2) {
        Write-Verbose "[REP-017] Single DC or no reachable DCs - UTD analysis not applicable"
        return @([PSCustomObject]@{
            DomainController = if ($reachableDCs.Count -gt 0) { $reachableDCs[0].Name } else { 'Unknown' }
            StalePartners    = 0
            TotalPartners    = 0
            HasIssue         = $false
            Status           = 'Pass'
            Severity         = 'Info'
            IsHealthy        = $true
            Message          = "Single-DC environment - UTD vector analysis not applicable"
        })
    }

    $domain = $Inventory.Domains | Select-Object -First 1
    if (-not $domain) {
        Write-Warning "[REP-017] No domain found in inventory"
        return @()
    }

    foreach ($dc in $reachableDCs) {
        $dcName = $dc.Name
        Write-Verbose "[REP-017] Checking UTD vectors on: $dcName"

        try {
            # Use repadmin /showrepl to get partner replication metadata
            $replOutput = & repadmin /showrepl $dcName /csv 2>$null
            $stalePartners  = 0
            $totalPartners  = 0
            $staleDetails   = @()

            if ($replOutput) {
                # Parse CSV output: skip header line
                $lines = $replOutput | Select-Object -Skip 1
                foreach ($line in $lines) {
                    if (-not $line -or $line.Trim() -eq '') { continue }
                    $cols = $line -split ','
                    # CSV columns: ShowRepl_CSV,DestSite,DestDSA,NC,SrcSite,SrcDSA,Transport,NumFail,LastFailTime,LastFailStatus,LastSuccessTime
                    if ($cols.Count -lt 11) { continue }

                    $sourceDC    = ($cols[5] -replace '"', '').Trim()
                    $lastSuccess = ($cols[10] -replace '"', '').Trim()

                    if (-not $sourceDC) { continue }
                    $totalPartners++

                    # Check if last success is stale
                    if ($lastSuccess -and $lastSuccess -ne '') {
                        try {
                            $successDate = [datetime]::Parse($lastSuccess)
                            $daysSince   = ((Get-Date) - $successDate).TotalDays
                            if ($daysSince -gt $staleThresholdDays) {
                                $stalePartners++
                                $staleDetails += "$sourceDC (last success: $([math]::Round($daysSince,0))d ago)"
                            }
                        } catch { }
                    }
                }
            }

            $hasIssue = ($stalePartners -gt 0)
            $status   = if ($hasIssue) { 'Fail' } else { 'Pass' }
            $severity = if ($stalePartners -ge 2) { 'High' } elseif ($hasIssue) { 'Medium' } else { 'Info' }

            $message = if ($hasIssue) {
                "DC $dcName has $stalePartners stale replication partner(s): $($staleDetails -join '; ')"
            } else {
                "DC $dcName UTD vectors are current (partners: $totalPartners)"
            }

            $results += [PSCustomObject]@{
                DomainController = $dcName
                StalePartners    = $stalePartners
                TotalPartners    = $totalPartners
                StaleDetails     = ($staleDetails -join '; ')
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                IsHealthy        = -not $hasIssue
                Message          = $message
            }
        }
        catch {
            Write-Warning "[REP-017] Failed to check UTD vectors on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController = $dcName
                StalePartners    = 0
                TotalPartners    = 0
                StaleDetails     = ''
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to check UTD vectors on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[REP-017] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-017] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        StalePartners    = 0
        TotalPartners    = 0
        StaleDetails     = ''
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
