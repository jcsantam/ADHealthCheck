<#
.SYNOPSIS
    SYSVOL Location Check (OPS-008)

.DESCRIPTION
    Checks that SYSVOL is not stored on the system drive. SYSVOL holds GPO templates
    and logon scripts - keeping it on the OS volume reduces performance and risks data
    loss if that volume fails. Uses remote registry via WMI StdRegProv.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-008
    Category: Operational
    Severity: Low
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'

$results = @()

Write-Verbose "[OPS-008] Starting SYSVOL location check..."

$reachableDCs = @($Inventory.DomainControllers | Where-Object { $_.IsReachable -eq $true })

if ($reachableDCs.Count -eq 0) {
    return @([PSCustomObject]@{
        DomainController = 'N/A'
        SYSVOLPath       = 'N/A'
        IsOnSystemDrive  = $false
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = 'No reachable domain controllers found'
    })
}

foreach ($dc in $reachableDCs) {
    $dcName = $dc.Name
    Write-Verbose "[OPS-008] Checking SYSVOL location on: $dcName"

    try {
        $regPath = 'SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
        $HKLM = 2147483650
        $wmiReg = [WMIClass]"\\$dcName\root\default:StdRegProv"

        $sysvolResult = $wmiReg.GetStringValue($HKLM, $regPath, 'SysVol')
        $sysvolPath   = $sysvolResult.sValue

        if ([string]::IsNullOrEmpty($sysvolPath)) {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                SYSVOLPath       = 'Not found'
                IsOnSystemDrive  = $false
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                Message          = "Could not read SysVol path from registry on $dcName"
            }
            continue
        }

        $sysvolUpper = $sysvolPath.ToUpper()
        $isOnSystemDrive = $false
        if ($sysvolUpper.StartsWith('C:\')) {
            $isOnSystemDrive = $true
        }

        if ($isOnSystemDrive) {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                SYSVOLPath       = $sysvolPath
                IsOnSystemDrive  = $true
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Warning'
                Severity         = 'Low'
                Message          = "SYSVOL on $dcName is stored on the system drive: $sysvolPath"
            }
        } else {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                SYSVOLPath       = $sysvolPath
                IsOnSystemDrive  = $false
                IsHealthy        = $true
                HasIssue         = $false
                Status           = 'Pass'
                Severity         = 'Info'
                Message          = "SYSVOL on $dcName is on a dedicated volume: $sysvolPath"
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            DomainController = $dcName
            SYSVOLPath       = 'Error'
            IsOnSystemDrive  = $false
            IsHealthy        = $false
            HasIssue         = $true
            Status           = 'Error'
            Severity         = 'Error'
            Message          = "Failed to check SYSVOL location on $dcName - $_"
        }
    }
}

Write-Verbose "[OPS-008] Check complete. DCs checked: $($results.Count)"
return $results
