<#
.SYNOPSIS
    DNS Forwarders Check (DNS-003)

.DESCRIPTION
    Validates DNS forwarder configuration on domain controllers.
    Checks if forwarders are configured and accessible.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DNS-003
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

Write-Verbose "[DNS-003] Starting DNS forwarders check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DNS-003] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DNS-003] Checking DNS forwarders on: $($dc.Name)"
        
        try {
            # Get DNS forwarders
            $forwarders = Get-DnsServerForwarder -ComputerName $dc.HostName -ErrorAction Stop
            
            if (-not $forwarders.IPAddress -or $forwarders.IPAddress.Count -eq 0) {
                # No forwarders configured
                $result = [PSCustomObject]@{
                    DomainController = $dc.Name
                    ForwardersConfigured = $false
                    ForwarderCount = 0
                    ForwarderIPs = "None"
                    AllForwardersReachable = $false
                    UseRootHints = $forwarders.UseRootHint
                    Severity = 'Low'
                    Status = 'Warning'
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "No DNS forwarders configured (using root hints)"
                }
                
                $results += $result
                continue
            }
            
            # Test forwarder reachability
            $reachableCount = 0
            $forwarderIPs = @()
            
            foreach ($forwarderIP in $forwarders.IPAddress) {
                $forwarderIPs += $forwarderIP.IPAddressToString
                
                # Test if forwarder is reachable
                $pingResult = Test-Connection -ComputerName $forwarderIP.IPAddressToString `
                    -Count 1 -Quiet -ErrorAction SilentlyContinue
                
                if ($pingResult) {
                    $reachableCount++
                }
            }
            
            $allReachable = ($reachableCount -eq $forwarders.IPAddress.Count)
            $someReachable = ($reachableCount -gt 0)
            
            # Determine status
            $severity = if (-not $someReachable) { 'High' }
                       elseif (-not $allReachable) { 'Medium' }
                       else { 'Info' }
            
            $hasIssue = (-not $someReachable)
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                ForwardersConfigured = $true
                ForwarderCount = $forwarders.IPAddress.Count
                ForwarderIPs = ($forwarderIPs -join ", ")
                ReachableCount = $reachableCount
                AllForwardersReachable = $allReachable
                UseRootHints = $forwarders.UseRootHint
                Severity = $severity
                Status = if (-not $someReachable) { 'Failed' }
                        elseif (-not $allReachable) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if (-not $someReachable) {
                    "CRITICAL: No DNS forwarders reachable!"
                }
                elseif (-not $allReachable) {
                    "WARNING: Only $reachableCount of $($forwarders.IPAddress.Count) forwarders reachable"
                }
                else {
                    "All $($forwarders.IPAddress.Count) forwarders reachable"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DNS-003] Failed to check forwarders on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                ForwardersConfigured = $null
                ForwarderCount = 0
                ForwarderIPs = "Unknown"
                ReachableCount = 0
                AllForwardersReachable = $false
                UseRootHints = $null
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query forwarders: $_"
            }
        }
    }
    
    Write-Verbose "[DNS-003] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DNS-003] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        ForwardersConfigured = $null
        ForwarderCount = 0
        ForwarderIPs = "Unknown"
        ReachableCount = 0
        AllForwardersReachable = $false
        UseRootHints = $null
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
