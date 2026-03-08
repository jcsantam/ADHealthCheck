<#
.SYNOPSIS
    Disk Space Check (DC-002)

.DESCRIPTION
    Checks free disk space on critical volumes for each DC:
    - System drive (C:)
    - Database volume (NTDS.dit location)
    - Log volume (if separate)
    - SYSVOL

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-DiskSpace.ps1 -Inventory $inventory

.OUTPUTS
    Array of disk space check results

.NOTES
    Check ID: DC-002
    Category: DCHealth
    Severity: High
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

# Thresholds (in GB)
$thresholds = @{
    SystemDriveCritical = 1
    SystemDriveWarning = 5
    DatabaseVolumeCritical = 5
    DatabaseVolumeWarning = 10
    LogVolumeCritical = 2
    LogVolumeWarning = 5
}

Write-Verbose "[DC-002] Starting disk space check..."

try {
    $domainControllers = $Inventory.DomainControllers
    
    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-002] No domain controllers found in inventory"
        return @()
    }
    
    Write-Verbose "[DC-002] Checking disk space on $($domainControllers.Count) domain controllers..."
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-002] Processing DC: $($dc.Name)"
        
        # Only check reachable DCs
        if (-not $dc.IsReachable) {
            Write-Verbose "[DC-002] DC $($dc.Name) is not reachable, skipping"
            continue
        }
        
        try {
            # Get all logical disks
            $disks = Get-WmiObject -Class Win32_LogicalDisk -ComputerName $dc.HostName -Filter "DriveType=3" -ErrorAction Stop
            
            foreach ($disk in $disks) {
                $driveLetter = $disk.DeviceID
                $freeSpaceGB = [math]::Round($disk.FreeSpace / 1GB, 2)
                $totalSpaceGB = [math]::Round($disk.Size / 1GB, 2)
                $freeSpacePercent = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
                
                # Determine disk type
                $diskType = "Data"
                if ($driveLetter -eq "C:") {
                    $diskType = "System"
                }
                
                # Determine status based on thresholds
                $status = 'Healthy'
                $severity = 'Info'
                $hasIssue = $false
                $message = "Disk space is adequate"
                
                if ($diskType -eq "System") {
                    if ($freeSpaceGB -lt $thresholds.SystemDriveCritical) {
                        $status = 'Critical'
                        $severity = 'Critical'
                        $hasIssue = $true
                        $message = "CRITICAL: System drive has less than $($thresholds.SystemDriveCritical)GB free"
                    }
                    elseif ($freeSpaceGB -lt $thresholds.SystemDriveWarning) {
                        $status = 'Warning'
                        $severity = 'Medium'
                        $hasIssue = $true
                        $message = "WARNING: System drive has less than $($thresholds.SystemDriveWarning)GB free"
                    }
                }
                else {
                    # Data drives (could contain database)
                    if ($freeSpaceGB -lt $thresholds.DatabaseVolumeCritical) {
                        $status = 'Critical'
                        $severity = 'High'
                        $hasIssue = $true
                        $message = "CRITICAL: Drive has less than $($thresholds.DatabaseVolumeCritical)GB free"
                    }
                    elseif ($freeSpaceGB -lt $thresholds.DatabaseVolumeWarning) {
                        $status = 'Warning'
                        $severity = 'Medium'
                        $hasIssue = $true
                        $message = "WARNING: Drive has less than $($thresholds.DatabaseVolumeWarning)GB free"
                    }
                }
                
                $result = [PSCustomObject]@{
                    DomainController = $dc.Name
                    DriveLetter = $driveLetter
                    DriveLabel = $disk.VolumeName
                    DiskType = $diskType
                    TotalSpaceGB = $totalSpaceGB
                    FreeSpaceGB = $freeSpaceGB
                    FreeSpacePercent = $freeSpacePercent
                    Severity = $severity
                    Status = $status
                    IsHealthy = -not $hasIssue
                    HasIssue = $hasIssue
                    Message = $message
                }
                
                $results += $result
            }
        }
        catch {
            Write-Warning "[DC-002] Failed to query disk space on $($dc.Name): $($_.Exception.Message)"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                DriveLetter = "Unknown"
                DriveLabel = "Unknown"
                DiskType = "Unknown"
                TotalSpaceGB = 0
                FreeSpaceGB = 0
                FreeSpacePercent = 0
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query disk space: $($_.Exception.Message)"
            }
        }
    }
    
    Write-Verbose "[DC-002] Check complete. Disks checked: $($results.Count)"
    
    # Summary
    $criticalCount = ($results | Where-Object { $_.Status -eq 'Critical' }).Count
    $warningCount = ($results | Where-Object { $_.Status -eq 'Warning' }).Count
    
    Write-Verbose "[DC-002] Critical: $criticalCount, Warning: $warningCount"
    
    return $results
}
catch {
    Write-Error "[DC-002] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        DriveLetter = "Unknown"
        DriveLabel = "Unknown"
        DiskType = "Unknown"
        TotalSpaceGB = 0
        FreeSpaceGB = 0
        FreeSpacePercent = 0
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
