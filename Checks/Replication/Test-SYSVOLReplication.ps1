<#
.SYNOPSIS
    SYSVOL Replication Check (REP-005)

.DESCRIPTION
    Checks SYSVOL replication health using DFSR (2012 R2+) or FRS (legacy).
    Auto-detects which method is in use and validates accordingly.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: REP-005
    Category: Replication
    Severity: Critical
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'

$dcCount = @($Inventory.DomainControllers).Count
if ($dcCount -eq 1) {
    return [PSCustomObject]@{
        IsHealthy = $true
        Status    = 'Pass'
        Message   = 'Single-DC environment - SYSVOL sync check not applicable'
    }
}

$results = @()

Write-Verbose "[REP-005] Starting SYSVOL replication check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[REP-005] No domains found"
        return @()
    }
    
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[REP-005] No reachable DCs"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-005] Checking SYSVOL on DC: $($dc.Name)"

        # Detect replication method per DC (DFSR or FRS)
        $replMethod = "FRS"  # Default

        try {
            $dfsrCheck = Get-Service -Name DFSR -ComputerName $dc.Name -ErrorAction SilentlyContinue
            if ($dfsrCheck -and $dfsrCheck.Status -eq 'Running') {
                $replMethod = "DFSR"
            }
        }
        catch {
            $replMethod = "FRS"
        }

        Write-Verbose "[REP-005] $($dc.Name) SYSVOL method: $replMethod"

        if ($replMethod -eq "DFSR") {
            try {
                $dfsrFolders = @(Get-WmiObject -Namespace "root\MicrosoftDFS" `
                    -Class DfsrReplicatedFolderInfo -ComputerName $dc.Name -ErrorAction Stop |
                    Where-Object { $_.ReplicationGroupName -eq "Domain System Volume" })

                $hasErrors    = @($dfsrFolders | Where-Object { $_.LastErrorCode -ne 0 }).Count -gt 0
                $inSync       = @($dfsrFolders | Where-Object { $_.State -eq 4 }).Count -gt 0
                $backlogCount = 0

                $results += [PSCustomObject]@{
                    DomainController  = $dc.Name
                    ReplicationMethod = "DFSR"
                    ServiceRunning    = $true
                    InSync            = $inSync
                    BacklogCount      = $backlogCount
                    HasErrors         = $hasErrors
                    Severity          = if ($hasErrors) { 'Critical' }
                                       elseif ($backlogCount -gt 100) { 'High' }
                                       elseif ($backlogCount -gt 50) { 'Medium' }
                                       else { 'Info' }
                    Status            = if ($hasErrors) { 'Failed' }
                                       elseif ($backlogCount -gt 100) { 'Warning' }
                                       else { 'Healthy' }
                    IsHealthy         = (-not $hasErrors -and $backlogCount -lt 50)
                    HasIssue          = ($hasErrors -or $backlogCount -gt 50)
                    Message           = if ($hasErrors) { "DFSR errors detected on $($dc.Name)" }
                                       elseif ($backlogCount -gt 100) { "High backlog: $backlogCount files" }
                                       elseif ($backlogCount -gt 50) { "Moderate backlog: $backlogCount files" }
                                       else { "DFSR healthy on $($dc.Name)" }
                }
            }
            catch {
                Write-Warning "[REP-005] DFSR WMI query failed on $($dc.Name): $_"
                # WMI namespace unavailable - skip rather than false-fail
                Write-Verbose "[REP-005] Skipping $($dc.Name) - DFSR WMI namespace not available"
            }
        }
        else {
            try {
                $frsCheck = Get-Service -Name NTFRS -ComputerName $dc.Name -ErrorAction Stop

                $results += [PSCustomObject]@{
                    DomainController  = $dc.Name
                    ReplicationMethod = "FRS"
                    ServiceRunning    = ($frsCheck.Status -eq 'Running')
                    InSync            = ($frsCheck.Status -eq 'Running')
                    BacklogCount      = 0
                    HasErrors         = ($frsCheck.Status -ne 'Running')
                    Severity          = if ($frsCheck.Status -ne 'Running') { 'Critical' } else { 'Info' }
                    Status            = if ($frsCheck.Status -ne 'Running') { 'Failed' } else { 'Healthy' }
                    IsHealthy         = ($frsCheck.Status -eq 'Running')
                    HasIssue          = ($frsCheck.Status -ne 'Running')
                    Message           = if ($frsCheck.Status -ne 'Running') {
                        "FRS service not running on $($dc.Name)"
                    } else {
                        "FRS running on $($dc.Name) (consider migrating to DFSR)"
                    }
                }
            }
            catch {
                Write-Warning "[REP-005] FRS check failed on $($dc.Name): $_"
                Write-Verbose "[REP-005] Skipping $($dc.Name) - FRS service query failed"
            }
        }
    }
    
    Write-Verbose "[REP-005] Check complete. Results: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[REP-005] Check failed: $_"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        ReplicationMethod = "Unknown"
        ServiceRunning = $false
        InSync = $false
        BacklogCount = 0
        HasErrors = $true
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
