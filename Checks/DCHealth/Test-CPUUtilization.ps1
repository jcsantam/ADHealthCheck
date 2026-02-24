<#
.SYNOPSIS
    CPU Utilization Check (DC-004)

.DESCRIPTION
    Monitors CPU usage on domain controllers. Detects sustained high CPU
    that may indicate performance issues or resource contention.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DC-004
    Category: DCHealth
    Severity: High
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
$warningThreshold = 80
$criticalThreshold = 95

Write-Verbose "[DC-004] Starting CPU utilization check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DC-004] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-004] Checking CPU on: $($dc.Name)"
        
        try {
            # Get CPU usage using Get-Counter (works on 2012 R2+)
            $cpuCounter = Get-Counter -ComputerName $dc.HostName `
                -Counter "\Processor(_Total)\% Processor Time" `
                -SampleInterval 1 -MaxSamples 5 -ErrorAction Stop
            
            # Calculate average
            $cpuValues = $cpuCounter.CounterSamples | ForEach-Object { $_.CookedValue }
            $avgCPU = ($cpuValues | Measure-Object -Average).Average
            $maxCPU = ($cpuValues | Measure-Object -Maximum).Maximum
            
            # Determine status
            $hasIssue = $avgCPU -gt $warningThreshold
            $severity = if ($avgCPU -gt $criticalThreshold) { 'Critical' }
                       elseif ($avgCPU -gt $warningThreshold) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                AverageCPU = [math]::Round($avgCPU, 1)
                MaxCPU = [math]::Round($maxCPU, 1)
                SampleCount = 5
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = $severity
                Status = if ($avgCPU -gt $criticalThreshold) { 'Failed' }
                        elseif ($avgCPU -gt $warningThreshold) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($avgCPU -gt $criticalThreshold) {
                    "CRITICAL: CPU at $([math]::Round($avgCPU, 1))% (threshold: $criticalThreshold%)"
                }
                elseif ($avgCPU -gt $warningThreshold) {
                    "WARNING: CPU at $([math]::Round($avgCPU, 1))% (threshold: $warningThreshold%)"
                }
                else {
                    "CPU healthy at $([math]::Round($avgCPU, 1))%"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DC-004] Failed to check CPU on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                AverageCPU = 0
                MaxCPU = 0
                SampleCount = 0
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query CPU: $_"
            }
        }
    }
    
    Write-Verbose "[DC-004] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DC-004] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        AverageCPU = 0
        MaxCPU = 0
        SampleCount = 0
        WarningThreshold = $warningThreshold
        CriticalThreshold = $criticalThreshold
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
