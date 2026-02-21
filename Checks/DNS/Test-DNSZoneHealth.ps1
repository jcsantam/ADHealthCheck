<#
.SYNOPSIS
    DNS Zone Health Check (DNS-002)

.DESCRIPTION
    Checks AD-integrated DNS zone health:
    - Zone type (should be AD-integrated)
    - Dynamic updates enabled
    - Scavenging configuration
    - Zone replication scope

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-DNSZoneHealth.ps1 -Inventory $inventory

.OUTPUTS
    Array of DNS zone health results

.NOTES
    Check ID: DNS-002
    Category: DNS
    Severity: Medium
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[DNS-002] Starting DNS zone health check..."

try {
    # Get DCs that should have DNS role
    $dnsServers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $dnsServers -or $dnsServers.Count -eq 0) {
        Write-Warning "[DNS-002] No reachable domain controllers found"
        return @()
    }
    
    # Check first available DC with DNS
    $primaryDC = $dnsServers | Select-Object -First 1
    
    Write-Verbose "[DNS-002] Checking DNS zones on $($primaryDC.Name)..."
    
    try {
        # Get DNS zones
        $zones = Get-DnsServerZone -ComputerName $primaryDC.HostName -ErrorAction Stop
        
        # Filter to AD-integrated zones
        $adZones = $zones | Where-Object { 
            $_.ZoneType -eq 'Primary' -and 
            $_.IsDsIntegrated -eq $true 
        }
        
        foreach ($zone in $adZones) {
            # Check zone health
            $isHealthy = $true
            $issues = @()
            $severity = 'Info'
            
            # Check if dynamic updates are enabled
            if ($zone.DynamicUpdate -eq 'None') {
                $isHealthy = $false
                $issues += "Dynamic updates are disabled"
                $severity = 'Medium'
            }
            
            # Check scavenging
            if (-not $zone.Aging) {
                $issues += "Aging/scavenging is disabled (may cause stale records)"
                if ($severity -eq 'Info') { $severity = 'Low' }
            }
            
            # Check zone replication scope
            $replicationScope = "Unknown"
            if ($zone.ReplicationScope) {
                $replicationScope = $zone.ReplicationScope
            }
            
            $result = [PSCustomObject]@{
                DomainController = $primaryDC.Name
                ZoneName = $zone.ZoneName
                ZoneType = $zone.ZoneType
                IsADIntegrated = $zone.IsDsIntegrated
                DynamicUpdate = $zone.DynamicUpdate
                Scavenging = $zone.Aging
                ReplicationScope = $replicationScope
                Issues = if ($issues.Count -gt 0) { $issues -join "; " } else { "None" }
                Severity = $severity
                Status = if ($isHealthy) { 'Healthy' } else { 'Warning' }
                IsHealthy = $isHealthy
                HasIssue = -not $isHealthy
                Message = if ($isHealthy) { 
                    "DNS zone is properly configured" 
                } else { 
                    "DNS zone has configuration issues: $($issues -join ', ')" 
                }
            }
            
            $results += $result
        }
        
        if ($results.Count -eq 0) {
            Write-Warning "[DNS-002] No AD-integrated DNS zones found"
            
            $results = @([PSCustomObject]@{
                DomainController = $primaryDC.Name
                ZoneName = "None"
                ZoneType = "None"
                IsADIntegrated = $false
                DynamicUpdate = "N/A"
                Scavenging = $false
                ReplicationScope = "N/A"
                Issues = "No AD-integrated zones found"
                Severity = 'High'
                Status = 'Warning'
                IsHealthy = $false
                HasIssue = $true
                Message = "WARNING: No AD-integrated DNS zones found on DC"
            })
        }
    }
    catch {
        Write-Warning "[DNS-002] Failed to query DNS zones on $($primaryDC.Name): $($_.Exception.Message)"
        
        $results = @([PSCustomObject]@{
            DomainController = $primaryDC.Name
            ZoneName = "Unknown"
            ZoneType = "Unknown"
            IsADIntegrated = $false
            DynamicUpdate = "Unknown"
            Scavenging = $false
            ReplicationScope = "Unknown"
            Issues = "Failed to query DNS zones"
            Severity = 'Error'
            Status = 'Error'
            IsHealthy = $false
            HasIssue = $true
            Message = "Failed to query DNS zones: $($_.Exception.Message)"
        })
    }
    
    Write-Verbose "[DNS-002] Check complete. Zones checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DNS-002] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        ZoneName = "Unknown"
        ZoneType = "Unknown"
        IsADIntegrated = $false
        DynamicUpdate = "Unknown"
        Scavenging = $false
        ReplicationScope = "Unknown"
        Issues = "Check execution failed"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
