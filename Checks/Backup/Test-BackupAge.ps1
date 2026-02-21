<#
.SYNOPSIS
    System State Backup Age Check (BACKUP-001)

.DESCRIPTION
    Validates system state backup recency vs tombstone lifetime:
    - Last successful backup timestamp
    - Backup age vs tombstone lifetime (critical threshold)
    - Backup location and accessibility
    - Windows Server Backup status
    - Tombstone lifetime configuration

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-BackupAge.ps1 -Inventory $inventory

.OUTPUTS
    Array of backup age results

.NOTES
    Check ID: BACKUP-001
    Category: Backup
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[BACKUP-001] Starting system state backup age check..."

try {
    $domainControllers = $Inventory.DomainControllers
    
    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[BACKUP-001] No domain controllers found in inventory"
        return @()
    }
    
    # Get tombstone lifetime from forest
    $forestDN = $Inventory.ForestInfo.RootDomain
    $configDN = "CN=Configuration," + (Get-ADDomain -Server $forestDN).DistinguishedName.Replace("DC=$($forestDN.Split('.')[0]),", "")
    
    try {
        $directoryService = Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$configDN" `
            -Properties tombstoneLifetime -Server $forestDN -ErrorAction Stop
        
        $tombstoneLifetime = if ($directoryService.tombstoneLifetime) {
            $directoryService.tombstoneLifetime
        } else {
            180  # Default is 180 days
        }
    }
    catch {
        $tombstoneLifetime = 180
        Write-Verbose "[BACKUP-001] Could not query tombstone lifetime, using default: 180 days"
    }
    
    Write-Verbose "[BACKUP-001] Tombstone lifetime: $tombstoneLifetime days"
    Write-Verbose "[BACKUP-001] Checking backups on $($domainControllers.Count) domain controllers..."
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[BACKUP-001] Processing DC: $($dc.Name)"
        
        if (-not $dc.IsReachable) {
            Write-Verbose "[BACKUP-001] DC $($dc.Name) is not reachable, skipping"
            continue
        }
        
        try {
            # Check Windows Server Backup status
            $backupInfo = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                param($TombstoneLifetime)
                
                # Try to get last backup info from registry (Windows Server Backup)
                $wsbPolicy = $null
                $lastBackup = $null
                
                try {
                    # Check if Windows Server Backup feature is installed
                    $wsbFeature = Get-WindowsFeature -Name Windows-Server-Backup -ErrorAction SilentlyContinue
                    
                    if ($wsbFeature -and $wsbFeature.Installed) {
                        # Try to get backup info
                        $wsbInfo = & wbadmin get versions -quiet 2>&1 | Out-String
                        
                        if ($wsbInfo -match "Backup time:(.+)") {
                            $backupTimeStr = $matches[1].Trim()
                            try {
                                $lastBackup = [DateTime]::Parse($backupTimeStr)
                            }
                            catch {
                                # Try different date format
                                $lastBackup = $null
                            }
                        }
                    }
                }
                catch {
                    # WSB not installed or accessible
                }
                
                # Alternative: Check NTDS backup timestamp from registry
                if (-not $lastBackup) {
                    try {
                        $ntdsParams = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -ErrorAction Stop
                        $dbPath = $ntdsParams."DSA Database file"
                        
                        # Check backup directory
                        $dbDir = Split-Path $dbPath -Parent
                        $backupDir = Join-Path $dbDir "Backup"
                        
                        if (Test-Path $backupDir) {
                            $backupFiles = Get-ChildItem -Path $backupDir -Recurse -File | Sort-Object LastWriteTime -Descending
                            if ($backupFiles) {
                                $lastBackup = $backupFiles[0].LastWriteTime
                            }
                        }
                    }
                    catch {
                        # Can't determine backup
                    }
                }
                
                return @{
                    LastBackup = $lastBackup
                    WSBInstalled = ($wsbFeature -and $wsbFeature.Installed)
                }
            } -ArgumentList $tombstoneLifetime -ErrorAction Stop
            
            # Calculate backup age
            $lastBackupDate = $backupInfo.LastBackup
            $backupAgeDays = if ($lastBackupDate) {
                ((Get-Date) - $lastBackupDate).Days
            } else {
                999  # Unknown/never
            }
            
            # Determine status based on tombstone lifetime
            $criticalThreshold = [math]::Floor($tombstoneLifetime * 0.75)  # 75% of tombstone
            $warningThreshold = [math]::Floor($tombstoneLifetime * 0.50)   # 50% of tombstone
            
            $isHealthy = $true
            $severity = 'Info'
            $status = 'Healthy'
            
            if (-not $lastBackupDate) {
                $isHealthy = $false
                $severity = 'Critical'
                $status = 'Failed'
            }
            elseif ($backupAgeDays -gt $criticalThreshold) {
                $isHealthy = $false
                $severity = 'Critical'
                $status = 'Failed'
            }
            elseif ($backupAgeDays -gt $warningThreshold) {
                $isHealthy = $false
                $severity = 'High'
                $status = 'Warning'
            }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                LastBackupDate = $lastBackupDate
                BackupAgeDays = $backupAgeDays
                TombstoneLifetime = $tombstoneLifetime
                CriticalThreshold = $criticalThreshold
                WarningThreshold = $warningThreshold
                WSBInstalled = $backupInfo.WSBInstalled
                PercentOfTombstone = if ($lastBackupDate) {
                    [math]::Round(($backupAgeDays / $tombstoneLifetime) * 100, 1)
                } else {
                    100
                }
                Severity = $severity
                Status = $status
                IsHealthy = $isHealthy
                HasIssue = -not $isHealthy
                Message = if (-not $lastBackupDate) {
                    "CRITICAL: No system state backup found or backup age unknown"
                } elseif ($backupAgeDays -gt $criticalThreshold) {
                    "CRITICAL: Backup is $backupAgeDays days old (exceeds 75% of tombstone lifetime $tombstoneLifetime days)"
                } elseif ($backupAgeDays -gt $warningThreshold) {
                    "WARNING: Backup is $backupAgeDays days old (exceeds 50% of tombstone lifetime)"
                } else {
                    "Backup is current ($backupAgeDays days old, tombstone: $tombstoneLifetime days)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[BACKUP-001] Failed to check backup on $($dc.Name): $($_.Exception.Message)"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                LastBackupDate = $null
                BackupAgeDays = 999
                TombstoneLifetime = $tombstoneLifetime
                CriticalThreshold = 0
                WarningThreshold = 0
                WSBInstalled = $false
                PercentOfTombstone = 100
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to check backup status: $($_.Exception.Message)"
            }
        }
    }
    
    Write-Verbose "[BACKUP-001] Check complete. DCs checked: $($results.Count)"
    
    # Summary
    $criticalCount = ($results | Where-Object { $_.Severity -eq 'Critical' }).Count
    if ($criticalCount -gt 0) {
        Write-Warning "[BACKUP-001] CRITICAL: $criticalCount DC(s) with backup age issues!"
    }
    
    return $results
}
catch {
    Write-Error "[BACKUP-001] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        LastBackupDate = $null
        BackupAgeDays = 999
        TombstoneLifetime = 180
        CriticalThreshold = 0
        WarningThreshold = 0
        WSBInstalled = $false
        PercentOfTombstone = 100
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
