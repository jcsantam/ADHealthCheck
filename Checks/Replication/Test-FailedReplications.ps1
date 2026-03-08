<#
.SYNOPSIS
    Failed Replication Attempts Check (REP-007)

.DESCRIPTION
    Scans event logs for recent replication failures. Identifies patterns
    and frequency of replication errors.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: REP-007
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

# Event IDs for replication failures
$replFailureEvents = @(
    1085,  # Replication failed
    1308,  # Replication error
    2087   # DNS lookup failure
)

# Check last 7 days
$startTime = (Get-Date).AddDays(-7)

Write-Verbose "[REP-007] Starting failed replication attempts check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[REP-007] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-007] Checking replication failures on: $($dc.Name)"
        
        try {
            # Get replication failure events
            $events = Get-WinEvent -ComputerName $dc.HostName -FilterHashtable @{
                LogName = 'Directory Service'
                Id = $replFailureEvents
                StartTime = $startTime
            } -ErrorAction SilentlyContinue
            
            $failureCount = if ($events) { $events.Count } else { 0 }
            
            # Group by event ID
            $eventBreakdown = @{}
            if ($events) {
                $events | Group-Object Id | ForEach-Object {
                    $eventBreakdown[$_.Name] = $_.Count
                }
            }
            
            # Get unique source DCs
            $sourceDCs = @()
            if ($events) {
                $events | ForEach-Object {
                    if ($_.Message -match "CN=NTDS Settings,CN=([^,]+)") {
                        $sourceDCs += $matches[1]
                    }
                }
            }
            $uniqueSources = ($sourceDCs | Select-Object -Unique).Count
            
            # Determine status
            $hasIssue = $failureCount -gt 0
            $severity = if ($failureCount -gt 100) { 'Critical' }
                       elseif ($failureCount -gt 20) { 'High' }
                       elseif ($failureCount -gt 0) { 'Medium' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                FailureCount = $failureCount
                UniqueSources = $uniqueSources
                EventBreakdown = ($eventBreakdown.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }) -join ", "
                Period = "Last 7 days"
                Severity = $severity
                Status = if ($failureCount -gt 20) { 'Failed' }
                        elseif ($failureCount -gt 0) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($failureCount -gt 100) {
                    "CRITICAL: $failureCount replication failures in last 7 days!"
                }
                elseif ($failureCount -gt 20) {
                    "WARNING: $failureCount replication failures in last 7 days"
                }
                elseif ($failureCount -gt 0) {
                    "$failureCount replication failures detected"
                }
                else {
                    "No replication failures in last 7 days"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[REP-007] Failed to check events on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                FailureCount = 0
                UniqueSources = 0
                EventBreakdown = "Unknown"
                Period = "Last 7 days"
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query events: $_"
            }
        }
    }
    
    Write-Verbose "[REP-007] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[REP-007] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        FailureCount = 0
        UniqueSources = 0
        EventBreakdown = "Unknown"
        Period = "Last 7 days"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
