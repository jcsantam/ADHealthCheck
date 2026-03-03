<#
.SYNOPSIS
    Check DC-001: Critical Services Status

.DESCRIPTION
    Verifies that all critical Active Directory services are running
    on all domain controllers.

    Beta 1.1 fix: Removed Start-Job (credential delegation fails for remote DCs).
    Instead uses direct Get-Service with all service names in a single call per DC.
    One network round-trip per DC instead of one per service.

.PARAMETER Inventory
    AD topology inventory object from Discovery.ps1

.OUTPUTS
    PSCustomObject with IsHealthy, HasIssue, Services, StoppedCount, Message

.NOTES
    Version: 1.1.1
    Check ID: DC-001
    Category: DCHealth
#>

param(
    [Parameter(Mandatory = $true)]
    $Inventory
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

# -----------------------------------------------------------------------
# CRITICAL SERVICES TO CHECK
# -----------------------------------------------------------------------

$criticalServices = @(
    'NTDS',
    'DNS',
    'Netlogon',
    'kdc',
    'W32Time',
    'DFSR',
    'LanmanServer',
    'LanmanWorkstation'
)

# -----------------------------------------------------------------------
# COLLECT DCs
# -----------------------------------------------------------------------

$dcs = @($Inventory.DomainControllers)

if ($dcs.Count -eq 0) {
    return [PSCustomObject]@{
        IsHealthy    = $false
        HasIssue     = $true
        Services     = @()
        Items        = @()
        StoppedCount = 0
        Message      = "No domain controllers found in inventory"
        CheckId      = 'DC-001'
    }
}

# -----------------------------------------------------------------------
# CHECK SERVICES - Direct call per DC, all services in one Get-Service call
# No Start-Job: avoids credential delegation failure on remote DCs
# -----------------------------------------------------------------------

$allServiceResults = @()

foreach ($dc in $dcs) {
    $dcName = $dc.Name
    if ([string]::IsNullOrWhiteSpace($dcName)) { continue }

    try {
        # Single Get-Service call with all service names - one network round-trip
        $services = @(Get-Service -ComputerName $dcName -Name $criticalServices -ErrorAction SilentlyContinue)

        # Track which services we actually got back
        $foundServices = @{}
        foreach ($svc in $services) {
            $foundServices[$svc.Name] = $svc
        }

        # Build result for each expected service
        foreach ($svcName in $criticalServices) {
            $status    = 'Unknown'
            $isRunning = $false

            if ($foundServices.ContainsKey($svcName)) {
                $status    = $foundServices[$svcName].Status.ToString()
                $isRunning = ($status -eq 'Running')
            }
            else {
                # Not returned by Get-Service - either not installed or access issue
                # Try individual call to distinguish
                try {
                    $single    = Get-Service -ComputerName $dcName -Name $svcName -ErrorAction Stop
                    $status    = $single.Status.ToString()
                    $isRunning = ($status -eq 'Running')
                }
                catch [Microsoft.PowerShell.Commands.ServiceCommandException] {
                    $status    = 'NotInstalled'
                    $isRunning = $true   # Not installed is not an error
                }
                catch {
                    $status    = 'Unknown'
                    $isRunning = $false
                }
            }

            $allServiceResults += [PSCustomObject]@{
                DCName        = $dcName
                ServiceName   = $svcName
                Status        = $status
                State         = $status
                ServiceStatus = $status
                IsRunning     = $isRunning
                ErrorMessage  = $null
            }
        }
    }
    catch {
        # Entire DC unreachable - mark all services as Unknown
        $errMsg = $_.Exception.Message
        foreach ($svcName in $criticalServices) {
            $allServiceResults += [PSCustomObject]@{
                DCName        = $dcName
                ServiceName   = $svcName
                Status        = 'Unknown'
                State         = 'Unknown'
                ServiceStatus = 'Unknown'
                IsRunning     = $false
                ErrorMessage  = $errMsg
            }
        }
    }
}

# -----------------------------------------------------------------------
# ANALYZE RESULTS
# Unknown = could not check, treat as potential issue
# NotInstalled = not an error
# -----------------------------------------------------------------------

$stoppedServices = @($allServiceResults | Where-Object {
    $_.Status -eq 'Stopped' -or $_.Status -eq 'Paused' -or $_.Status -eq 'StartPending'
})

$unknownServices = @($allServiceResults | Where-Object {
    $_.Status -eq 'Unknown'
})

$stoppedCount = $stoppedServices.Count
$unknownCount = $unknownServices.Count

# IsHealthy = no stopped services AND no unknown services
$isHealthy = ($stoppedCount -eq 0 -and $unknownCount -eq 0)
$hasIssue  = (-not $isHealthy)

# Build message
if ($stoppedCount -gt 0) {
    $stoppedList = ($stoppedServices | ForEach-Object { "$($_.ServiceName) on $($_.DCName)" }) -join ', '
    $message = "$stoppedCount critical service(s) stopped: $stoppedList"
}
elseif ($unknownCount -gt 0) {
    $unknownDCs = ($unknownServices | Select-Object -ExpandProperty DCName -Unique) -join ', '
    $message = "Could not check services on: $unknownDCs (access or connectivity issue)"
}
else {
    $message = "All $($criticalServices.Count) critical services running across $($dcs.Count) DC(s)"
}

# -----------------------------------------------------------------------
# RETURN OUTPUT
# -----------------------------------------------------------------------

return [PSCustomObject]@{
    IsHealthy    = $isHealthy
    HasIssue     = $hasIssue
    Services     = $allServiceResults
    Items        = $allServiceResults
    StoppedCount = $stoppedCount
    UnknownCount = $unknownCount
    DCCount      = $dcs.Count
    Message      = $message
    CheckId      = 'DC-001'
}