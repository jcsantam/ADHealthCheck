<#
.SYNOPSIS
    NTDS Database White Space Analysis (DB-004)
.DESCRIPTION
    Checks NTDS.dit database size and transaction log file accumulation on each
    domain controller. Uses remote registry (via WMI StdRegProv) to locate the
    database path, then queries file size via WMI CIM_DataFile.
    High log file counts indicate replication or backup issues.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DB-004
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

$logCountWarning  = 200
$logCountCritical = 1000

Write-Verbose "[DB-004] Starting NTDS white space analysis..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DB-004] No reachable DCs found"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DB-004] Checking NTDS database on: $($dc.Name)"

        try {
            # Read NTDS database path from remote registry via WMI StdRegProv
            $HKLM     = [uint32]2147483650
            $regKey   = 'SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
            $regClass = [WMIClass]"\\$($dc.Name)\root\default:StdRegProv"

            $dbPathResult  = $regClass.GetStringValue($HKLM, $regKey, 'DSA Database file')
            $logPathResult = $regClass.GetStringValue($HKLM, $regKey, 'Database log files path')

            $dbPath  = $dbPathResult.sValue
            $logPath = $logPathResult.sValue

            if (-not $dbPath) {
                # Fallback default path
                $dbPath = 'C:\Windows\NTDS\ntds.dit'
            }
            if (-not $logPath) {
                $logPath = [System.IO.Path]::GetDirectoryName($dbPath)
            }

            # Get database file size via WMI CIM_DataFile
            # Convert path for WMI: backslashes must be doubled
            $wmiDbPath = $dbPath -replace '\\', '\\'
            $dbFile    = Get-WmiObject -Query "SELECT FileSize FROM CIM_DataFile WHERE Name='$wmiDbPath'" `
                -ComputerName $dc.Name -ErrorAction SilentlyContinue |
                Select-Object -First 1

            $dbSizeBytes = if ($dbFile -and $dbFile.FileSize) { [long]$dbFile.FileSize } else { 0 }
            $dbSizeGB    = [math]::Round($dbSizeBytes / 1GB, 2)

            # Count transaction log files in the log directory
            # Escape path for WMI - backslashes doubled, colon kept
            $wmiLogPath = ($logPath.TrimEnd('\')) -replace '\\', '\\'
            $logFiles   = @(Get-WmiObject -Query "SELECT Name,FileSize FROM CIM_DataFile WHERE Drive='$($logPath.Substring(0,2))' AND Path='$($logPath.Substring(2).TrimEnd('\') -replace '\\', '\\' + '\\')' AND Extension='log' AND FileName LIKE 'edb%'" `
                -ComputerName $dc.Name -ErrorAction SilentlyContinue)

            # Simpler approach: count log files via WMI directory query
            if (@($logFiles).Count -eq 0) {
                # Try alternative query using the log directory path
                $logDrive = $logPath.Substring(0, 2)
                $logDir   = '\' + $logPath.Substring(3).TrimEnd('\') + '\'
                $logDir   = $logDir -replace '\\', '\\'
                $logFiles = @(Get-WmiObject -Query "SELECT Name FROM CIM_DataFile WHERE Drive='$logDrive' AND Path='$logDir' AND Extension='log'" `
                    -ComputerName $dc.Name -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '\\edb[0-9A-Fa-f]+\.log$|\\edb\.log$|\\edbtmp\.log$' })
            }

            $logFileCount = @($logFiles).Count
            $logSizeBytes = ($logFiles | ForEach-Object { [long]$_.FileSize } | Measure-Object -Sum).Sum
            $logSizeGB    = if ($logSizeBytes) { [math]::Round($logSizeBytes / 1GB, 2) } else { 0 }

            $hasIssue = $logFileCount -gt $logCountWarning
            $severity = if ($logFileCount -gt $logCountCritical) { 'Critical' }
                        elseif ($logFileCount -gt $logCountWarning) { 'High' }
                        else { 'Info' }
            $status   = if ($logFileCount -gt $logCountCritical) { 'Fail' }
                        elseif ($logFileCount -gt $logCountWarning) { 'Warning' }
                        else { 'Healthy' }

            $results += [PSCustomObject]@{
                DomainController        = $dc.Name
                DatabasePath            = $dbPath
                DatabaseSizeGB          = $dbSizeGB
                LogPath                 = $logPath
                LogFileSizeGB           = $logSizeGB
                LogFileCount            = $logFileCount
                EstimatedWhiteSpacePercent = 0   # Cannot determine without offline defrag
                IsHealthy               = -not $hasIssue
                HasIssue                = $hasIssue
                Status                  = $status
                Severity                = $severity
                Message                 = if ($logFileCount -gt $logCountCritical) {
                    "CRITICAL: $logFileCount transaction logs on $($dc.Name) - replication or backup issue likely"
                } elseif ($logFileCount -gt $logCountWarning) {
                    "WARNING: $logFileCount transaction logs on $($dc.Name) (threshold: $logCountWarning)"
                } else {
                    "$($dc.Name): NTDS.dit = $dbSizeGB GB, $logFileCount log files ($logSizeGB GB)"
                }
            }
        }
        catch {
            Write-Warning "[DB-004] Failed to check NTDS on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController           = $dc.Name
                DatabasePath               = 'Unknown'
                DatabaseSizeGB             = 0
                LogPath                    = 'Unknown'
                LogFileSizeGB              = 0
                LogFileCount               = 0
                EstimatedWhiteSpacePercent = 0
                IsHealthy                  = $false
                HasIssue                   = $true
                Status                     = 'Error'
                Severity                   = 'Error'
                Message                    = "Failed to query NTDS database on $($dc.Name): $_"
            }
        }
    }

    Write-Verbose "[DB-004] Check complete. DCs checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DB-004] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController           = 'Unknown'
        DatabasePath               = 'Unknown'
        DatabaseSizeGB             = 0
        LogPath                    = 'Unknown'
        LogFileSizeGB              = 0
        LogFileCount               = 0
        EstimatedWhiteSpacePercent = 0
        IsHealthy                  = $false
        HasIssue                   = $true
        Status                     = 'Error'
        Severity                   = 'Error'
        Message                    = "Check execution failed: $($_.Exception.Message)"
    })
}
