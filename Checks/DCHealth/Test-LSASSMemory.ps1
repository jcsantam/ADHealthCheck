<#
.SYNOPSIS
    LSASS Memory Usage Check (DC-013)
.DESCRIPTION
    Checks LSASS process memory consumption on each domain controller.
    High LSASS memory usage can indicate memory leaks, excessive credential
    caching, or resource contention.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DC-013
    Category: DCHealth
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

# Thresholds in GB
$warningThresholdGB  = 1
$criticalThresholdGB = 2

Write-Verbose "[DC-013] Starting LSASS memory usage check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DC-013] No reachable DCs found"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-013] Checking LSASS memory on: $($dc.Name)"

        try {
            $lsassProc = Get-WmiObject -Class Win32_Process `
                -Filter "Name='lsass.exe'" `
                -ComputerName $dc.Name -ErrorAction Stop |
                Select-Object -First 1

            if (-not $lsassProc) {
                $results += [PSCustomObject]@{
                    DomainController   = $dc.Name
                    LsassMemoryGB      = 0
                    LsassMemoryMB      = 0
                    WarningThresholdGB = $warningThresholdGB
                    CriticalThresholdGB = $criticalThresholdGB
                    IsHealthy          = $false
                    HasIssue           = $true
                    Status             = 'Warning'
                    Severity           = 'Medium'
                    Message            = "LSASS process not found on $($dc.Name) - may indicate a service issue"
                }
                continue
            }

            # WorkingSetSize is in bytes
            $memoryBytes = [long]$lsassProc.WorkingSetSize
            $memoryMB    = [math]::Round($memoryBytes / 1MB, 1)
            $memoryGB    = [math]::Round($memoryBytes / 1GB, 2)

            $hasIssue = $memoryGB -gt $warningThresholdGB
            $severity = if ($memoryGB -gt $criticalThresholdGB) { 'High' }
                        elseif ($memoryGB -gt $warningThresholdGB) { 'Medium' }
                        else { 'Info' }
            $status   = if ($memoryGB -gt $criticalThresholdGB) { 'Fail' }
                        elseif ($memoryGB -gt $warningThresholdGB) { 'Warning' }
                        else { 'Healthy' }

            $results += [PSCustomObject]@{
                DomainController    = $dc.Name
                LsassMemoryGB       = $memoryGB
                LsassMemoryMB       = $memoryMB
                WarningThresholdGB  = $warningThresholdGB
                CriticalThresholdGB = $criticalThresholdGB
                IsHealthy           = -not $hasIssue
                HasIssue            = $hasIssue
                Status              = $status
                Severity            = $severity
                Message             = if ($memoryGB -gt $criticalThresholdGB) {
                    "FAIL: LSASS using $memoryGB GB on $($dc.Name) (threshold: $criticalThresholdGB GB)"
                } elseif ($memoryGB -gt $warningThresholdGB) {
                    "WARNING: LSASS using $memoryGB GB on $($dc.Name) (threshold: $warningThresholdGB GB)"
                } else {
                    "LSASS memory usage normal: $memoryGB GB ($memoryMB MB) on $($dc.Name)"
                }
            }
        }
        catch {
            Write-Warning "[DC-013] Failed to check LSASS on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController    = $dc.Name
                LsassMemoryGB       = 0
                LsassMemoryMB       = 0
                WarningThresholdGB  = $warningThresholdGB
                CriticalThresholdGB = $criticalThresholdGB
                IsHealthy           = $false
                HasIssue            = $true
                Status              = 'Error'
                Severity            = 'Error'
                Message             = "Failed to query LSASS process on $($dc.Name): $_"
            }
        }
    }

    Write-Verbose "[DC-013] Check complete. DCs checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DC-013] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController    = 'Unknown'
        LsassMemoryGB       = 0
        LsassMemoryMB       = 0
        WarningThresholdGB  = $warningThresholdGB
        CriticalThresholdGB = $criticalThresholdGB
        IsHealthy           = $false
        HasIssue            = $true
        Status              = 'Error'
        Severity            = 'Error'
        Message             = "Check execution failed: $($_.Exception.Message)"
    })
}
