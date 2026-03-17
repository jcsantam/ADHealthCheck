<#
.SYNOPSIS
    Windows Update Status Check (DC-019)

.DESCRIPTION
    Checks the Windows Update status on each domain controller to detect
    DCs that have not received updates recently. Unpatched DCs are vulnerable
    to known exploits and may be non-compliant with security policies.

    Checks:
    - Last successful Windows Update search date (registry)
    - Last successful update installation date
    - Whether a reboot is pending due to Windows Updates
    - Flags DCs where updates have not been installed in 90+ days

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-WindowsUpdateStatus.ps1 -Inventory $inventory

.OUTPUTS
    Array of Windows Update status results per DC

.NOTES
    Check ID: DC-019
    Category: DCHealth
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

Write-Verbose "[DC-019] Starting Windows Update status check..."

$HKLM           = [uint32]'0x80000002'
$WU_REG_KEY     = 'SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\Results\Install'
$WU_LAST_KEY    = 'LastSuccessTime'
$REBOOT_REG_KEY = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$staleThreshold = 90  # days

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-019] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[DC-019] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[DC-019] Checking Windows Update status on: $dcName"

        try {
            $reg = $null
            try {
                $reg = [WMIClass]"\\$dcName\root\default:StdRegProv"
            } catch {
                Write-Verbose "[DC-019] StdRegProv unavailable on $dcName"
            }

            $lastInstallDate = $null
            $rebootPending   = $false
            $issues          = @()

            if ($reg) {
                # Last successful install date
                $r = $reg.GetStringValue($HKLM, $WU_REG_KEY, $WU_LAST_KEY)
                if ($r.ReturnValue -eq 0 -and $r.sValue) {
                    try {
                        $lastInstallDate = [datetime]::Parse($r.sValue)
                    } catch { }
                }

                # Reboot pending check
                $rebootCheck = $reg.GetDWORDValue($HKLM, $REBOOT_REG_KEY, 'RebootRequired')
                if ($rebootCheck.ReturnValue -eq 0) {
                    $rebootPending = $true
                }

                # Also check alternative reboot pending key
                if (-not $rebootPending) {
                    $altReboot = $reg.GetStringValue($HKLM,
                        'SYSTEM\CurrentControlSet\Control\Session Manager', 'PendingFileRenameOperations')
                    if ($altReboot.ReturnValue -eq 0 -and $altReboot.sValue) {
                        $rebootPending = $true
                    }
                }
            }

            # Evaluate results
            if ($lastInstallDate -eq $null) {
                $issues += "Cannot determine last Windows Update install date - verify Windows Update is configured"
                $daysSinceUpdate = $null
            } else {
                $daysSinceUpdate = [math]::Round(((Get-Date) - $lastInstallDate).TotalDays)
                if ($daysSinceUpdate -gt $staleThreshold) {
                    $issues += "Last Windows Update installation was $daysSinceUpdate days ago ($($lastInstallDate.ToString('yyyy-MM-dd'))) - exceeds $staleThreshold day threshold"
                }
            }

            if ($rebootPending) {
                $issues += "Reboot is pending due to Windows Updates - DC should be rebooted during maintenance window"
            }

            $hasIssue = ($issues.Count -gt 0)
            $status   = if ($hasIssue) { if ($lastInstallDate -eq $null) { 'Warning' } else { 'Fail' } } else { 'Pass' }
            $severity = if ($daysSinceUpdate -ne $null -and $daysSinceUpdate -gt 180) { 'Critical' } `
                        elseif ($hasIssue) { 'High' } else { 'Info' }

            $lastInstallStr = if ($lastInstallDate) { $lastInstallDate.ToString('yyyy-MM-dd') } else { 'Unknown' }
            $daysSinceStr   = if ($daysSinceUpdate -ne $null) { "$daysSinceUpdate days ago" } else { 'Unknown' }

            $message = if ($hasIssue) {
                "DC $dcName Windows Update issues: $($issues -join '; ')"
            } else {
                "DC $dcName Windows Update is current (last install: $lastInstallStr, $daysSinceStr; reboot pending: $rebootPending)"
            }

            $results += [PSCustomObject]@{
                DomainController  = $dcName
                LastInstallDate   = $lastInstallStr
                DaysSinceUpdate   = $daysSinceUpdate
                RebootPending     = $rebootPending
                HasIssue          = $hasIssue
                Status            = $status
                Severity          = $severity
                IsHealthy         = -not $hasIssue
                Message           = $message
            }
        }
        catch {
            Write-Warning "[DC-019] Failed to check Windows Update on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController  = $dcName
                LastInstallDate   = 'Unknown'
                DaysSinceUpdate   = $null
                RebootPending     = $false
                HasIssue          = $true
                Status            = 'Error'
                Severity          = 'Error'
                IsHealthy         = $false
                Message           = "Failed to check Windows Update status on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DC-019] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-019] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController  = 'Unknown'
        LastInstallDate   = 'Unknown'
        DaysSinceUpdate   = $null
        RebootPending     = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        IsHealthy         = $false
        Message           = "Check execution failed: $($_.Exception.Message)"
    })
}
