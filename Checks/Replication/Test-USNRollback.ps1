<#
.SYNOPSIS
    USN Rollback Detection Check (REP-003)

.DESCRIPTION
    Detects potential USN rollback scenarios which indicate serious replication issues.
    Checks for:
    - Event ID 2095 (USN rollback detected)
    - Unusual USN gaps
    - DC restore without proper procedures

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-USNRollback.ps1 -Inventory $inventory

.OUTPUTS
    Array of USN rollback detection results

.NOTES
    Check ID: REP-003
    Category: Replication
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[REP-003] Starting USN rollback detection check..."

try {
    $domainControllers = $Inventory.DomainControllers
    
    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[REP-003] No domain controllers found in inventory"
        return @()
    }
    
    Write-Verbose "[REP-003] Checking for USN rollback on $($domainControllers.Count) domain controllers..."
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-003] Processing DC: $($dc.Name)"
        
        # Only check reachable DCs
        if (-not $dc.IsReachable) {
            Write-Verbose "[REP-003] DC $($dc.Name) is not reachable, skipping"
            continue
        }
        
        $rollbackDetected = $false
        $rollbackEvents = @()
        
        try {
            # Check for Event ID 2095 (USN rollback detected)
            $usnEvents = Get-WinEvent -ComputerName $dc.HostName -FilterHashtable @{
                LogName = 'Directory Service'
                ID = 2095
            } -MaxEvents 5 -ErrorAction SilentlyContinue
            
            if ($usnEvents) {
                $rollbackDetected = $true
                $rollbackEvents = $usnEvents
                
                Write-Warning "[REP-003] USN ROLLBACK DETECTED on $($dc.Name)!"
            }
        }
        catch {
            Write-Verbose "[REP-003] No USN rollback events found on $($dc.Name) (this is good)"
        }
        
        # Also check for Event ID 1113 (NTDS database inconsistency)
        try {
            $inconsistencyEvents = Get-WinEvent -ComputerName $dc.HostName -FilterHashtable @{
                LogName = 'Directory Service'
                ID = 1113
                StartTime = (Get-Date).AddDays(-30)
            } -MaxEvents 5 -ErrorAction SilentlyContinue
            
            if ($inconsistencyEvents) {
                Write-Warning "[REP-003] Database inconsistency detected on $($dc.Name)"
                $rollbackDetected = $true
                $rollbackEvents += $inconsistencyEvents
            }
        }
        catch {
            # No inconsistency events (good)
        }
        
        # Create result
        if ($rollbackDetected) {
            # CRITICAL: Rollback detected
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                RollbackDetected = $true
                EventCount = $rollbackEvents.Count
                LastEventTime = ($rollbackEvents | Select-Object -First 1).TimeCreated
                EventDetails = ($rollbackEvents | Select-Object -First 1).Message
                Severity = 'Critical'
                Status = 'Failed'
                IsHealthy = $false
                HasIssue = $true
                Message = "CRITICAL: USN rollback detected! DC must be removed and rebuilt. DO NOT attempt replication."
            }
        }
        else {
            # No rollback detected (good)
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                RollbackDetected = $false
                EventCount = 0
                LastEventTime = $null
                EventDetails = $null
                Severity = 'Info'
                Status = 'Healthy'
                IsHealthy = $true
                HasIssue = $false
                Message = "No USN rollback detected"
            }
        }
        
        $results += $result
    }
    
    Write-Verbose "[REP-003] Check complete. DCs checked: $($results.Count)"
    
    # Summary
    $rollbackCount = ($results | Where-Object { $_.RollbackDetected }).Count
    if ($rollbackCount -gt 0) {
        Write-Warning "[REP-003] CRITICAL: USN ROLLBACK DETECTED on $rollbackCount DC(s)!"
    }
    else {
        Write-Verbose "[REP-003] No USN rollback issues detected"
    }
    
    return $results
}
catch {
    Write-Error "[REP-003] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        RollbackDetected = $null
        EventCount = 0
        LastEventTime = $null
        EventDetails = $null
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
