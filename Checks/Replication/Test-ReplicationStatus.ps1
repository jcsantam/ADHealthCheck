<#
.SYNOPSIS
    Replication Status Check (REP-001)

.DESCRIPTION
    Validates AD replication health by checking:
    - Replication partnerships between DCs
    - Last successful replication time
    - Replication failures and errors
    - Uses 'repadmin /showrepl' equivalent via .NET

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ReplicationStatus.ps1 -Inventory $inventory

.OUTPUTS
    Array of replication partnership status objects

.NOTES
    Check ID: REP-001
    Category: Replication
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[REP-001] Starting replication status check..."

try {
    # Get all DCs from inventory
    $domainControllers = $Inventory.DomainControllers
    
    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[REP-001] No domain controllers found in inventory"
        return @()
    }
    
    Write-Verbose "[REP-001] Checking replication for $($domainControllers.Count) domain controllers..."
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-001] Processing DC: $($dc.Name)"
        
        try {
            # Get DC object
            $dcContext = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext(
                'DirectoryServer', $dc.Name
            )
            $dcServer = [System.DirectoryServices.ActiveDirectory.DomainController]::GetDomainController($dcContext)
            
            # Get replication metadata for this DC
            $replNeighbors = $dcServer.GetAllReplicationNeighbors()
            
            foreach ($neighbor in $replNeighbors) {
                # Calculate last sync hours
                $lastSync = $neighbor.LastSuccessfulSync
                $hoursSinceSync = if ($lastSync) {
                    ((Get-Date) - $lastSync).TotalHours
                } else {
                    999  # Never synced
                }
                
                # Determine status
                $status = 'Healthy'
                $hasIssue = $false
                
                if ($neighbor.LastSyncResult -ne 0) {
                    $status = 'Failed'
                    $hasIssue = $true
                }
                elseif ($hoursSinceSync -gt 24) {
                    $status = 'Stale'
                    $hasIssue = $true
                }
                elseif ($hoursSinceSync -gt 12) {
                    $status = 'Warning'
                }
                
                $result = [PSCustomObject]@{
                    SourceDC = $dc.Name
                    TargetDC = $neighbor.SourceServer
                    NamingContext = $neighbor.PartitionName
                    LastSync = $lastSync
                    LastSyncHours = [math]::Round($hoursSinceSync, 2)
                    LastSyncResult = $neighbor.LastSyncResult
                    ConsecutiveFailures = $neighbor.ConsecutiveFailureCount
                    Status = $status
                    IsHealthy = -not $hasIssue
                    HasIssue = $hasIssue
                    Message = if ($hasIssue) {
                        if ($neighbor.LastSyncResult -ne 0) {
                            "Replication failed with error $($neighbor.LastSyncResult)"
                        } else {
                            "Last sync was $([math]::Round($hoursSinceSync, 1)) hours ago"
                        }
                    } else {
                        "Replication healthy"
                    }
                }
                
                $results += $result
            }
        }
        catch {
            Write-Warning "[REP-001] Failed to query replication for DC $($dc.Name): $($_.Exception.Message)"
            
            # Add error result
            $results += [PSCustomObject]@{
                SourceDC = $dc.Name
                TargetDC = "Unknown"
                NamingContext = "Unknown"
                LastSync = $null
                LastSyncHours = 999
                LastSyncResult = -1
                ConsecutiveFailures = 0
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query replication: $($_.Exception.Message)"
            }
        }
    }
    
    Write-Verbose "[REP-001] Check complete. Partnerships checked: $($results.Count)"
    
    # Summary
    $healthyCount = ($results | Where-Object { $_.IsHealthy }).Count
    $issueCount = ($results | Where-Object { $_.HasIssue }).Count
    
    Write-Verbose "[REP-001] Healthy: $healthyCount, Issues: $issueCount"
    
    return $results
}
catch {
    Write-Error "[REP-001] Check failed: $($_.Exception.Message)"
    
    # Return error result
    return @([PSCustomObject]@{
        SourceDC = "Unknown"
        TargetDC = "Unknown"
        NamingContext = "Unknown"
        LastSync = $null
        LastSyncHours = 999
        LastSyncResult = -1
        ConsecutiveFailures = 0
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
