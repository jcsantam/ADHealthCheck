<#
.SYNOPSIS
    Stale User Accounts Check (SEC-005)

.DESCRIPTION
    Identifies user accounts that haven't been used in 90+ days.
    Security risk and license waste.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: SEC-005
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

# Thresholds
$staleThreshold = 90
$criticalThreshold = 180

Write-Verbose "[SEC-005] Starting stale user accounts check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[SEC-005] No domains found"
        return @()
    }
    
    $staleDate = (Get-Date).AddDays(-$staleThreshold)
    $criticalDate = (Get-Date).AddDays(-$criticalThreshold)
    
    foreach ($domain in $domains) {
        Write-Verbose "[SEC-005] Checking users in domain: $($domain.Name)"
        
        try {
            # Get all enabled user accounts
            $users = Get-ADUser -Filter {Enabled -eq $true} `
                -Properties LastLogonDate, PasswordLastSet, whenCreated `
                -Server $domain.Name -ErrorAction Stop
            
            $staleCount = 0
            $criticalCount = 0
            $totalUsers = $users.Count
            
            foreach ($user in $users) {
                $lastLogon = $user.LastLogonDate
                
                if (-not $lastLogon -or $lastLogon -lt $staleDate) {
                    $daysSinceLogon = if ($lastLogon) {
                        ((Get-Date) - $lastLogon).Days
                    } else {
                        999
                    }
                    
                    if ($daysSinceLogon -gt $criticalThreshold) {
                        $criticalCount++
                    }
                    $staleCount++
                }
            }
            
            # Determine status
            $stalePercent = if ($totalUsers -gt 0) {
                [math]::Round(($staleCount / $totalUsers) * 100, 1)
            } else { 0 }
            
            $hasIssue = $staleCount -gt 0
            $severity = if ($criticalCount -gt 50) { 'High' }
                       elseif ($staleCount -gt 50) { 'Medium' }
                       elseif ($staleCount -gt 0) { 'Low' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                Domain = $domain.Name
                TotalUsers = $totalUsers
                StaleUsers90Days = $staleCount
                StaleUsers180Days = $criticalCount
                StalePercent = $stalePercent
                Severity = $severity
                Status = if ($criticalCount -gt 50) { 'Warning' }
                        elseif ($staleCount -gt 0) { 'Info' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($criticalCount -gt 50) {
                    "WARNING: $criticalCount users inactive >180 days, $staleCount total stale ($stalePercent%)"
                }
                elseif ($staleCount -gt 0) {
                    "$staleCount users inactive >90 days ($stalePercent% of total)"
                }
                else {
                    "No stale user accounts detected"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[SEC-005] Failed to check users in $($domain.Name): $_"
            
            $results += [PSCustomObject]@{
                Domain = $domain.Name
                TotalUsers = 0
                StaleUsers90Days = 0
                StaleUsers180Days = 0
                StalePercent = 0
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query users: $_"
            }
        }
    }
    
    Write-Verbose "[SEC-005] Check complete. Domains checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[SEC-005] Check failed: $_"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        TotalUsers = 0
        StaleUsers90Days = 0
        StaleUsers180Days = 0
        StalePercent = 0
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
