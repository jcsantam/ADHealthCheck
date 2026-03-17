<#
.SYNOPSIS
    Power Plan Configuration Check (DC-020)

.DESCRIPTION
    Verifies that domain controllers are running the High Performance power plan.
    DCs running Balanced or Power Saver power plans throttle CPU frequency,
    increasing authentication latency and potentially causing Kerberos timeouts
    under load.

    Microsoft recommends the High Performance power plan for all DCs.

    Power Plan GUIDs:
    - High Performance : 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
    - Balanced         : 381b4222-f694-41f0-9685-ff5bb260df2e
    - Power Saver      : a1841308-3541-4fab-bc81-f71556f20b4a

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-PowerPlanConfig.ps1 -Inventory $inventory

.OUTPUTS
    Array of power plan configuration results per DC

.NOTES
    Check ID: DC-020
    Category: DCHealth
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

Write-Verbose "[DC-020] Starting power plan configuration check..."

$HIGH_PERFORMANCE_GUID = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$BALANCED_GUID         = '381b4222-f694-41f0-9685-ff5bb260df2e'
$POWER_SAVER_GUID      = 'a1841308-3541-4fab-bc81-f71556f20b4a'

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-020] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[DC-020] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[DC-020] Checking power plan on: $dcName"

        try {
            $activePlan     = $null
            $activePlanName = 'Unknown'
            $activePlanGuid = 'Unknown'

            try {
                # Win32_PowerPlan is available via WMI root\cimv2\power namespace on 2012R2+
                $plans = @(Get-WmiObject -Namespace 'root\cimv2\power' `
                    -Class Win32_PowerPlan `
                    -ComputerName $dcName `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.IsActive -eq $true })

                if ($plans -and $plans.Count -gt 0) {
                    $activePlan = $plans[0]
                    $activePlanName = $activePlan.ElementName

                    # Extract GUID from InstanceID (format: Microsoft:PowerPlan\{GUID})
                    if ($activePlan.InstanceID -match '\{([^}]+)\}') {
                        $activePlanGuid = $matches[1].ToLower()
                    }
                }
            }
            catch {
                Write-Verbose "[DC-020] Win32_PowerPlan query failed on $dcName`: $($_.Exception.Message)"
            }

            # Fallback: use powercfg output via remote registry
            if ($activePlanGuid -eq 'Unknown') {
                try {
                    $HKLM = [uint32]'0x80000002'
                    $reg  = [WMIClass]"\\$dcName\root\default:StdRegProv"
                    $r    = $reg.GetStringValue($HKLM,
                        'SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes',
                        'ActivePowerScheme')
                    if ($r.ReturnValue -eq 0 -and $r.sValue) {
                        $activePlanGuid = $r.sValue.ToLower().Trim('{', '}')
                        switch ($activePlanGuid) {
                            $HIGH_PERFORMANCE_GUID { $activePlanName = 'High Performance' }
                            $BALANCED_GUID         { $activePlanName = 'Balanced' }
                            $POWER_SAVER_GUID      { $activePlanName = 'Power Saver' }
                            default                { $activePlanName = "Custom ($activePlanGuid)" }
                        }
                    }
                }
                catch {
                    Write-Verbose "[DC-020] Registry fallback also failed on $dcName"
                }
            }

            $isHighPerformance = ($activePlanGuid -eq $HIGH_PERFORMANCE_GUID)
            $isBalanced        = ($activePlanGuid -eq $BALANCED_GUID)
            $isPowerSaver      = ($activePlanGuid -eq $POWER_SAVER_GUID)

            $hasIssue = -not $isHighPerformance -and ($activePlanGuid -ne 'Unknown')
            $status   = if ($activePlanGuid -eq 'Unknown') { 'Pass' } elseif ($hasIssue) { 'Warning' } else { 'Pass' }
            $severity = if ($isPowerSaver) { 'High' } elseif ($isBalanced) { 'Medium' } elseif ($hasIssue) { 'Medium' } else { 'Info' }

            $message = if ($activePlanGuid -eq 'Unknown') {
                "DC $dcName - power plan could not be determined remotely"
            } elseif ($isHighPerformance) {
                "DC $dcName is using High Performance power plan - recommended configuration"
            } elseif ($isPowerSaver) {
                "DC $dcName is using Power Saver power plan - CPU throttling active; authentication latency will be elevated"
            } elseif ($isBalanced) {
                "DC $dcName is using Balanced power plan - CPU may throttle under authentication load; switch to High Performance"
            } else {
                "DC $dcName is using custom power plan '$activePlanName' ($activePlanGuid) - verify it does not throttle CPU"
            }

            $results += [PSCustomObject]@{
                DomainController   = $dcName
                PowerPlanName      = $activePlanName
                PowerPlanGuid      = $activePlanGuid
                IsHighPerformance  = $isHighPerformance
                HasIssue           = $hasIssue
                Status             = $status
                Severity           = $severity
                IsHealthy          = -not $hasIssue
                Message            = $message
            }
        }
        catch {
            Write-Warning "[DC-020] Failed to check power plan on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController   = $dcName
                PowerPlanName      = 'Unknown'
                PowerPlanGuid      = 'Unknown'
                IsHighPerformance  = $false
                HasIssue           = $true
                Status             = 'Error'
                Severity           = 'Error'
                IsHealthy          = $false
                Message            = "Failed to check power plan on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DC-020] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-020] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController   = 'Unknown'
        PowerPlanName      = 'Unknown'
        PowerPlanGuid      = 'Unknown'
        IsHighPerformance  = $false
        HasIssue           = $true
        Status             = 'Error'
        Severity           = 'Error'
        IsHealthy          = $false
        Message            = "Check execution failed: $($_.Exception.Message)"
    })
}
