<#
.SYNOPSIS
    W32Time Service Startup Check (TIME-005)

.DESCRIPTION
    Verifies that the Windows Time (W32Time) service is running and set to
    automatic startup on all reachable domain controllers. A stopped or
    manually-started W32Time service will cause time drift and eventually
    break Kerberos authentication.

    Checks:
    - W32Time service State == Running
    - W32Time service StartMode == Auto

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-W32TimeService.ps1 -Inventory $inventory

.OUTPUTS
    Array of W32Time service status results per DC

.NOTES
    Check ID: TIME-005
    Category: Time
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[TIME-005] Starting W32Time service check..."

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[TIME-005] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[TIME-005] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[TIME-005] Checking W32Time service on: $dcName"

        try {
            $svc = Get-WmiObject -Class Win32_Service -Filter "Name='W32Time'" -ComputerName $dc.Name -ErrorAction SilentlyContinue

            if (-not $svc) {
                $results += [PSCustomObject]@{
                    DomainController = $dcName
                    ServiceState     = 'NotFound'
                    StartMode        = 'Unknown'
                    IsRunning        = $false
                    IsAutoStart      = $false
                    HasIssue         = $true
                    Status           = 'Fail'
                    Severity         = 'Critical'
                    IsHealthy        = $false
                    Message          = "W32Time service not found on $dcName"
                }
                continue
            }

            $isRunning = ($svc.State -eq 'Running')
            $isAutoStart = ($svc.StartMode -eq 'Auto')

            $hasIssue = $false
            $status = 'Pass'
            $severity = 'Info'
            $message = ''

            if (-not $isRunning) {
                $hasIssue = $true
                $status = 'Fail'
                $severity = 'Critical'
                $message = "W32Time service is not running on $dcName (State: $($svc.State))"
            }
            elseif (-not $isAutoStart) {
                $hasIssue = $true
                $status = 'Warning'
                $severity = 'High'
                $message = "W32Time service StartMode is '$($svc.StartMode)' on $dcName (expected Auto)"
            }
            else {
                $message = "W32Time service is running and set to Auto on $dcName"
            }

            $results += [PSCustomObject]@{
                DomainController = $dcName
                ServiceState     = $svc.State
                StartMode        = $svc.StartMode
                IsRunning        = $isRunning
                IsAutoStart      = $isAutoStart
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                IsHealthy        = -not $hasIssue
                Message          = $message
            }
        }
        catch {
            Write-Warning "[TIME-005] Failed to query W32Time service on DC ${dcName}: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController = $dcName
                ServiceState     = 'Unknown'
                StartMode        = 'Unknown'
                IsRunning        = $false
                IsAutoStart      = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to query W32Time service: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[TIME-005] Check complete. DCs checked: $($results.Count)"
    return $results
}
catch {
    Write-Error "[TIME-005] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        ServiceState     = 'Unknown'
        StartMode        = 'Unknown'
        IsRunning        = $false
        IsAutoStart      = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
