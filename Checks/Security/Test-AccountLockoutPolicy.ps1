<#
.SYNOPSIS
    Account Lockout Policy Check (SEC-007)

.DESCRIPTION
    Validates account lockout policy settings to protect against brute force attacks.
    Checks threshold, duration, and observation window.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: SEC-007
    Category: Security
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

# Recommended thresholds
$recommendedThreshold = 5  # Lock after 5 failed attempts
$recommendedDuration = 30  # Lock for 30 minutes
$recommendedWindow = 30    # Reset counter after 30 minutes

Write-Verbose "[SEC-007] Starting account lockout policy check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[SEC-007] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[SEC-007] Checking lockout policy for domain: $($domain.Name)"
        
        try {
            # Get default domain password policy (includes lockout settings)
            $policy = Get-ADDefaultDomainPasswordPolicy -Server $domain.Name -ErrorAction Stop
            
            # Analyze lockout settings
            $issues = @()
            $warnings = @()
            
            # Check if lockout is enabled
            if ($policy.LockoutThreshold -eq 0) {
                $issues += "Account lockout is disabled (brute force risk)"
            }
            else {
                # Check lockout threshold
                if ($policy.LockoutThreshold -gt 10) {
                    $warnings += "Lockout threshold is $($policy.LockoutThreshold) (recommended: ≤$recommendedThreshold)"
                }
                
                # Check lockout duration
                if ($policy.LockoutDuration.TotalMinutes -eq 0) {
                    $warnings += "Lockout duration is 0 (accounts locked until admin unlocks)"
                }
                elseif ($policy.LockoutDuration.TotalMinutes -lt 15) {
                    $warnings += "Lockout duration is only $($policy.LockoutDuration.TotalMinutes) minutes (recommended: ≥$recommendedDuration)"
                }
                
                # Check observation window
                if ($policy.LockoutObservationWindow.TotalMinutes -lt 15) {
                    $warnings += "Observation window is only $($policy.LockoutObservationWindow.TotalMinutes) minutes"
                }
            }
            
            # Determine status
            $hasIssue = ($issues.Count -gt 0 -or $warnings.Count -gt 0)
            $severity = if ($issues.Count -gt 0) { 'High' }
                       elseif ($warnings.Count -gt 2) { 'Medium' }
                       elseif ($warnings.Count -gt 0) { 'Low' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                Domain = $domain.Name
                LockoutEnabled = ($policy.LockoutThreshold -gt 0)
                LockoutThreshold = $policy.LockoutThreshold
                LockoutDurationMinutes = [int]$policy.LockoutDuration.TotalMinutes
                ObservationWindowMinutes = [int]$policy.LockoutObservationWindow.TotalMinutes
                IssuesFound = $issues.Count
                WarningsFound = $warnings.Count
                IssuesList = if ($issues.Count -gt 0) { ($issues -join "; ") } else { "None" }
                WarningsList = if ($warnings.Count -gt 0) { ($warnings -join "; ") } else { "None" }
                Severity = $severity
                Status = if ($issues.Count -gt 0) { 'Failed' }
                        elseif ($warnings.Count -gt 0) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($policy.LockoutThreshold -eq 0) {
                    "CRITICAL: Account lockout disabled - brute force attacks possible!"
                }
                elseif ($issues.Count -gt 0) {
                    "Policy issues: $($issues -join '; ')"
                }
                elseif ($warnings.Count -gt 0) {
                    "Lockout enabled but could be strengthened ($($warnings.Count) recommendations)"
                }
                else {
                    "Lockout policy configured appropriately (threshold: $($policy.LockoutThreshold))"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[SEC-007] Failed to check policy for $($domain.Name): $_"
            
            $results += [PSCustomObject]@{
                Domain = $domain.Name
                LockoutEnabled = $null
                LockoutThreshold = 0
                LockoutDurationMinutes = 0
                ObservationWindowMinutes = 0
                IssuesFound = 0
                WarningsFound = 0
                IssuesList = "Unknown"
                WarningsList = "Unknown"
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query lockout policy: $_"
            }
        }
    }
    
    Write-Verbose "[SEC-007] Check complete. Domains checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[SEC-007] Check failed: $_"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        LockoutEnabled = $null
        LockoutThreshold = 0
        LockoutDurationMinutes = 0
        ObservationWindowMinutes = 0
        IssuesFound = 0
        WarningsFound = 0
        IssuesList = "Unknown"
        WarningsList = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
