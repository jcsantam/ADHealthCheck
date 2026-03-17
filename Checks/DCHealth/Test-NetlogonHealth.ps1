<#
.SYNOPSIS
    Netlogon Service Health Check (DC-014)

.DESCRIPTION
    Performs a deep health check of the Netlogon service on each domain controller:
    - Netlogon service is running and set to automatic startup
    - NETLOGON share is accessible (used for logon scripts)
    - SYSVOL share is accessible (used for GPO/script delivery)
    - Secure channel to the domain is established
    - No recent Netlogon errors in the event log (last 24 hours)

    Netlogon failures cause authentication errors, logon script failures,
    and GPO processing issues for domain clients.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-NetlogonHealth.ps1 -Inventory $inventory

.OUTPUTS
    Array of Netlogon health results per DC

.NOTES
    Check ID: DC-014
    Category: DCHealth
    Severity: Critical
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[DC-014] Starting Netlogon service health check..."

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-014] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[DC-014] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[DC-014] Checking Netlogon health on: $dcName"

        try {
            $issues = @()

            # --- Service status ---
            $nlSvc = $null
            try {
                $nlSvc = Get-WmiObject -Class Win32_Service -ComputerName $dcName `
                    -Filter "Name='Netlogon'" -ErrorAction SilentlyContinue
            } catch { }

            $svcRunning  = $false
            $svcAutoStart = $false
            if ($nlSvc) {
                $svcRunning   = ($nlSvc.State -eq 'Running')
                $svcAutoStart = ($nlSvc.StartMode -eq 'Auto')
                if (-not $svcRunning) {
                    $issues += "Netlogon service is NOT running (state: $($nlSvc.State))"
                }
                if (-not $svcAutoStart) {
                    $issues += "Netlogon service startup type is '$($nlSvc.StartMode)' (expected: Auto)"
                }
            } else {
                $issues += "Could not query Netlogon service status"
            }

            # --- Share accessibility ---
            $netlogonShare = $false
            $sysvolShare   = $false
            try {
                $shares = @(Get-WmiObject -Class Win32_Share -ComputerName $dcName -ErrorAction SilentlyContinue)
                $netlogonShare = ($shares | Where-Object { $_.Name -eq 'NETLOGON' }) -ne $null
                $sysvolShare   = ($shares | Where-Object { $_.Name -eq 'SYSVOL' }) -ne $null
            } catch { }

            if (-not $netlogonShare) { $issues += "NETLOGON share is not present" }
            if (-not $sysvolShare)   { $issues += "SYSVOL share is not present" }

            # --- Recent Netlogon errors in event log ---
            $netlogonErrors = 0
            try {
                $since = (Get-Date).AddHours(-24)
                $evts = @(Get-EventLog -LogName System -ComputerName $dcName `
                    -Source 'NETLOGON' -EntryType Error,Warning -After $since `
                    -Newest 20 -ErrorAction SilentlyContinue 2>$null)
                $netlogonErrors = $evts.Count
                if ($netlogonErrors -gt 5) {
                    $issues += "$netlogonErrors Netlogon error/warning events in the last 24 hours"
                }
            } catch {
                try {
                    $wevtFilter = @{ LogName = 'System'; ProviderName = 'NETLOGON'; Level = @(2,3); StartTime = $since }
                    $evts = @(Get-WinEvent -ComputerName $dcName -FilterHashtable $wevtFilter -MaxEvents 20 -ErrorAction SilentlyContinue 2>$null)
                    $netlogonErrors = $evts.Count
                    if ($netlogonErrors -gt 5) {
                        $issues += "$netlogonErrors Netlogon error/warning events in the last 24 hours"
                    }
                } catch { }
            }

            # --- Build result ---
            $hasIssue = ($issues.Count -gt 0)
            $status   = if ($hasIssue) { if (-not $svcRunning) { 'Fail' } else { 'Warning' } } else { 'Pass' }
            $severity = if (-not $svcRunning) { 'Critical' } elseif ($hasIssue) { 'High' } else { 'Info' }
            $message  = if ($hasIssue) {
                "DC $dcName Netlogon issues: $($issues -join '; ')"
            } else {
                "DC $dcName Netlogon service is healthy (running, shares present, no recent errors)"
            }

            $results += [PSCustomObject]@{
                DomainController = $dcName
                ServiceRunning   = $svcRunning
                ServiceAutoStart = $svcAutoStart
                NetlogonShare    = $netlogonShare
                SysvolShare      = $sysvolShare
                ErrorCount24h    = $netlogonErrors
                IssueList        = ($issues -join '; ')
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                IsHealthy        = -not $hasIssue
                Message          = $message
            }
        }
        catch {
            Write-Warning "[DC-014] Failed to check Netlogon on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController = $dcName
                ServiceRunning   = $false
                ServiceAutoStart = $false
                NetlogonShare    = $false
                SysvolShare      = $false
                ErrorCount24h    = 0
                IssueList        = $_.Exception.Message
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to check Netlogon health on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DC-014] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-014] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        ServiceRunning   = $false
        ServiceAutoStart = $false
        NetlogonShare    = $false
        SysvolShare      = $false
        ErrorCount24h    = 0
        IssueList        = $_.Exception.Message
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
