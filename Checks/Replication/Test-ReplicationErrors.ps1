<#
.SYNOPSIS
    Replication Errors Check (REP-002)

.DESCRIPTION
    Checks for common AD replication error codes in event logs:
    - Event ID 1655 (replication failure)
    - Event ID 2042 (time since last replication)
    - Event IDs 1311, 1388, 1925 (common replication errors)
    
.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ReplicationErrors.ps1 -Inventory $inventory

.OUTPUTS
    Array of replication error objects

.NOTES
    Check ID: REP-002
    Category: Replication
    Severity: High
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

# Replication error event IDs to check
$replicationErrorIDs = @(
    @{ ID = 1655; Description = "AD cannot communicate with global catalog" },
    @{ ID = 2042; Description = "Too long since last replication" },
    @{ ID = 1311; Description = "Replication configuration information is missing" },
    @{ ID = 1388; Description = "Replication error due to lingering object" },
    @{ ID = 1925; Description = "Replication failed to establish connection" },
    @{ ID = 1586; Description = "Insufficient attributes to create object" },
    @{ ID = 2087; Description = "DNS lookup failure prevented replication" }
)

Write-Verbose "[REP-002] Starting replication errors check..."

try {
    $domainControllers = $Inventory.DomainControllers
    
    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[REP-002] No domain controllers found in inventory"
        return @()
    }
    
    Write-Verbose "[REP-002] Checking event logs on $($domainControllers.Count) domain controllers..."
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-002] Processing DC: $($dc.Name)"
        
        # Only check reachable DCs
        if (-not $dc.IsReachable) {
            Write-Verbose "[REP-002] DC $($dc.Name) is not reachable, skipping"
            continue
        }
        
        foreach ($eventInfo in $replicationErrorIDs) {
            try {
                # Query event log for this error in last 7 days
                $events = Get-WinEvent -ComputerName $dc.HostName -FilterHashtable @{
                    LogName = 'Directory Service'
                    ID = $eventInfo.ID
                    StartTime = (Get-Date).AddDays(-7)
                } -MaxEvents 10 -ErrorAction SilentlyContinue
                
                if ($events) {
                    foreach ($event in $events) {
                        $result = [PSCustomObject]@{
                            DomainController = $dc.Name
                            EventID = $eventInfo.ID
                            EventDescription = $eventInfo.Description
                            TimeGenerated = $event.TimeCreated
                            Message = $event.Message
                            ErrorCount = $events.Count
                            Severity = if ($eventInfo.ID -in @(1655, 2042)) { 'Critical' } else { 'High' }
                            Status = 'Failed'
                            IsHealthy = $false
                            HasIssue = $true
                        }
                        
                        $results += $result
                    }
                    
                    Write-Verbose "[REP-002] Found $($events.Count) occurrences of Event ID $($eventInfo.ID) on $($dc.Name)"
                }
            }
            catch {
                Write-Verbose "[REP-002] Could not query Event ID $($eventInfo.ID) on $($dc.Name): $($_.Exception.Message)"
            }
        }
    }
    
    # If no errors found, return healthy result
    if ($results.Count -eq 0) {
        Write-Verbose "[REP-002] No replication errors found in event logs"
        
        $results = @([PSCustomObject]@{
            DomainController = "All DCs"
            EventID = 0
            EventDescription = "No replication errors detected"
            TimeGenerated = Get-Date
            Message = "Event log check completed - no replication errors in last 7 days"
            ErrorCount = 0
            Severity = 'Info'
            Status = 'Healthy'
            IsHealthy = $true
            HasIssue = $false
        })
    }
    
    Write-Verbose "[REP-002] Check complete. Errors found: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[REP-002] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        EventID = -1
        EventDescription = "Check execution failed"
        TimeGenerated = Get-Date
        Message = $_.Exception.Message
        ErrorCount = 0
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
    })
}
