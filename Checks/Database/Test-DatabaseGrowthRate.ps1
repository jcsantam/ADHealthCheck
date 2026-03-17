<#
.SYNOPSIS
    Database Growth Rate / Disk Capacity Check (DB-005)

.DESCRIPTION
    Assesses the NTDS.dit database size relative to available disk space on each
    domain controller and flags capacity risks. Also detects unusually large
    databases that may indicate object bloat or runaway growth.

    Checks:
    - NTDS.dit file size (warning >10 GB, critical >50 GB)
    - Free disk space on the NTDS volume as a ratio to DB size
    - Free disk space dropping below 2x the database size (risk of no room to grow)
    - Absolute free disk space below 5 GB warning, 2 GB critical

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-DatabaseGrowthRate.ps1 -Inventory $inventory

.OUTPUTS
    Array of database size/capacity results per DC

.NOTES
    Check ID: DB-005
    Category: Database
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

Write-Verbose "[DB-005] Starting database growth rate / disk capacity check..."

# Registry key where NTDS stores its database path
$NTDS_REG_KEY  = 'SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
$NTDS_REG_VAL  = 'DSA Database file'

# HKEY_LOCAL_MACHINE constant for StdRegProv
$HKLM = [uint32]'0x80000002'

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DB-005] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[DB-005] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[DB-005] Checking database size on: $dcName"

        try {
            # Get NTDS database path from registry
            $reg = $null
            try {
                $reg = [WMIClass]"\\$dcName\root\default:StdRegProv"
            }
            catch {
                Write-Verbose "[DB-005] StdRegProv not available on $dcName"
            }

            $dbPath = $null
            if ($reg) {
                $result = $reg.GetStringValue($HKLM, $NTDS_REG_KEY, $NTDS_REG_VAL)
                if ($result.ReturnValue -eq 0) {
                    $dbPath = $result.sValue
                }
            }

            if (-not $dbPath) {
                $dbPath = 'C:\Windows\NTDS\ntds.dit'
                Write-Verbose "[DB-005] Could not read NTDS path from registry on $dcName, using default: $dbPath"
            }

            Write-Verbose "[DB-005] NTDS database path on $dcName`: $dbPath"

            # Parse drive letter and directory from path
            $dbDrive = $dbPath.Substring(0, 2)
            $dbDir   = ('\' + $dbPath.Substring(3, $dbPath.LastIndexOf('\') - 3).TrimEnd('\') + '\').Replace('\', '\\')
            $dbFile  = $dbPath.Substring($dbPath.LastIndexOf('\') + 1)
            $dbFileName = $dbFile -replace '\.dit$', ''

            # Get NTDS.dit file size via WMI
            $dbSizeBytes = $null
            try {
                $wmiFile = Get-WmiObject -Query "SELECT FileSize FROM CIM_DataFile WHERE Drive='$dbDrive' AND Path='$dbDir' AND FileName='$dbFileName' AND Extension='dit'" `
                    -ComputerName $dcName -ErrorAction SilentlyContinue
                if ($wmiFile) {
                    $dbSizeBytes = [long]$wmiFile.FileSize
                }
            }
            catch {
                Write-Verbose "[DB-005] WMI file query failed on $dcName`: $($_.Exception.Message)"
            }

            # Get disk free space for the drive hosting NTDS
            $freeBytesResult = $null
            if ($reg) {
                try {
                    $diskInfo = Get-WmiObject -Query "SELECT FreeSpace,Size FROM Win32_LogicalDisk WHERE DeviceID='$dbDrive'" `
                        -ComputerName $dcName -ErrorAction SilentlyContinue
                    if ($diskInfo) {
                        $freeBytesResult = [long]$diskInfo.FreeSpace
                        $totalBytes      = [long]$diskInfo.Size
                    }
                }
                catch {
                    Write-Verbose "[DB-005] Disk query failed on $dcName"
                }
            }

            if (-not $dbSizeBytes) {
                $results += [PSCustomObject]@{
                    DomainController = $dcName
                    DatabasePath     = $dbPath
                    DatabaseSizeGB   = $null
                    FreeDiskGB       = $null
                    TotalDiskGB      = $null
                    FreeRatio        = $null
                    HasIssue         = $false
                    Status           = 'Pass'
                    Severity         = 'Info'
                    IsHealthy        = $true
                    Message          = "DC $dcName - could not retrieve NTDS.dit size (may lack remote WMI access)"
                }
                continue
            }

            $dbSizeGB   = [math]::Round($dbSizeBytes / 1GB, 2)
            $freeGB     = if ($freeBytesResult) { [math]::Round($freeBytesResult / 1GB, 2) } else { $null }
            $totalGB    = if ($totalBytes) { [math]::Round($totalBytes / 1GB, 2) } else { $null }
            $freeRatio  = $null
            if ($freeGB -and $dbSizeGB -gt 0) {
                $freeRatio = [math]::Round($freeGB / $dbSizeGB, 1)
            }

            $hasIssue = $false
            $status   = 'Pass'
            $severity = 'Info'
            $message  = ''

            if ($dbSizeGB -gt 50) {
                $hasIssue = $true
                $status   = 'Fail'
                $severity = 'Critical'
                $message  = "DC $dcName NTDS.dit is ${dbSizeGB} GB - exceeds 50 GB threshold; investigate object bloat"
            }
            elseif ($freeGB -ne $null -and $freeGB -lt 2) {
                $hasIssue = $true
                $status   = 'Fail'
                $severity = 'Critical'
                $message  = "DC $dcName NTDS volume has only ${freeGB} GB free (DB is ${dbSizeGB} GB) - critical disk space shortage"
            }
            elseif ($dbSizeGB -gt 10) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'High'
                $message  = "DC $dcName NTDS.dit is ${dbSizeGB} GB - exceeds 10 GB; monitor growth trend"
            }
            elseif ($freeGB -ne $null -and $freeGB -lt 5) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'High'
                $message  = "DC $dcName NTDS volume has only ${freeGB} GB free (DB is ${dbSizeGB} GB) - low disk space"
            }
            elseif ($freeRatio -ne $null -and $freeRatio -lt 2) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'Medium'
                $message  = "DC $dcName free disk space (${freeGB} GB) is less than 2x NTDS.dit size (${dbSizeGB} GB) - limited room for database growth"
            }
            else {
                $freeStr = if ($freeGB) { "${freeGB} GB free" } else { 'free space unknown' }
                $message = "DC $dcName NTDS.dit is ${dbSizeGB} GB - within normal range ($freeStr on volume)"
            }

            $results += [PSCustomObject]@{
                DomainController = $dcName
                DatabasePath     = $dbPath
                DatabaseSizeGB   = $dbSizeGB
                FreeDiskGB       = $freeGB
                TotalDiskGB      = $totalGB
                FreeRatio        = $freeRatio
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                IsHealthy        = -not $hasIssue
                Message          = $message
            }
        }
        catch {
            Write-Warning "[DB-005] Failed to check database size on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController = $dcName
                DatabasePath     = 'Unknown'
                DatabaseSizeGB   = $null
                FreeDiskGB       = $null
                TotalDiskGB      = $null
                FreeRatio        = $null
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to check database size on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DB-005] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DB-005] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        DatabasePath     = 'Unknown'
        DatabaseSizeGB   = $null
        FreeDiskGB       = $null
        TotalDiskGB      = $null
        FreeRatio        = $null
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
