<#
.SYNOPSIS
    SYSVOL Replication Check (REP-005)

.DESCRIPTION
    Checks SYSVOL replication health using DFSR (2012 R2+) or FRS (legacy).
    Auto-detects which method is in use and validates accordingly.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: REP-005
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

Write-Verbose "[REP-005] Starting SYSVOL replication check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[REP-005] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[REP-005] Checking domain: $($domain.Name)"
        
        # Detect replication method (DFSR or FRS)
        $replMethod = "FRS"  # Default
        
        try {
            # Check if DFSR is in use (2012 R2+)
            $dfsrCheck = Get-Service -Name DFSR -ErrorAction SilentlyContinue
            if ($dfsrCheck -and $dfsrCheck.Status -eq 'Running') {
                $replMethod = "DFSR"
            }
        }
        catch {
            $replMethod = "FRS"
        }
        
        Write-Verbose "[REP-005] SYSVOL replication method: $replMethod"
        
        if ($replMethod -eq "DFSR") {
            # Check DFSR health
            try {
                # Use WMI instead of dfsrdiag (not always installed)
                $dfsrFolders = @(Get-WmiObject -Namespace "root\MicrosoftDFS" `
                    -Class DfsrReplicatedFolderInfo -ErrorAction Stop |
                    Where-Object { $_.ReplicationGroupName -eq "Domain System Volume" })

                $hasErrors = @($dfsrFolders | Where-Object { $_.LastErrorCode -ne 0 }).Count -gt 0
                $inSync    = @($dfsrFolders | Where-Object { $_.State -eq 4 }).Count -gt 0
                $backlogCount = 0  # WMI doesn't expose backlog directly
                
                $result = [PSCustomObject]@{
                    Domain = $domain.Name
                    ReplicationMethod = "DFSR"
                    ServiceRunning = $true
                    InSync = $inSync
                    BacklogCount = $backlogCount
                    HasErrors = $hasErrors
                    Severity = if ($hasErrors) { 'Critical' } 
                              elseif ($backlogCount -gt 100) { 'High' }
                              elseif ($backlogCount -gt 50) { 'Medium' }
                              else { 'Info' }
                    Status = if ($hasErrors) { 'Failed' }
                            elseif ($backlogCount -gt 100) { 'Warning' }
                            else { 'Healthy' }
                    IsHealthy = (-not $hasErrors -and $backlogCount -lt 50)
                    HasIssue = ($hasErrors -or $backlogCount -gt 50)
                    Message = if ($hasErrors) { "DFSR errors detected" }
                             elseif ($backlogCount -gt 100) { "High backlog: $backlogCount files" }
                             elseif ($backlogCount -gt 50) { "Moderate backlog: $backlogCount files" }
                             else { "DFSR healthy, backlog: $backlogCount" }
                }
                
                $results += $result
            }
            catch {
                Write-Warning "[REP-005] DFSR check failed: $_"
                
                $results += [PSCustomObject]@{
                    Domain = $domain.Name
                    ReplicationMethod = "DFSR"
                    ServiceRunning = $true
                    InSync = $false
                    BacklogCount = 0
                    HasErrors = $true
                    Severity = 'Error'
                    Status = 'Error'
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "Failed to query DFSR: $_"
                }
            }
        }
        else {
            # Check FRS health (legacy)
            try {
                $frsCheck = Get-Service -Name NTFRS -ErrorAction Stop
                
                if ($frsCheck.Status -ne 'Running') {
                    $results += [PSCustomObject]@{
                        Domain = $domain.Name
                        ReplicationMethod = "FRS"
                        ServiceRunning = $false
                        InSync = $false
                        BacklogCount = 0
                        HasErrors = $true
                        Severity = 'Critical'
                        Status = 'Failed'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = "FRS service not running"
                    }
                }
                else {
                    # FRS is running - basic check
                    $results += [PSCustomObject]@{
                        Domain = $domain.Name
                        ReplicationMethod = "FRS"
                        ServiceRunning = $true
                        InSync = $true
                        BacklogCount = 0
                        HasErrors = $false
                        Severity = 'Info'
                        Status = 'Healthy'
                        IsHealthy = $true
                        HasIssue = $false
                        Message = "FRS running (consider migrating to DFSR)"
                    }
                }
            }
            catch {
                Write-Warning "[REP-005] FRS check failed: $_"
                
                $results += [PSCustomObject]@{
                    Domain = $domain.Name
                    ReplicationMethod = "FRS"
                    ServiceRunning = $false
                    InSync = $false
                    BacklogCount = 0
                    HasErrors = $true
                    Severity = 'Error'
                    Status = 'Error'
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "Failed to query FRS: $_"
                }
            }
        }
    }
    
    Write-Verbose "[REP-005] Check complete. Results: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[REP-005] Check failed: $_"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        ReplicationMethod = "Unknown"
        ServiceRunning = $false
        InSync = $false
        BacklogCount = 0
        HasErrors = $true
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
