<#
.SYNOPSIS
    FSMO Role Placement Check (FSMO-001)

.DESCRIPTION
    Validates FSMO (Flexible Single Master Operations) role placement and availability.
    Ensures all 5 FSMO roles are assigned to reachable domain controllers.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: FSMO-001
    Category: Operational
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

Write-Verbose "[FSMO-001] Starting FSMO role placement check..."

try {
    # Check forest-level FSMO roles
    $forestInfo = $Inventory.ForestInfo
    
    if ($forestInfo) {
        Write-Verbose "[FSMO-001] Checking forest FSMO roles..."
        
        # Schema Master
        $schemaMaster = $forestInfo.SchemaMaster
        $schemaMasterDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $schemaMaster }
        
        $result = [PSCustomObject]@{
            Role = "Schema Master"
            Scope = "Forest"
            Holder = $schemaMaster
            IsReachable = if ($schemaMasterDC) { $schemaMasterDC.IsReachable } else { $false }
            Severity = if ($schemaMasterDC -and $schemaMasterDC.IsReachable) { 'Info' } else { 'Critical' }
            Status = if ($schemaMasterDC -and $schemaMasterDC.IsReachable) { 'Healthy' } else { 'Failed' }
            IsHealthy = ($schemaMasterDC -and $schemaMasterDC.IsReachable)
            HasIssue = -not ($schemaMasterDC -and $schemaMasterDC.IsReachable)
            Message = if ($schemaMasterDC -and $schemaMasterDC.IsReachable) {
                "Schema Master available on $schemaMaster"
            } else {
                "CRITICAL: Schema Master on $schemaMaster is not reachable!"
            }
        }
        $results += $result
        
        # Domain Naming Master
        $domainNamingMaster = $forestInfo.DomainNamingMaster
        $domainNamingDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $domainNamingMaster }
        
        $result = [PSCustomObject]@{
            Role = "Domain Naming Master"
            Scope = "Forest"
            Holder = $domainNamingMaster
            IsReachable = if ($domainNamingDC) { $domainNamingDC.IsReachable } else { $false }
            Severity = if ($domainNamingDC -and $domainNamingDC.IsReachable) { 'Info' } else { 'Critical' }
            Status = if ($domainNamingDC -and $domainNamingDC.IsReachable) { 'Healthy' } else { 'Failed' }
            IsHealthy = ($domainNamingDC -and $domainNamingDC.IsReachable)
            HasIssue = -not ($domainNamingDC -and $domainNamingDC.IsReachable)
            Message = if ($domainNamingDC -and $domainNamingDC.IsReachable) {
                "Domain Naming Master available on $domainNamingMaster"
            } else {
                "CRITICAL: Domain Naming Master on $domainNamingMaster is not reachable!"
            }
        }
        $results += $result
    }
    
    # Check domain-level FSMO roles
    $domains = $Inventory.Domains
    
    foreach ($domain in $domains) {
        Write-Verbose "[FSMO-001] Checking domain FSMO roles for: $($domain.Name)"
        
        # PDC Emulator
        $pdcEmulator = $domain.PDCEmulator
        $pdcDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $pdcEmulator }
        
        $result = [PSCustomObject]@{
            Role = "PDC Emulator"
            Scope = "Domain: $($domain.Name)"
            Holder = $pdcEmulator
            IsReachable = if ($pdcDC) { $pdcDC.IsReachable } else { $false }
            Severity = if ($pdcDC -and $pdcDC.IsReachable) { 'Info' } else { 'Critical' }
            Status = if ($pdcDC -and $pdcDC.IsReachable) { 'Healthy' } else { 'Failed' }
            IsHealthy = ($pdcDC -and $pdcDC.IsReachable)
            HasIssue = -not ($pdcDC -and $pdcDC.IsReachable)
            Message = if ($pdcDC -and $pdcDC.IsReachable) {
                "PDC Emulator available on $pdcEmulator"
            } else {
                "CRITICAL: PDC Emulator on $pdcEmulator is not reachable!"
            }
        }
        $results += $result
        
        # RID Master
        $ridMaster = $domain.RIDMaster
        $ridDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $ridMaster }
        
        $result = [PSCustomObject]@{
            Role = "RID Master"
            Scope = "Domain: $($domain.Name)"
            Holder = $ridMaster
            IsReachable = if ($ridDC) { $ridDC.IsReachable } else { $false }
            Severity = if ($ridDC -and $ridDC.IsReachable) { 'Info' } else { 'High' }
            Status = if ($ridDC -and $ridDC.IsReachable) { 'Healthy' } else { 'Failed' }
            IsHealthy = ($ridDC -and $ridDC.IsReachable)
            HasIssue = -not ($ridDC -and $ridDC.IsReachable)
            Message = if ($ridDC -and $ridDC.IsReachable) {
                "RID Master available on $ridMaster"
            } else {
                "WARNING: RID Master on $ridMaster is not reachable!"
            }
        }
        $results += $result
        
        # Infrastructure Master
        $infraMaster = $domain.InfrastructureMaster
        $infraDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $infraMaster }
        
        $result = [PSCustomObject]@{
            Role = "Infrastructure Master"
            Scope = "Domain: $($domain.Name)"
            Holder = $infraMaster
            IsReachable = if ($infraDC) { $infraDC.IsReachable } else { $false }
            Severity = if ($infraDC -and $infraDC.IsReachable) { 'Info' } else { 'High' }
            Status = if ($infraDC -and $infraDC.IsReachable) { 'Healthy' } else { 'Failed' }
            IsHealthy = ($infraDC -and $infraDC.IsReachable)
            HasIssue = -not ($infraDC -and $infraDC.IsReachable)
            Message = if ($infraDC -and $infraDC.IsReachable) {
                "Infrastructure Master available on $infraMaster"
            } else {
                "WARNING: Infrastructure Master on $infraMaster is not reachable!"
            }
        }
        $results += $result
    }
    
    Write-Verbose "[FSMO-001] Check complete. Roles checked: $($results.Count)"
    
    # Summary
    $criticalIssues = ($results | Where-Object { $_.Severity -eq 'Critical' -and $_.HasIssue }).Count
    if ($criticalIssues -gt 0) {
        Write-Warning "[FSMO-001] CRITICAL: $criticalIssues FSMO role holders are not reachable!"
    }
    
    return $results
}
catch {
    Write-Error "[FSMO-001] Check failed: $_"
    
    return @([PSCustomObject]@{
        Role = "Unknown"
        Scope = "Unknown"
        Holder = "Unknown"
        IsReachable = $false
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
