<#
.SYNOPSIS
    Active Directory Recycle Bin Status Check (BACKUP-002)

.DESCRIPTION
    Checks if AD Recycle Bin is enabled. Recycle Bin allows recovery
    of deleted objects without authoritative restore.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: BACKUP-002
    Category: Backup
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

Write-Verbose "[BACKUP-002] Starting AD Recycle Bin status check..."

try {
    $forestInfo = $Inventory.ForestInfo
    
    if (-not $forestInfo) {
        Write-Warning "[BACKUP-002] No forest info found"
        return @()
    }
    
    Write-Verbose "[BACKUP-002] Checking Recycle Bin for forest: $($forestInfo.Name)"
    
    try {
        # Get AD Optional Features
        $recycleBin = Get-ADOptionalFeature -Filter {Name -eq 'Recycle Bin Feature'} `
            -Server $forestInfo.Name -ErrorAction Stop
        
        if (-not $recycleBin) {
            $result = [PSCustomObject]@{
                Forest = $forestInfo.Name
                RecycleBinEnabled = $false
                EnabledScopes = "None"
                ForestFunctionalLevel = $forestInfo.ForestMode
                MinimumLevel = "Windows2008R2Forest"
                Severity = 'Medium'
                Status = 'Warning'
                IsHealthy = $false
                HasIssue = $true
                Message = "Recycle Bin not enabled - deleted objects cannot be easily recovered"
            }
            
            $results += $result
        }
        else {
            # Check if enabled
            $isEnabled = ($recycleBin.EnabledScopes.Count -gt 0)
            
            $result = [PSCustomObject]@{
                Forest = $forestInfo.Name
                RecycleBinEnabled = $isEnabled
                EnabledScopes = if ($isEnabled) {
                    ($recycleBin.EnabledScopes -join ", ")
                } else {
                    "None"
                }
                ForestFunctionalLevel = $forestInfo.ForestMode
                MinimumLevel = "Windows2008R2Forest"
                Severity = if ($isEnabled) { 'Info' } else { 'Medium' }
                Status = if ($isEnabled) { 'Healthy' } else { 'Warning' }
                IsHealthy = $isEnabled
                HasIssue = -not $isEnabled
                Message = if ($isEnabled) {
                    "Recycle Bin enabled - deleted objects can be recovered"
                }
                else {
                    "Recycle Bin not enabled - consider enabling for easier recovery"
                }
            }
            
            $results += $result
        }
    }
    catch {
        Write-Warning "[BACKUP-002] Failed to check Recycle Bin: $_"
        
        $results += [PSCustomObject]@{
            Forest = $forestInfo.Name
            RecycleBinEnabled = $null
            EnabledScopes = "Unknown"
            ForestFunctionalLevel = $forestInfo.ForestMode
            MinimumLevel = "Windows2008R2Forest"
            Severity = 'Error'
            Status = 'Error'
            IsHealthy = $false
            HasIssue = $true
            Message = "Failed to query Recycle Bin: $_"
        }
    }
    
    Write-Verbose "[BACKUP-002] Check complete"
    
    return $results
}
catch {
    Write-Error "[BACKUP-002] Check failed: $_"
    
    return @([PSCustomObject]@{
        Forest = "Unknown"
        RecycleBinEnabled = $null
        EnabledScopes = "Unknown"
        ForestFunctionalLevel = "Unknown"
        MinimumLevel = "Windows2008R2Forest"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
