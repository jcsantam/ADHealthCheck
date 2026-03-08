<#
.SYNOPSIS
    GPO Permissions Validation Check (GPO-004)

.DESCRIPTION
    Validates Group Policy Object permissions for security and proper delegation.
    Detects overly permissive access and missing standard permissions.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: GPO-004
    Category: GPO
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

Write-Verbose "[GPO-004] Starting GPO permissions validation check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[GPO-004] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[GPO-004] Checking GPO permissions for domain: $($domain.Name)"
        
        try {
            # Get all GPOs
            $gpos = Get-GPO -All -Domain $domain.Name -ErrorAction Stop
            
            $totalGPOs = $gpos.Count
            $gposWithIssues = 0
            $permissionIssues = @()
            
            foreach ($gpo in $gpos) {
                try {
                    # Get GPO permissions
                    $permissions = Get-GPPermission -Guid $gpo.Id -All -Server $domain.Name -ErrorAction SilentlyContinue
                    
                    if (-not $permissions) {
                        $gposWithIssues++
                        $permissionIssues += "$($gpo.DisplayName): No permissions found"
                        continue
                    }
                    
                    # Check for critical permissions
                    $hasAuthUsers = $false
                    $hasDomainComputers = $false
                    $hasEnterpriseAdmins = $false
                    $hasDomainAdmins = $false
                    $everyoneHasAccess = $false
                    
                    foreach ($perm in $permissions) {
                        $trustee = $perm.Trustee.Name
                        
                        if ($trustee -match "Authenticated Users") {
                            $hasAuthUsers = $true
                        }
                        if ($trustee -match "Domain Computers") {
                            $hasDomainComputers = $true
                        }
                        if ($trustee -match "Enterprise Admins") {
                            $hasEnterpriseAdmins = $true
                        }
                        if ($trustee -match "Domain Admins") {
                            $hasDomainAdmins = $true
                        }
                        if ($trustee -match "Everyone" -and $perm.Permission -ne "GpoRead") {
                            $everyoneHasAccess = $true
                        }
                    }
                    
                    # Check for issues
                    $gpoHasIssue = $false
                    
                    if ($everyoneHasAccess) {
                        $gposWithIssues++
                        $permissionIssues += "$($gpo.DisplayName): Everyone has excessive permissions"
                        $gpoHasIssue = $true
                    }
                    
                    if (-not $hasDomainAdmins -and -not $hasEnterpriseAdmins) {
                        $gposWithIssues++
                        $permissionIssues += "$($gpo.DisplayName): Missing admin permissions"
                        $gpoHasIssue = $true
                    }
                }
                catch {
                    Write-Verbose "[GPO-004] Could not check permissions for $($gpo.DisplayName): $_"
                }
            }
            
            # Determine status
            $hasIssue = ($gposWithIssues -gt 0)
            $severity = if ($gposWithIssues -gt 10) { 'High' }
                       elseif ($gposWithIssues -gt 5) { 'Medium' }
                       elseif ($gposWithIssues -gt 0) { 'Low' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                Domain = $domain.Name
                TotalGPOs = $totalGPOs
                GPOsWithIssues = $gposWithIssues
                HealthyGPOs = ($totalGPOs - $gposWithIssues)
                IssuesList = if ($permissionIssues.Count -gt 0) {
                    ($permissionIssues | Select-Object -First 5) -join "; "
                } else {
                    "None"
                }
                Severity = $severity
                Status = if ($gposWithIssues -gt 10) { 'Failed' }
                        elseif ($gposWithIssues -gt 0) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($gposWithIssues -gt 10) {
                    "WARNING: $gposWithIssues of $totalGPOs GPOs have permission issues"
                }
                elseif ($gposWithIssues -gt 0) {
                    "$gposWithIssues of $totalGPOs GPOs have permission issues"
                }
                else {
                    "All $totalGPOs GPO permissions validated"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[GPO-004] Failed to check GPO permissions for $($domain.Name): $_"
            
            $results += [PSCustomObject]@{
                Domain = $domain.Name
                TotalGPOs = 0
                GPOsWithIssues = 0
                HealthyGPOs = 0
                IssuesList = "Unknown"
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query GPO permissions: $_"
            }
        }
    }
    
    Write-Verbose "[GPO-004] Check complete. Domains checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[GPO-004] Check failed: $_"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        TotalGPOs = 0
        GPOsWithIssues = 0
        HealthyGPOs = 0
        IssuesList = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
