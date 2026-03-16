<#
.SYNOPSIS
    Event Log Critical Errors Check (DC-011)
.DESCRIPTION
    Checks System event logs for Critical and Error level events in the last 24 hours
    on each domain controller. High error counts may indicate underlying health issues.
    Known noisy but harmless event IDs (1014 DNS client, 10016 DCOM) are excluded.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DC-011
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

# Thresholds
$warningThreshold  = 20
$criticalThreshold = 50

# Known noisy/harmless event IDs to exclude
$excludedEventIds = @(1014, 10016)

$cutoff = (Get-Date).AddHours(-24)

Write-Verbose "[DC-011] Starting event log critical error check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DC-011] No reachable DCs found"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-011] Checking event logs on: $($dc.Name)"

        try {
            $errorEvents    = @()
            $criticalEvents = @()

            # Try Get-WinEvent first (preferred, works on 2016+)
            try {
                $filterError = @{
                    LogName   = 'System'
                    Level     = @(1, 2)   # 1 = Critical, 2 = Error
                    StartTime = $cutoff
                }
                $allEvents = @(Get-WinEvent -ComputerName $dc.Name -FilterHashtable $filterError -ErrorAction Stop)

                # Exclude known noisy event IDs
                $allEvents      = @($allEvents | Where-Object { $excludedEventIds -notcontains $_.Id })
                $criticalEvents = @($allEvents | Where-Object { $_.Level -eq 1 })
                $errorEvents    = @($allEvents | Where-Object { $_.Level -eq 2 })
            }
            catch [System.Exception] {
                if ($_.Exception.Message -like '*No events were found*') {
                    $allEvents      = @()
                    $criticalEvents = @()
                    $errorEvents    = @()
                }
                else {
                    # Fallback to Get-EventLog for 2012 R2
                    try {
                        $rawEvents  = @(Get-EventLog -LogName System -ComputerName $dc.Name `
                            -After $cutoff -EntryType Error -ErrorAction Stop)
                        $allEvents  = @($rawEvents | Where-Object { $excludedEventIds -notcontains $_.EventID })
                        $errorEvents    = $allEvents
                        $criticalEvents = @()  # Get-EventLog doesn't expose Critical separately
                    }
                    catch {
                        Write-Warning "[DC-011] Could not query System event log on $($dc.Name): $_"
                        $allEvents      = @()
                        $criticalEvents = @()
                        $errorEvents    = @()
                    }
                }
            }

            $systemErrorCount = @($allEvents).Count
            $criticalCount    = @($criticalEvents).Count

            # Find top 3 event IDs by frequency
            $topEventIds = ''
            if ($systemErrorCount -gt 0) {
                $topEventIds = ($allEvents |
                    Group-Object -Property Id |
                    Sort-Object Count -Descending |
                    Select-Object -First 3 |
                    ForEach-Object { "$($_.Name)($($_.Count))" }) -join ', '
            }

            $oldestError = if ($systemErrorCount -gt 0) {
                ($allEvents | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
            } else { $null }

            $newestError = if ($systemErrorCount -gt 0) {
                ($allEvents | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
            } else { $null }

            $hasIssue = $systemErrorCount -gt $warningThreshold -or $criticalCount -gt 0
            $severity = if ($criticalCount -gt 0)                  { 'Critical' }
                        elseif ($systemErrorCount -gt $criticalThreshold) { 'High' }
                        elseif ($systemErrorCount -gt $warningThreshold)  { 'Medium' }
                        else { 'Info' }
            $status   = if ($criticalCount -gt 0 -or $systemErrorCount -gt $criticalThreshold) { 'Fail' }
                        elseif ($systemErrorCount -gt $warningThreshold) { 'Warning' }
                        else { 'Healthy' }

            $results += [PSCustomObject]@{
                DomainController  = $dc.Name
                SystemErrorCount  = $systemErrorCount
                CriticalCount     = $criticalCount
                OldestError       = $oldestError
                NewestError       = $newestError
                TopEventIds       = $topEventIds
                WarningThreshold  = $warningThreshold
                CriticalThreshold = $criticalThreshold
                IsHealthy         = -not $hasIssue
                HasIssue          = $hasIssue
                Status            = $status
                Severity          = $severity
                Message           = if ($criticalCount -gt 0) {
                    "CRITICAL: $criticalCount Critical + $systemErrorCount total error events on $($dc.Name) in last 24h"
                } elseif ($systemErrorCount -gt $criticalThreshold) {
                    "FAIL: $systemErrorCount error events on $($dc.Name) in last 24h (threshold: $criticalThreshold)"
                } elseif ($systemErrorCount -gt $warningThreshold) {
                    "WARNING: $systemErrorCount error events on $($dc.Name) in last 24h (threshold: $warningThreshold)"
                } else {
                    "$($dc.Name) has $systemErrorCount error events in last 24h - within normal limits"
                }
            }
        }
        catch {
            Write-Warning "[DC-011] Failed to check event logs on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController  = $dc.Name
                SystemErrorCount  = 0
                CriticalCount     = 0
                OldestError       = $null
                NewestError       = $null
                TopEventIds       = ''
                WarningThreshold  = $warningThreshold
                CriticalThreshold = $criticalThreshold
                IsHealthy         = $false
                HasIssue          = $true
                Status            = 'Error'
                Severity          = 'Error'
                Message           = "Failed to query event logs on $($dc.Name): $_"
            }
        }
    }

    Write-Verbose "[DC-011] Check complete. DCs checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DC-011] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController  = 'Unknown'
        SystemErrorCount  = 0
        CriticalCount     = 0
        OldestError       = $null
        NewestError       = $null
        TopEventIds       = ''
        WarningThreshold  = $warningThreshold
        CriticalThreshold = $criticalThreshold
        IsHealthy         = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        Message           = "Check execution failed: $($_.Exception.Message)"
    })
}
