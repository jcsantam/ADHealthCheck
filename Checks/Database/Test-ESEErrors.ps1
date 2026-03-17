<#
.SYNOPSIS
    ESE Database Error Events Check (DB-008)

.DESCRIPTION
    Scans the Application and System event logs on each DC for ESENT (Extensible
    Storage Engine) error events that indicate NTDS database integrity problems,
    dirty shutdowns, or I/O failures.

    Critical ESENT event IDs monitored:
    - 454: Database file recovery failed (corruption risk)
    - 474: Logging failed - database may be inconsistent
    - 490: Shadow copy failure
    - 508: Database requires recovery (dirty shutdown)
    - 510: Database file checksum mismatch (corruption)
    - 512: Dirty shutdown detected
    - 533: Database was not cleanly shut down
    - 610: Database header indicates it needs repair

    Events are checked from the last 30 days. Any critical ESENT errors on a
    DC running NTDS should be investigated immediately.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ESEErrors.ps1 -Inventory $inventory

.OUTPUTS
    Array of ESE error event results per DC

.NOTES
    Check ID: DB-008
    Category: Database
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

Write-Verbose "[DB-008] Starting ESE database error check..."

# Critical ESENT event IDs that indicate database problems
$criticalEventIds = @(454, 474, 490, 508, 510, 512, 533, 610)
$warningEventIds  = @(467, 469, 489, 491, 700, 701, 702)  # degraded but not immediately critical

$lookbackDays = 30
$since = (Get-Date).AddDays(-$lookbackDays)

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DB-008] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[DB-008] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[DB-008] Checking ESENT events on: $dcName"

        try {
            $criticalEvents = @()
            $warningEvents  = @()

            # Try Get-EventLog (PS 5.1 / 2012 R2 compatible)
            try {
                $allEsentEvents = @(Get-EventLog -LogName Application `
                    -ComputerName $dcName `
                    -Source 'ESENT' `
                    -After $since `
                    -ErrorAction SilentlyContinue 2>$null)

                if ($allEsentEvents) {
                    $criticalEvents = @($allEsentEvents | Where-Object { $criticalEventIds -contains $_.EventID })
                    $warningEvents  = @($allEsentEvents | Where-Object { $warningEventIds  -contains $_.EventID })
                    Write-Verbose "[DB-008] $dcName`: $($allEsentEvents.Count) ESENT events, $($criticalEvents.Count) critical"
                }
            }
            catch {
                Write-Verbose "[DB-008] Get-EventLog failed on $dcName, trying Get-WinEvent"

                # Fallback to Get-WinEvent
                try {
                    $allIds = $criticalEventIds + $warningEventIds
                    $wevtFilter = @{
                        LogName      = 'Application'
                        ProviderName = 'ESENT'
                        Id           = $allIds
                        StartTime    = $since
                    }
                    $allEsentEvents = @(Get-WinEvent -ComputerName $dcName -FilterHashtable $wevtFilter `
                        -MaxEvents 100 -ErrorAction SilentlyContinue 2>$null)

                    if ($allEsentEvents) {
                        $criticalEvents = @($allEsentEvents | Where-Object { $criticalEventIds -contains $_.Id })
                        $warningEvents  = @($allEsentEvents | Where-Object { $warningEventIds  -contains $_.Id })
                    }
                }
                catch {
                    Write-Verbose "[DB-008] Get-WinEvent also failed on $dcName"
                }
            }

            # Also check NTDS-specific events in Directory Service log
            $ntdsCriticalEvents = @()
            try {
                # Directory Service log events indicating DB problems
                $dsFilter = @{
                    LogName   = 'Directory Service'
                    Id        = @(1173, 1168, 1069, 1084, 1000, 2042)  # replication/DB error IDs
                    StartTime = $since
                }
                $dsEvents = @(Get-WinEvent -ComputerName $dcName -FilterHashtable $dsFilter `
                    -MaxEvents 20 -ErrorAction SilentlyContinue 2>$null)
                if ($dsEvents) { $ntdsCriticalEvents = $dsEvents }
            }
            catch {
                try {
                    $ntdsCriticalEvents = @(Get-EventLog -LogName 'Directory Service' `
                        -ComputerName $dcName `
                        -EntryType Error `
                        -After $since `
                        -Newest 20 `
                        -ErrorAction SilentlyContinue 2>$null)
                }
                catch { }
            }

            $hasIssue = $false
            $status   = 'Pass'
            $severity = 'Info'
            $message  = ''

            if ($criticalEvents.Count -gt 0) {
                $hasIssue = $true
                $status   = 'Fail'
                $severity = 'Critical'
                # Get unique event IDs found
                $foundIds = ($criticalEvents | ForEach-Object {
                    if ($_.EventID) { $_.EventID } else { $_.Id }
                } | Sort-Object -Unique) -join ', '
                $message = "DC $dcName has $($criticalEvents.Count) critical ESENT database error event(s) in the last $lookbackDays days (Event IDs: $foundIds) - database integrity may be compromised"
            }
            elseif ($warningEvents.Count -gt 0) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'High'
                $foundIds = ($warningEvents | ForEach-Object {
                    if ($_.EventID) { $_.EventID } else { $_.Id }
                } | Sort-Object -Unique) -join ', '
                $message = "DC $dcName has $($warningEvents.Count) ESENT warning event(s) in the last $lookbackDays days (Event IDs: $foundIds) - monitor for escalation"
            }
            elseif ($ntdsCriticalEvents.Count -gt 0) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'High'
                $message  = "DC $dcName has $($ntdsCriticalEvents.Count) Directory Service error event(s) in the last $lookbackDays days - review Directory Service event log"
            }
            else {
                $message = "DC $dcName - no ESENT database error events detected in the last $lookbackDays days"
            }

            $results += [PSCustomObject]@{
                DomainController   = $dcName
                CriticalEventCount = $criticalEvents.Count
                WarningEventCount  = $warningEvents.Count
                NTDSErrorCount     = $ntdsCriticalEvents.Count
                HasIssue           = $hasIssue
                Status             = $status
                Severity           = $severity
                IsHealthy          = -not $hasIssue
                Message            = $message
            }
        }
        catch {
            Write-Warning "[DB-008] Failed to check ESE events on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController   = $dcName
                CriticalEventCount = 0
                WarningEventCount  = 0
                NTDSErrorCount     = 0
                HasIssue           = $true
                Status             = 'Error'
                Severity           = 'Error'
                IsHealthy          = $false
                Message            = "Failed to check ESE events on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DB-008] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DB-008] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController   = 'Unknown'
        CriticalEventCount = 0
        WarningEventCount  = 0
        NTDSErrorCount     = 0
        HasIssue           = $true
        Status             = 'Error'
        Severity           = 'Error'
        IsHealthy          = $false
        Message            = "Check execution failed: $($_.Exception.Message)"
    })
}
