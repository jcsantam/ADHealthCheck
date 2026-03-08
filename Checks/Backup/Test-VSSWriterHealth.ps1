<#
.SYNOPSIS
    VSS Writer Health Check (BACKUP-003)

.DESCRIPTION
    Validates Volume Shadow Copy Service (VSS) writer health.
    Critical for successful AD backups and system state backups.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: BACKUP-003
    Category: Backup
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

Write-Verbose "[BACKUP-003] Starting VSS writer health check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[BACKUP-003] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[BACKUP-003] Checking VSS writers on: $($dc.Name)"
        
        try {
            # Get VSS writer status
            $vssOutput = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                & vssadmin list writers 2>&1 | Out-String
            } -ErrorAction Stop
            
            # Parse VSS output
            $writers = @()
            $currentWriter = $null
            
            foreach ($line in ($vssOutput -split "`n")) {
                if ($line -match "Writer name: '(.+)'") {
                    if ($currentWriter) {
                        $writers += $currentWriter
                    }
                    $currentWriter = @{
                        Name = $matches[1]
                        State = "Unknown"
                        LastError = "Unknown"
                    }
                }
                elseif ($line -match "State: \[(\d+)\] (.+)") {
                    if ($currentWriter) {
                        $currentWriter.State = $matches[2]
                    }
                }
                elseif ($line -match "Last error: (.+)") {
                    if ($currentWriter) {
                        $currentWriter.LastError = $matches[1]
                    }
                }
            }
            
            if ($currentWriter) {
                $writers += $currentWriter
            }
            
            # Analyze writers
            $totalWriters = $writers.Count
            $stableWriters = ($writers | Where-Object { $_.State -eq 'Stable' }).Count
            $failedWriters = ($writers | Where-Object { $_.State -ne 'Stable' }).Count
            
            $failedWritersList = $writers | Where-Object { $_.State -ne 'Stable' } | 
                ForEach-Object { "$($_.Name) ($($_.State))" }
            
            # Determine status
            $hasIssue = ($failedWriters -gt 0)
            $severity = if ($failedWriters -gt 3) { 'Critical' }
                       elseif ($failedWriters -gt 0) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                TotalWriters = $totalWriters
                StableWriters = $stableWriters
                FailedWriters = $failedWriters
                FailedWritersList = if ($failedWritersList) { ($failedWritersList -join "; ") } else { "None" }
                Severity = $severity
                Status = if ($failedWriters -gt 3) { 'Failed' }
                        elseif ($failedWriters -gt 0) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($failedWriters -gt 3) {
                    "CRITICAL: $failedWriters VSS writers failed! Backups may fail!"
                }
                elseif ($failedWriters -gt 0) {
                    "WARNING: $failedWriters VSS writer(s) not stable"
                }
                else {
                    "All $totalWriters VSS writers stable"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[BACKUP-003] Failed to check VSS writers on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                TotalWriters = 0
                StableWriters = 0
                FailedWriters = 0
                FailedWritersList = "Unknown"
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query VSS writers: $_"
            }
        }
    }
    
    Write-Verbose "[BACKUP-003] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[BACKUP-003] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        TotalWriters = 0
        StableWriters = 0
        FailedWriters = 0
        FailedWritersList = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
