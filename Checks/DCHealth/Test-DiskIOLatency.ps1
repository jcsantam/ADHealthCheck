<#
.SYNOPSIS
    Disk I/O Latency Check (DC-006)

.DESCRIPTION
    Measures disk read/write latency on domain controllers.
    High latency indicates storage performance issues affecting AD operations.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DC-006
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

# Thresholds (in milliseconds)
$warningThreshold = 20
$criticalThreshold = 50

Write-Verbose "[DC-006] Starting disk I/O latency check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DC-006] No reachable DCs"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-006] Checking disk I/O on: $($dc.Name)"

        try {
            # Primary: Get-Counter
            $readLatency = Get-Counter -ComputerName $dc.Name `
                -Counter "\PhysicalDisk(*)\Avg. Disk sec/Read" `
                -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop

            $writeLatency = Get-Counter -ComputerName $dc.Name `
                -Counter "\PhysicalDisk(*)\Avg. Disk sec/Write" `
                -SampleInterval 1 -MaxSamples 3 -ErrorAction Stop

            $avgReadMs = ($readLatency.CounterSamples | Where-Object { $_.InstanceName -ne "_Total" } |
                Measure-Object -Property CookedValue -Average).Average * 1000

            $avgWriteMs = ($writeLatency.CounterSamples | Where-Object { $_.InstanceName -ne "_Total" } |
                Measure-Object -Property CookedValue -Average).Average * 1000

            $maxLatency = [math]::Max($avgReadMs, $avgWriteMs)
            $hasIssue = $maxLatency -gt $warningThreshold

            $results += [PSCustomObject]@{
                DomainController  = $dc.Name
                AvgReadLatencyMs  = [math]::Round($avgReadMs, 1)
                AvgWriteLatencyMs = [math]::Round($avgWriteMs, 1)
                MaxLatencyMs      = [math]::Round($maxLatency, 1)
                WarningThreshold  = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity          = if ($maxLatency -gt $criticalThreshold) { 'Critical' } elseif ($maxLatency -gt $warningThreshold) { 'High' } else { 'Info' }
                Status            = if ($maxLatency -gt $criticalThreshold) { 'Failed' } elseif ($maxLatency -gt $warningThreshold) { 'Warning' } else { 'Healthy' }
                IsHealthy         = -not $hasIssue
                HasIssue          = $hasIssue
                Message           = if ($maxLatency -gt $criticalThreshold) { "CRITICAL: Disk latency at $([math]::Round($maxLatency,1))ms" } elseif ($maxLatency -gt $warningThreshold) { "WARNING: Disk latency at $([math]::Round($maxLatency,1))ms" } else { "Disk I/O healthy ($([math]::Round($maxLatency,1))ms avg)" }
            }
        }
        catch {
            # Fallback for 2012 R2 performance counter failures (error c0000bb8)
            if ($_.Exception.Message -match 'c0000bb8') {
                $results += [PSCustomObject]@{
                    DomainController  = $dc.Name
                    AvgReadLatencyMs  = 0
                    AvgWriteLatencyMs = 0
                    MaxLatencyMs      = 0
                    WarningThreshold  = $warningThreshold
                    CriticalThreshold = $criticalThreshold
                    Severity          = 'Unknown'
                    Status            = 'Unknown'
                    IsHealthy         = $null
                    HasIssue          = $false
                    Message           = "Performance counter unavailable. Run 'lodctr /r' on $($dc.Name) to rebuild counters."
                }
            }
            else {
                $results += [PSCustomObject]@{
                    DomainController  = $dc.Name
                    AvgReadLatencyMs  = 0
                    AvgWriteLatencyMs = 0
                    MaxLatencyMs      = 0
                    WarningThreshold  = $warningThreshold
                    CriticalThreshold = $criticalThreshold
                    Severity          = 'Error'
                    Status            = 'Error'
                    IsHealthy         = $false
                    HasIssue          = $true
                    Message           = "Failed to query disk I/O: $_"
                }
            }
        }
    }

    Write-Verbose "[DC-006] Check complete. DCs checked: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-006] Check failed: $_"
    return @([PSCustomObject]@{
        DomainController  = "Unknown"
        AvgReadLatencyMs  = 0
        AvgWriteLatencyMs = 0
        MaxLatencyMs      = 0
        WarningThreshold  = $warningThreshold
        CriticalThreshold = $criticalThreshold
        Severity          = 'Error'
        Status            = 'Error'
        IsHealthy         = $false
        HasIssue          = $true
        Message           = "Check execution failed: $_"
    })
}