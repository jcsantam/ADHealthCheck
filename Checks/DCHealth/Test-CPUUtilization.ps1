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
            # Primary: Get-Counter
            $cpuCounter = Get-Counter -ComputerName $dc.Name `
                -Counter "\Processor(_Total)\% Processor Time" `
                -SampleInterval 1 -MaxSamples 5 -ErrorAction Stop

            $cpuValues = $cpuCounter.CounterSamples | ForEach-Object { $_.CookedValue }
            $avgCPU = ($cpuValues | Measure-Object -Average).Average
            $maxCPU = ($cpuValues | Measure-Object -Maximum).Maximum

            $hasIssue = $avgCPU -gt $warningThreshold

            $results += [PSCustomObject]@{
                DomainController  = $dc.Name
                AverageCPU        = [math]::Round($avgCPU, 1)
                MaxCPU            = [math]::Round($maxCPU, 1)
                SampleCount       = 5
                WarningThreshold  = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity          = if ($avgCPU -gt $criticalThreshold) { 'Critical' } elseif ($avgCPU -gt $warningThreshold) { 'High' } else { 'Info' }
                Status            = if ($avgCPU -gt $criticalThreshold) { 'Failed' } elseif ($avgCPU -gt $warningThreshold) { 'Warning' } else { 'Healthy' }
                IsHealthy         = -not $hasIssue
                HasIssue          = $hasIssue
                Message           = if ($avgCPU -gt $criticalThreshold) { "CRITICAL: CPU at $([math]::Round($avgCPU,1))%" } elseif ($avgCPU -gt $warningThreshold) { "WARNING: CPU at $([math]::Round($avgCPU,1))%" } else { "CPU healthy at $([math]::Round($avgCPU,1))%" }
            }
        }
        catch {
            # Fallback: WMI for 2012 R2 performance counter failures
            try {
                $wmiCPU = Get-WmiObject -Query "SELECT LoadPercentage FROM Win32_Processor" `
                    -ComputerName $dc.Name -ErrorAction Stop
                $avgCPU = ($wmiCPU | Measure-Object -Property LoadPercentage -Average).Average
                $maxCPU = $avgCPU
                $hasIssue = $avgCPU -gt $warningThreshold

                $results += [PSCustomObject]@{
                    DomainController  = $dc.Name
                    AverageCPU        = [math]::Round($avgCPU, 1)
                    MaxCPU            = [math]::Round($maxCPU, 1)
                    SampleCount       = 1
                    WarningThreshold  = $warningThreshold
                    CriticalThreshold = $criticalThreshold
                    Severity          = if ($avgCPU -gt $criticalThreshold) { 'Critical' } elseif ($avgCPU -gt $warningThreshold) { 'High' } else { 'Info' }
                    Status            = if ($avgCPU -gt $criticalThreshold) { 'Failed' } elseif ($avgCPU -gt $warningThreshold) { 'Warning' } else { 'Healthy' }
                    IsHealthy         = -not $hasIssue
                    HasIssue          = $hasIssue
                    Message           = "CPU at $([math]::Round($avgCPU,1))% (WMI fallback)"
                }
            }
            catch {
                $results += [PSCustomObject]@{
                    DomainController  = $dc.Name
                    AverageCPU        = 0
                    MaxCPU            = 0
                    SampleCount       = 0
                    WarningThreshold  = $warningThreshold
                    CriticalThreshold = $criticalThreshold
                    Severity          = 'Error'
                    Status            = 'Error'
                    IsHealthy         = $false
                    HasIssue          = $true
                    Message           = "Failed to query CPU: $_"
                }
            }
        }
    }

    Write-Verbose "[DC-004] Check complete. DCs checked: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-004] Check failed: $_"
    return @([PSCustomObject]@{
        DomainController  = "Unknown"
        AverageCPU        = 0
        MaxCPU            = 0
        SampleCount       = 0
        WarningThreshold  = $warningThreshold
        CriticalThreshold = $criticalThreshold
        Severity          = 'Error'
        Status            = 'Error'
        IsHealthy         = $false
        HasIssue          = $true
        Message           = "Check execution failed: $_"
    })
}