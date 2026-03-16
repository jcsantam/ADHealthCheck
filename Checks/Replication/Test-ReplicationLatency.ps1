<#
.SYNOPSIS
    Replication Latency Check (REP-004)

.DESCRIPTION
    Measures replication latency per naming context between domain controllers.
    
.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: REP-004
    Category: Replication  
    Severity: Critical
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
# Single-DC environment - replication latency check not applicable
$dcCount = @($Inventory.DomainControllers).Count
if ($dcCount -eq 1) {
    # Single-DC environment - replication latency check not applicable
    return [PSCustomObject]@{
        IsHealthy = $true
        Status    = 'Pass'
        Message   = 'Single-DC environment - replication latency check not applicable'
    }
}
$results = @()

# Thresholds
$warningThreshold = 900    # 15 minutes
$criticalThreshold = 3600  # 1 hour

Write-Verbose "[REP-004] Starting replication latency check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[REP-004] No reachable DCs"
        return @()
    }
    
    # Fixed column names matching repadmin /showrepl /csv output order
    $csvHeaders = 'Flags','DestSite','DestDC','NamingContext','SrcSite','SrcDC','Transport','Failures','LastFailTime','LastSuccessTime','LastStatus'

    foreach ($dc in $domainControllers) {
        try {
            $repadminOutput = & repadmin /showrepl $dc.Name /csv 2>&1

            if ($LASTEXITCODE -ne 0) { continue }

            # Strip showrepl_INFO prefix; ConvertFrom-Csv handles quoted DNs correctly
            $dataLines = $repadminOutput | Where-Object { $_ -match "^showrepl_INFO" } |
                         ForEach-Object { $_ -replace "^showrepl_INFO," }

            if (-not $dataLines) { continue }

            $parsed = @($dataLines | ConvertFrom-Csv -Header $csvHeaders)

            foreach ($row in $parsed) {
                $lastSuccessTime = $null
                if ($row.LastSuccessTime -and $row.LastSuccessTime -ne '0') {
                    try { $lastSuccessTime = [DateTime]::Parse($row.LastSuccessTime) } catch {}
                }

                $latencySeconds = if ($lastSuccessTime) {
                    ((Get-Date) - $lastSuccessTime).TotalSeconds
                } else { 999999 }

                $hasIssue = $latencySeconds -gt $warningThreshold
                $severity = if ($latencySeconds -gt $criticalThreshold) { 'Critical' }
                           elseif ($latencySeconds -gt $warningThreshold) { 'High' }
                           else { 'Info' }

                $results += [PSCustomObject]@{
                    SourceDC        = $dc.Name
                    DestinationDC   = $row.DestDC
                    NamingContext   = $row.NamingContext
                    LastSuccessTime = $lastSuccessTime
                    LatencyMinutes  = [math]::Round($latencySeconds / 60, 1)
                    Severity        = $severity
                    Status          = if ($hasIssue) { 'Warning' } else { 'Healthy' }
                    IsHealthy       = -not $hasIssue
                    HasIssue        = $hasIssue
                    Message         = "Latency: $([math]::Round($latencySeconds / 60, 1)) min"
                }
            }
        }
        catch {
            Write-Warning "[REP-004] Failed on $($dc.Name): $_"
        }
    }
    
    return $results
}
catch {
    Write-Error "[REP-004] Check failed: $_"
    return @()
}
