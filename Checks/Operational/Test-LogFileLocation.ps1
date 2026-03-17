<#
.SYNOPSIS
    Log File Location Check (OPS-007)

.DESCRIPTION
    Checks that NTDS transaction logs are stored on a dedicated volume, ideally
    separate from both the OS and the NTDS.dit database. Uses remote registry
    via WMI StdRegProv.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-007
    Category: Operational
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

Write-Verbose "[OPS-007] Starting NTDS log file location check..."

$reachableDCs = @($Inventory.DomainControllers | Where-Object { $_.IsReachable -eq $true })

if ($reachableDCs.Count -eq 0) {
    return @([PSCustomObject]@{
        DomainController = 'N/A'
        LogPath          = 'N/A'
        DatabasePath     = 'N/A'
        LogsOnSameDrive  = $false
        LogsOnSystemDrive = $false
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = 'No reachable domain controllers found'
    })
}

foreach ($dc in $reachableDCs) {
    $dcName = $dc.Name
    Write-Verbose "[OPS-007] Checking log file location on: $dcName"

    try {
        $regPath = 'SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
        $HKLM = 2147483650
        $wmiReg = [WMIClass]"\\$dcName\root\default:StdRegProv"

        $logResult = $wmiReg.GetStringValue($HKLM, $regPath, 'Database log files path')
        $dbResult  = $wmiReg.GetStringValue($HKLM, $regPath, 'DSA Database file')

        $logPath = $logResult.sValue
        $dbPath  = $dbResult.sValue

        if ([string]::IsNullOrEmpty($logPath)) {
            $results += [PSCustomObject]@{
                DomainController  = $dcName
                LogPath           = 'Not found'
                DatabasePath      = $dbPath
                LogsOnSameDrive   = $false
                LogsOnSystemDrive = $false
                IsHealthy         = $false
                HasIssue          = $true
                Status            = 'Error'
                Severity          = 'Error'
                Message           = "Could not read log files path from registry on $dcName"
            }
            continue
        }

        $logPathUpper = $logPath.ToUpper()
        $dbPathUpper  = if ([string]::IsNullOrEmpty($dbPath)) { '' } else { $dbPath.ToUpper() }

        $logsOnSystemDrive = $false
        if ($logPathUpper.StartsWith('C:\')) {
            $logsOnSystemDrive = $true
        }

        $logsOnSameDrive = $false
        if (-not [string]::IsNullOrEmpty($dbPathUpper)) {
            $logDrive = $logPathUpper.Substring(0, 2)
            $dbDrive  = $dbPathUpper.Substring(0, 2)
            if ($logDrive -eq $dbDrive) {
                $logsOnSameDrive = $true
            }
        }

        if ($logsOnSystemDrive) {
            $results += [PSCustomObject]@{
                DomainController  = $dcName
                LogPath           = $logPath
                DatabasePath      = $dbPath
                LogsOnSameDrive   = $logsOnSameDrive
                LogsOnSystemDrive = $true
                IsHealthy         = $false
                HasIssue          = $true
                Status            = 'Warning'
                Severity          = 'Medium'
                Message           = "NTDS logs on $dcName are on the system drive: $logPath"
            }
        } elseif ($logsOnSameDrive) {
            $results += [PSCustomObject]@{
                DomainController  = $dcName
                LogPath           = $logPath
                DatabasePath      = $dbPath
                LogsOnSameDrive   = $true
                LogsOnSystemDrive = $false
                IsHealthy         = $false
                HasIssue          = $true
                Status            = 'Warning'
                Severity          = 'Low'
                Message           = "NTDS logs on $dcName share the same drive as the database: $logPath"
            }
        } else {
            $results += [PSCustomObject]@{
                DomainController  = $dcName
                LogPath           = $logPath
                DatabasePath      = $dbPath
                LogsOnSameDrive   = $false
                LogsOnSystemDrive = $false
                IsHealthy         = $true
                HasIssue          = $false
                Status            = 'Pass'
                Severity          = 'Info'
                Message           = "NTDS logs on $dcName are on a dedicated volume: $logPath"
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            DomainController  = $dcName
            LogPath           = 'Error'
            DatabasePath      = 'Error'
            LogsOnSameDrive   = $false
            LogsOnSystemDrive = $false
            IsHealthy         = $false
            HasIssue          = $true
            Status            = 'Error'
            Severity          = 'Error'
            Message           = "Failed to check log file location on $dcName - $_"
        }
    }
}

Write-Verbose "[OPS-007] Check complete. DCs checked: $($results.Count)"
return $results
