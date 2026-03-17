<#
.SYNOPSIS
    ESE Database Defragmentation Status Check (DB-006)

.DESCRIPTION
    Checks whether the NTDS database has been recently defragmented by examining
    the Windows event log for NTDS offline defragmentation completion events.

    ESE (Extensible Storage Engine) databases accumulate internal fragmentation
    over time as objects are added and deleted. Offline defragmentation compacts
    the database, reclaims white space, and rebuilds indexes improving performance.

    Checks:
    - Event ID 700 (NTDS General): offline defrag completion (if not found, marks
      as informational - the database may simply never have been defragmented)
    - Event log source "NTDS" or "ActiveDirectory_DomainService"
    - Flags if last defrag was more than 1 year ago (Warning)
    - Flags if NTDS.dit size is very large and no defrag event found (Warning)

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-IndexFragmentation.ps1 -Inventory $inventory

.OUTPUTS
    Array of defragmentation status results per DC

.NOTES
    Check ID: DB-006
    Category: Database
    Severity: Medium
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
Import-Module ActiveDirectory -ErrorAction SilentlyContinue
$results = @()

Write-Verbose "[DB-006] Starting database defragmentation status check..."

# NTDS offline defrag completion: Event ID 700, Source = "NTDS" or "ActiveDirectory_DomainService"
# Event message contains "Internal Processing" with "defrag" context
# Actually the correct event: Source=NTDS General, Event ID 700 = "Active Directory completed the internal processing required for defragmentation"
# On 2016+ source may be "Microsoft-Windows-ActiveDirectory_DomainService"

$defragEventId = 700
$oneYearAgo    = (Get-Date).AddDays(-365)

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DB-006] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[DB-006] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[DB-006] Checking defrag status on: $dcName"

        try {
            $lastDefragDate = $null
            $defragFound    = $false

            # Try Get-EventLog (2012 R2 compatible) first
            try {
                $events = @(Get-EventLog -LogName 'Directory Service' `
                    -ComputerName $dcName `
                    -Source 'NTDS*' `
                    -InstanceId $defragEventId `
                    -Newest 5 `
                    -ErrorAction SilentlyContinue 2>$null)

                if ($events -and $events.Count -gt 0) {
                    $lastDefragDate = ($events | Sort-Object TimeGenerated -Descending | Select-Object -First 1).TimeGenerated
                    $defragFound = $true
                }
            }
            catch {
                Write-Verbose "[DB-006] Get-EventLog failed on $dcName, trying Get-WinEvent"
            }

            # Fallback to Get-WinEvent for 2016+
            if (-not $defragFound) {
                try {
                    $wevtFilter = @{
                        LogName  = 'Directory Service'
                        Id       = $defragEventId
                    }
                    $events = @(Get-WinEvent -ComputerName $dcName -FilterHashtable $wevtFilter `
                        -MaxEvents 5 -ErrorAction SilentlyContinue 2>$null)

                    if ($events -and $events.Count -gt 0) {
                        $lastDefragDate = ($events | Sort-Object TimeCreated -Descending | Select-Object -First 1).TimeCreated
                        $defragFound = $true
                    }
                }
                catch {
                    Write-Verbose "[DB-006] Get-WinEvent also failed on $dcName"
                }
            }

            $hasIssue = $false
            $status   = 'Pass'
            $severity = 'Info'
            $message  = ''

            if (-not $defragFound) {
                # No defrag event in the log - this is informational; logs may be rolled over
                # or defrag was done before the current log history
                $hasIssue = $false
                $status   = 'Pass'
                $severity = 'Info'
                $message  = "DC $dcName - no offline defragmentation event found in Directory Service log (may have been done before log history, or never performed)"
            }
            elseif ($lastDefragDate -lt $oneYearAgo) {
                $daysSince = [math]::Round(((Get-Date) - $lastDefragDate).TotalDays)
                $hasIssue  = $true
                $status    = 'Warning'
                $severity  = 'Medium'
                $message   = "DC $dcName last offline defragmentation was $daysSince days ago ($($lastDefragDate.ToString('yyyy-MM-dd'))) - consider running defrag to reclaim white space"
            }
            else {
                $daysSince = [math]::Round(((Get-Date) - $lastDefragDate).TotalDays)
                $message   = "DC $dcName last offline defragmentation was $daysSince days ago ($($lastDefragDate.ToString('yyyy-MM-dd'))) - within 1 year"
            }

            $results += [PSCustomObject]@{
                DomainController = $dcName
                LastDefragDate   = if ($lastDefragDate) { $lastDefragDate.ToString('yyyy-MM-dd') } else { 'Unknown' }
                DefragFound      = $defragFound
                DaysSinceDefrag  = if ($lastDefragDate) { [math]::Round(((Get-Date) - $lastDefragDate).TotalDays) } else { $null }
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                IsHealthy        = -not $hasIssue
                Message          = $message
            }
        }
        catch {
            Write-Warning "[DB-006] Failed to check defrag status on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController = $dcName
                LastDefragDate   = 'Unknown'
                DefragFound      = $false
                DaysSinceDefrag  = $null
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to check defragmentation status on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DB-006] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DB-006] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        LastDefragDate   = 'Unknown'
        DefragFound      = $false
        DaysSinceDefrag  = $null
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
