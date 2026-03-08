<#
.SYNOPSIS
    DNS Scavenging Configuration Check (DNS-006)

.DESCRIPTION
    Validates DNS scavenging settings to prevent stale DNS records.
    Checks if scavenging is enabled and properly configured.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DNS-006
    Category: DNS
    Severity: Low
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

# Recommended intervals (in days)
$recommendedNoRefreshInterval = 7
$recommendedRefreshInterval = 7

Write-Verbose "[DNS-006] Starting DNS scavenging configuration check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DNS-006] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DNS-006] Checking scavenging on: $($dc.Name)"
        
        try {
            # Get server scavenging settings
            $serverSettings = Get-DnsServerScavenging -ComputerName $dc.HostName -ErrorAction Stop
            
            $scavengingEnabled = $serverSettings.ScavengingState
            $scavengingInterval = $serverSettings.ScavengingInterval.Days
            $noRefreshInterval = $serverSettings.NoRefreshInterval.Days
            $refreshInterval = $serverSettings.RefreshInterval.Days
            
            # Get zones with scavenging enabled
            $zones = Get-DnsServerZone -ComputerName $dc.HostName -ErrorAction Stop
            $zonesWithScavenging = ($zones | Where-Object { $_.IsAutoCreated -eq $false -and $_.Aging -eq $true }).Count
            $totalZones = ($zones | Where-Object { $_.IsAutoCreated -eq $false }).Count
            
            # Analyze configuration
            $warnings = @()
            
            if (-not $scavengingEnabled) {
                $warnings += "Scavenging is disabled server-wide"
            }
            
            if ($scavengingInterval -eq 0) {
                $warnings += "Scavenging interval is 0 (scavenging will not run)"
            }
            elseif ($scavengingInterval -gt 7) {
                $warnings += "Scavenging interval is $scavengingInterval days (recommended: ≤7)"
            }
            
            if ($zonesWithScavenging -eq 0) {
                $warnings += "No zones have aging/scavenging enabled"
            }
            elseif ($zonesWithScavenging -lt $totalZones) {
                $warnings += "Only $zonesWithScavenging of $totalZones zones have scavenging enabled"
            }
            
            # Determine status
            $hasIssue = ($warnings.Count -gt 0)
            $severity = if (-not $scavengingEnabled) { 'Medium' }
                       elseif ($warnings.Count -gt 2) { 'Low' }
                       elseif ($warnings.Count -gt 0) { 'Info' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                ScavengingEnabled = $scavengingEnabled
                ScavengingIntervalDays = $scavengingInterval
                NoRefreshIntervalDays = $noRefreshInterval
                RefreshIntervalDays = $refreshInterval
                TotalZones = $totalZones
                ZonesWithScavenging = $zonesWithScavenging
                WarningsFound = $warnings.Count
                WarningsList = if ($warnings.Count -gt 0) { ($warnings -join "; ") } else { "None" }
                Severity = $severity
                Status = if (-not $scavengingEnabled) { 'Warning' }
                        elseif ($warnings.Count -gt 0) { 'Info' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if (-not $scavengingEnabled) {
                    "Scavenging disabled - stale DNS records may accumulate"
                }
                elseif ($zonesWithScavenging -eq 0) {
                    "Scavenging enabled but no zones configured"
                }
                elseif ($warnings.Count -gt 0) {
                    "Scavenging configured but could be optimized ($($warnings.Count) recommendations)"
                }
                else {
                    "Scavenging properly configured ($zonesWithScavenging zones enabled)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DNS-006] Failed to check scavenging on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                ScavengingEnabled = $null
                ScavengingIntervalDays = 0
                NoRefreshIntervalDays = 0
                RefreshIntervalDays = 0
                TotalZones = 0
                ZonesWithScavenging = 0
                WarningsFound = 0
                WarningsList = "Unknown"
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query scavenging settings: $_"
            }
        }
    }
    
    Write-Verbose "[DNS-006] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DNS-006] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        ScavengingEnabled = $null
        ScavengingIntervalDays = 0
        NoRefreshIntervalDays = 0
        RefreshIntervalDays = 0
        TotalZones = 0
        ZonesWithScavenging = 0
        WarningsFound = 0
        WarningsList = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
