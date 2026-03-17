<#
.SYNOPSIS
    DIT File Location Check (OPS-006)

.DESCRIPTION
    Checks that the NTDS.dit database file is NOT stored on the system drive (C:\).
    Storing the database on the system drive risks corruption during OS updates and
    reduces I/O performance. Uses remote registry via WMI StdRegProv.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-006
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

Write-Verbose "[OPS-006] Starting DIT file location check..."

$reachableDCs = @($Inventory.DomainControllers | Where-Object { $_.IsReachable -eq $true })

if ($reachableDCs.Count -eq 0) {
    return @([PSCustomObject]@{
        DomainController = 'N/A'
        DatabasePath     = 'N/A'
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
    Write-Verbose "[OPS-006] Checking DIT location on: $dcName"

    try {
        $regPath = 'SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
        $regValue = 'DSA Database file'

        $wmiReg = [WMIClass]"\\$dcName\root\default:StdRegProv"
        $HKLM = 2147483650

        $result = $wmiReg.GetStringValue($HKLM, $regPath, $regValue)
        $dbPath = $result.sValue

        if ([string]::IsNullOrEmpty($dbPath)) {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                DatabasePath     = 'Not found'
                IsOnSystemDrive  = $false
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                Message          = "Could not read DSA Database file path from registry on $dcName"
            }
            continue
        }

        $dbPathUpper = $dbPath.ToUpper()
        $isOnSystemDrive = $false

        if ($dbPathUpper.StartsWith('C:\')) {
            $isOnSystemDrive = $true
        }

        if ($isOnSystemDrive) {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                DatabasePath     = $dbPath
                IsOnSystemDrive  = $true
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Warning'
                Severity         = 'Medium'
                Message          = "NTDS.dit on $dcName is stored on the system drive: $dbPath"
            }
        } else {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                DatabasePath     = $dbPath
                IsOnSystemDrive  = $false
                IsHealthy        = $true
                HasIssue         = $false
                Status           = 'Pass'
                Severity         = 'Info'
                Message          = "NTDS.dit on $dcName is on a dedicated volume: $dbPath"
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            DomainController = $dcName
            DatabasePath     = 'Error'
            IsOnSystemDrive  = $false
            IsHealthy        = $false
            HasIssue         = $true
            Status           = 'Error'
            Severity         = 'Error'
            Message          = "Failed to check DIT location on $dcName - $_"
        }
    }
}

Write-Verbose "[OPS-006] Check complete. DCs checked: $($results.Count)"
return $results
