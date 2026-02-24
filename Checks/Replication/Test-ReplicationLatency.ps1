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
    
    foreach ($dc in $domainControllers) {
        try {
            $repadminOutput = & repadmin /showrepl $dc.HostName /csv 2>&1
            
            if ($LASTEXITCODE -ne 0) { continue }
            
            $csvData = $repadminOutput | Where-Object { $_ -notmatch "^showrepl_COLUMNS" }
            
            foreach ($line in $csvData) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                
                $fields = $line -split ','
                if ($fields.Count -lt 8) { continue }
                
                $lastSuccessTime = $null
                if ($fields[5] -and $fields[5] -ne "0") {
                    try { $lastSuccessTime = [DateTime]::Parse($fields[5]) } catch {}
                }
                
                $latencySeconds = if ($lastSuccessTime) {
                    ((Get-Date) - $lastSuccessTime).TotalSeconds
                } else { 999999 }
                
                $hasIssue = $latencySeconds -gt $warningThreshold
                $severity = if ($latencySeconds -gt $criticalThreshold) { 'Critical' } 
                           elseif ($latencySeconds -gt $warningThreshold) { 'High' } 
                           else { 'Info' }
                
                $results += [PSCustomObject]@{
                    SourceDC = $dc.Name
                    DestinationDC = $fields[1]
                    NamingContext = $fields[2]
                    LastSuccessTime = $lastSuccessTime
                    LatencyMinutes = [math]::Round($latencySeconds / 60, 1)
                    Severity = $severity
                    Status = if ($hasIssue) { 'Warning' } else { 'Healthy' }
                    IsHealthy = -not $hasIssue
                    HasIssue = $hasIssue
                    Message = "Latency: $([math]::Round($latencySeconds / 60, 1)) min"
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
