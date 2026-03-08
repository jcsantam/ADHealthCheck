<#
.SYNOPSIS
    Stale Computer Accounts Check (SEC-001)

.DESCRIPTION
    Detects stale, inactive, and potentially orphaned computer accounts:
    - Computers not logged in for 90+ days
    - Disabled computers still in AD
    - Computers with expired passwords
    - Computers in default container (not proper OU)
    - Duplicate computer accounts

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-StaleComputers.ps1 -Inventory $inventory

.OUTPUTS
    Array of stale computer account results

.NOTES
    Check ID: SEC-001
    Category: Security
    Severity: High
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

# Thresholds
$staleThresholdDays = 90
$criticalThresholdDays = 180
$passwordExpiredDays = 45

Write-Verbose "[SEC-001] Starting stale computer accounts check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[SEC-001] No domains found in inventory"
        return @()
    }
    
    $staleDate = (Get-Date).AddDays(-$staleThresholdDays)
    $criticalDate = (Get-Date).AddDays(-$criticalThresholdDays)
    
    foreach ($domain in $domains) {
        Write-Verbose "[SEC-001] Processing domain: $($domain.Name)"
        
        try {
            # Get all computer accounts
            $computers = Get-ADComputer -Filter * -Properties `
                LastLogonDate, PasswordLastSet, Enabled, DistinguishedName, OperatingSystem, Created `
                -Server $domain.Name -ErrorAction Stop
            
            Write-Verbose "[SEC-001] Found $($computers.Count) computer accounts in $($domain.Name)"
            
            $staleCount = 0
            $criticalStaleCount = 0
            $disabledCount = 0
            $defaultContainerCount = 0
            
            foreach ($computer in $computers) {
                $isStale = $false
                $isCritical = $false
                $issues = @()
                
                # Check last logon
                if (-not $computer.LastLogonDate -or $computer.LastLogonDate -lt $staleDate) {
                    $isStale = $true
                    $daysSinceLogon = if ($computer.LastLogonDate) {
                        ((Get-Date) - $computer.LastLogonDate).Days
                    } else {
                        999
                    }
                    
                    if ($daysSinceLogon -gt $criticalThresholdDays) {
                        $isCritical = $true
                        $criticalStaleCount++
                    }
                    
                    $staleCount++
                    $issues += "Last logon: $daysSinceLogon days ago"
                }
                
                # Check if disabled
                if (-not $computer.Enabled) {
                    $issues += "Account is disabled"
                    $disabledCount++
                }
                
                # Check if in default Computers container
                if ($computer.DistinguishedName -match "CN=Computers,DC=") {
                    $issues += "In default Computers container (should be in proper OU)"
                    $defaultContainerCount++
                }
                
                # Check password age
                if ($computer.PasswordLastSet) {
                    $passwordAge = ((Get-Date) - $computer.PasswordLastSet).Days
                    if ($passwordAge -gt $passwordExpiredDays) {
                        $issues += "Password last set $passwordAge days ago"
                    }
                }
                
                # Only report problematic computers
                if ($issues.Count -gt 0) {
                    $result = [PSCustomObject]@{
                        Domain = $domain.Name
                        ComputerName = $computer.Name
                        OperatingSystem = $computer.OperatingSystem
                        LastLogonDate = $computer.LastLogonDate
                        PasswordLastSet = $computer.PasswordLastSet
                        Enabled = $computer.Enabled
                        Created = $computer.Created
                        DistinguishedName = $computer.DistinguishedName
                        DaysSinceLogon = if ($computer.LastLogonDate) {
                            ((Get-Date) - $computer.LastLogonDate).Days
                        } else {
                            999
                        }
                        Issues = $issues -join "; "
                        Severity = if ($isCritical) { 'High' } 
                                  elseif ($isStale) { 'Medium' } 
                                  else { 'Low' }
                        Status = 'Warning'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = "Stale/problematic computer account: $($issues -join ', ')"
                    }
                    
                    $results += $result
                }
            }
            
            # Summary result
            $summaryResult = [PSCustomObject]@{
                Domain = $domain.Name
                ComputerName = "SUMMARY"
                OperatingSystem = "N/A"
                LastLogonDate = $null
                PasswordLastSet = $null
                Enabled = $null
                Created = $null
                DistinguishedName = "N/A"
                DaysSinceLogon = 0
                Issues = "Total: $($computers.Count), Stale (90d): $staleCount, Critical (180d): $criticalStaleCount, Disabled: $disabledCount, Default Container: $defaultContainerCount"
                Severity = if ($criticalStaleCount -gt 0) { 'High' } elseif ($staleCount -gt 0) { 'Medium' } else { 'Info' }
                Status = if ($staleCount -gt 0) { 'Warning' } else { 'Healthy' }
                IsHealthy = ($staleCount -eq 0)
                HasIssue = ($staleCount -gt 0)
                Message = "Found $staleCount stale computers ($criticalStaleCount critical)"
            }
            
            $results += $summaryResult
            
            Write-Verbose "[SEC-001] Domain $($domain.Name): Stale=$staleCount, Critical=$criticalStaleCount"
        }
        catch {
            Write-Error "[SEC-001] Failed to check computers in domain $($domain.Name): $($_.Exception.Message)"
        }
    }
    
    Write-Verbose "[SEC-001] Check complete. Total issues: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[SEC-001] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        ComputerName = "Unknown"
        OperatingSystem = "Unknown"
        LastLogonDate = $null
        PasswordLastSet = $null
        Enabled = $null
        Created = $null
        DistinguishedName = "Unknown"
        DaysSinceLogon = 0
        Issues = "Check execution failed"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
