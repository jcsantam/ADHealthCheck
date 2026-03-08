<#
.SYNOPSIS
    Memory Pressure Check (DC-005)

.DESCRIPTION
    Monitors available memory on domain controllers. Detects memory pressure
    that may lead to performance issues or out-of-memory conditions.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DC-005
    Category: DCHealth
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

# Thresholds (percentage of available memory)
$warningThreshold = 20  # Less than 20% available
$criticalThreshold = 10 # Less than 10% available

Write-Verbose "[DC-005] Starting memory pressure check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DC-005] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-005] Checking memory on: $($dc.Name)"
        
        try {
            # Get memory info using WMI (compatible with 2012 R2+)
            $os = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $dc.HostName -ErrorAction Stop
            
            $totalMemoryGB = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
            $freeMemoryGB = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
            $usedMemoryGB = $totalMemoryGB - $freeMemoryGB
            $freeMemoryPercent = [math]::Round(($freeMemoryGB / $totalMemoryGB) * 100, 1)
            
            # Determine status
            $hasIssue = $freeMemoryPercent -lt $warningThreshold
            $severity = if ($freeMemoryPercent -lt $criticalThreshold) { 'Critical' }
                       elseif ($freeMemoryPercent -lt $warningThreshold) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                TotalMemoryGB = $totalMemoryGB
                FreeMemoryGB = $freeMemoryGB
                UsedMemoryGB = $usedMemoryGB
                FreeMemoryPercent = $freeMemoryPercent
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = $severity
                Status = if ($freeMemoryPercent -lt $criticalThreshold) { 'Failed' }
                        elseif ($freeMemoryPercent -lt $warningThreshold) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($freeMemoryPercent -lt $criticalThreshold) {
                    "CRITICAL: Only $freeMemoryPercent% memory available ($freeMemoryGB GB free)"
                }
                elseif ($freeMemoryPercent -lt $warningThreshold) {
                    "WARNING: Only $freeMemoryPercent% memory available ($freeMemoryGB GB free)"
                }
                else {
                    "Memory healthy: $freeMemoryPercent% available ($freeMemoryGB GB free)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DC-005] Failed to check memory on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                TotalMemoryGB = 0
                FreeMemoryGB = 0
                UsedMemoryGB = 0
                FreeMemoryPercent = 0
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query memory: $_"
            }
        }
    }
    
    Write-Verbose "[DC-005] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DC-005] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        TotalMemoryGB = 0
        FreeMemoryGB = 0
        UsedMemoryGB = 0
        FreeMemoryPercent = 0
        WarningThreshold = $warningThreshold
        CriticalThreshold = $criticalThreshold
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
