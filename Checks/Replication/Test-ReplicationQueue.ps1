<#
.SYNOPSIS
    Replication Queue Depth Check (REP-006)

.DESCRIPTION
    Monitors inbound and outbound replication queue depth on domain controllers.
    High queue depth indicates replication bottlenecks or performance issues.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: REP-006
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

# Thresholds
$warningThreshold = 50
$criticalThreshold = 100

Write-Verbose "[REP-006] Starting replication queue depth check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[REP-006] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-006] Checking queue on: $($dc.Name)"
        
        try {
            # Get DRA (Directory Replication Agent) queue statistics
            $inboundQueue = Get-Counter -ComputerName $dc.HostName `
                -Counter "\NTDS\DRA Inbound Objects Remaining in Packet" `
                -ErrorAction SilentlyContinue
            
            $outboundQueue = Get-Counter -ComputerName $dc.HostName `
                -Counter "\NTDS\DRA Outbound Objects Filtered/sec" `
                -ErrorAction SilentlyContinue
            
            $inboundValue = if ($inboundQueue) {
                [math]::Round($inboundQueue.CounterSamples[0].CookedValue, 0)
            } else { 0 }
            
            $outboundValue = if ($outboundQueue) {
                [math]::Round($outboundQueue.CounterSamples[0].CookedValue, 0)
            } else { 0 }
            
            # Also check pending operations
            $pendingOps = Get-Counter -ComputerName $dc.HostName `
                -Counter "\NTDS\DRA Pending Replication Operations" `
                -ErrorAction SilentlyContinue
            
            $pendingValue = if ($pendingOps) {
                [math]::Round($pendingOps.CounterSamples[0].CookedValue, 0)
            } else { 0 }
            
            # Determine worst queue depth
            $maxQueue = [math]::Max($inboundValue, $pendingValue)
            
            # Determine status
            $hasIssue = $maxQueue -gt $warningThreshold
            $severity = if ($maxQueue -gt $criticalThreshold) { 'Critical' }
                       elseif ($maxQueue -gt $warningThreshold) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                InboundQueue = $inboundValue
                OutboundQueue = $outboundValue
                PendingOperations = $pendingValue
                MaxQueue = $maxQueue
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = $severity
                Status = if ($maxQueue -gt $criticalThreshold) { 'Failed' }
                        elseif ($maxQueue -gt $warningThreshold) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($maxQueue -gt $criticalThreshold) {
                    "CRITICAL: Replication queue at $maxQueue items (threshold: $criticalThreshold)"
                }
                elseif ($maxQueue -gt $warningThreshold) {
                    "WARNING: Replication queue at $maxQueue items (threshold: $warningThreshold)"
                }
                else {
                    "Replication queue healthy ($maxQueue items)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[REP-006] Failed to check queue on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                InboundQueue = 0
                OutboundQueue = 0
                PendingOperations = 0
                MaxQueue = 0
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query queue: $_"
            }
        }
    }
    
    Write-Verbose "[REP-006] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[REP-006] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        InboundQueue = 0
        OutboundQueue = 0
        PendingOperations = 0
        MaxQueue = 0
        WarningThreshold = $warningThreshold
        CriticalThreshold = $criticalThreshold
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
