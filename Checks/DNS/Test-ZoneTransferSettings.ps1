<#
.SYNOPSIS
    Zone Transfer Settings Check (DNS-005)

.DESCRIPTION
    Validates DNS zone transfer settings for security.
    Ensures zone transfers are restricted to authorized servers only.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DNS-005
    Category: DNS
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

Write-Verbose "[DNS-005] Starting zone transfer settings check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DNS-005] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DNS-005] Checking zone transfers on: $($dc.Name)"
        
        try {
            # Get all DNS zones
            $zones = Get-DnsServerZone -ComputerName $dc.HostName -ErrorAction Stop
            
            $totalZones = $zones.Count
            $insecureZones = 0
            $restrictedZones = 0
            $disabledZones = 0
            $insecureZonesList = @()
            
            foreach ($zone in $zones) {
                # Skip auto-created zones
                if ($zone.ZoneName -match "^(TrustAnchors|_msdcs\.|\.arpa$)") {
                    continue
                }
                
                # Check zone transfer settings
                $transferSetting = $zone.SecureSecondaries
                
                switch ($transferSetting) {
                    'NoTransfer' {
                        $disabledZones++
                    }
                    'TransferToSecureServers' {
                        $restrictedZones++
                    }
                    'TransferToZoneNameServer' {
                        $restrictedZones++
                    }
                    'TransferAnyServer' {
                        $insecureZones++
                        $insecureZonesList += $zone.ZoneName
                    }
                    default {
                        # Unknown or null
                    }
                }
            }
            
            # Determine status
            $hasIssue = ($insecureZones -gt 0)
            $severity = if ($insecureZones -gt 3) { 'High' }
                       elseif ($insecureZones -gt 0) { 'Medium' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                TotalZones = $totalZones
                InsecureZones = $insecureZones
                RestrictedZones = $restrictedZones
                DisabledTransfers = $disabledZones
                InsecureZonesList = if ($insecureZonesList.Count -gt 0) {
                    ($insecureZonesList -join ", ")
                } else {
                    "None"
                }
                Severity = $severity
                Status = if ($insecureZones -gt 3) { 'Failed' }
                        elseif ($insecureZones -gt 0) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($insecureZones -gt 3) {
                    "WARNING: $insecureZones zones allow unrestricted transfers (security risk!)"
                }
                elseif ($insecureZones -gt 0) {
                    "$insecureZones zone(s) allow unrestricted transfers"
                }
                else {
                    "All $totalZones zones have secure transfer settings"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DNS-005] Failed to check zone transfers on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                TotalZones = 0
                InsecureZones = 0
                RestrictedZones = 0
                DisabledTransfers = 0
                InsecureZonesList = "Unknown"
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query zone transfers: $_"
            }
        }
    }
    
    Write-Verbose "[DNS-005] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DNS-005] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        TotalZones = 0
        InsecureZones = 0
        RestrictedZones = 0
        DisabledTransfers = 0
        InsecureZonesList = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
