<#
.SYNOPSIS
    Transaction Log Size Check (DB-003)

.DESCRIPTION
    Monitors NTDS database transaction log size and growth.
    Excessive log files indicate replication or backup issues.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DB-003
    Category: Database
    Severity: Medium
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
$warningLogCount = 100
$criticalLogCount = 1000
$warningLogSizeGB = 5
$criticalLogSizeGB = 10

Write-Verbose "[DB-003] Starting transaction log size check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DB-003] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DB-003] Checking transaction logs on: $($dc.Name)"
        
        try {
            # Get log directory path
            $logPath = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
                $dbLogPath = (Get-ItemProperty -Path $regPath -Name "Database log files path")."Database log files path"
                return $dbLogPath
            } -ErrorAction Stop
            
            # Get log files
            $logFiles = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                param($Path)
                
                if (Test-Path $Path) {
                    $logs = Get-ChildItem -Path $Path -Filter "*.log" -ErrorAction SilentlyContinue
                    
                    $stats = @{
                        LogCount = $logs.Count
                        TotalSizeBytes = ($logs | Measure-Object -Property Length -Sum).Sum
                        OldestLog = ($logs | Sort-Object CreationTime | Select-Object -First 1).CreationTime
                        NewestLog = ($logs | Sort-Object CreationTime | Select-Object -Last 1).CreationTime
                    }
                    
                    return $stats
                }
                else {
                    return $null
                }
            } -ArgumentList $logPath -ErrorAction Stop
            
            if (-not $logFiles) {
                $result = [PSCustomObject]@{
                    DomainController = $dc.Name
                    LogPath = $logPath
                    LogCount = 0
                    TotalLogSizeGB = 0
                    OldestLogDate = $null
                    NewestLogDate = $null
                    Severity = 'Medium'
                    Status = 'Warning'
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "Could not access log directory"
                }
                
                $results += $result
                continue
            }
            
            $logCount = $logFiles.LogCount
            $totalSizeGB = [math]::Round($logFiles.TotalSizeBytes / 1GB, 2)
            
            # Determine status
            $hasIssue = ($logCount -gt $warningLogCount -or $totalSizeGB -gt $warningLogSizeGB)
            $severity = if ($logCount -gt $criticalLogCount -or $totalSizeGB -gt $criticalLogSizeGB) { 'Critical' }
                       elseif ($logCount -gt $warningLogCount -or $totalSizeGB -gt $warningLogSizeGB) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                LogPath = $logPath
                LogCount = $logCount
                TotalLogSizeGB = $totalSizeGB
                OldestLogDate = $logFiles.OldestLog
                NewestLogDate = $logFiles.NewestLog
                Severity = $severity
                Status = if ($logCount -gt $criticalLogCount -or $totalSizeGB -gt $criticalLogSizeGB) { 'Failed' }
                        elseif ($hasIssue) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($logCount -gt $criticalLogCount) {
                    "CRITICAL: $logCount transaction logs ($totalSizeGB GB) - replication or backup issue!"
                }
                elseif ($totalSizeGB -gt $criticalLogSizeGB) {
                    "CRITICAL: Transaction logs consuming $totalSizeGB GB!"
                }
                elseif ($logCount -gt $warningLogCount) {
                    "WARNING: $logCount transaction logs ($totalSizeGB GB) accumulating"
                }
                elseif ($totalSizeGB -gt $warningLogSizeGB) {
                    "WARNING: Transaction logs consuming $totalSizeGB GB"
                }
                else {
                    "Transaction logs normal ($logCount files, $totalSizeGB GB)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DB-003] Failed to check logs on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                LogPath = "Unknown"
                LogCount = 0
                TotalLogSizeGB = 0
                OldestLogDate = $null
                NewestLogDate = $null
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query transaction logs: $_"
            }
        }
    }
    
    Write-Verbose "[DB-003] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DB-003] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        LogPath = "Unknown"
        LogCount = 0
        TotalLogSizeGB = 0
        OldestLogDate = $null
        NewestLogDate = $null
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
