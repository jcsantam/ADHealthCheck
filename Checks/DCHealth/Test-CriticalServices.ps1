<#
.SYNOPSIS
    Critical Services Status Check (DC-001)

.DESCRIPTION
    Validates that critical AD services are running on each DC:
    - NTDS (Active Directory Domain Services)
    - Netlogon
    - DNS (if DNS role installed)
    - KDC (Kerberos Key Distribution Center)
    - W32Time

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-CriticalServices.ps1 -Inventory $inventory

.OUTPUTS
    Array of service status objects

.NOTES
    Check ID: DC-001
    Category: DCHealth
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

# Critical services to check
$criticalServices = @('NTDS', 'Netlogon', 'DNS', 'KDC', 'W32Time')

Write-Verbose "[DC-001] Starting critical services check..."

try {
    $domainControllers = $Inventory.DomainControllers
    
    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-001] No domain controllers found in inventory"
        return @()
    }
    
    Write-Verbose "[DC-001] Checking services on $($domainControllers.Count) domain controllers..."
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-001] Processing DC: $($dc.Name)"
        
        # Only check DCs that are reachable
        if (-not $dc.IsReachable) {
            Write-Verbose "[DC-001] DC $($dc.Name) is not reachable, skipping service check"
            
            foreach ($serviceName in $criticalServices) {
                $results += [PSCustomObject]@{
                    DomainController = $dc.Name
                    ServiceName = $serviceName
                    ServiceStatus = 'Unknown'
                    StartupType = 'Unknown'
                    IsRunning = $false
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "DC unreachable, cannot check service status"
                }
            }
            continue
        }
        
        foreach ($serviceName in $criticalServices) {
            try {
                # Get service status
                $service = Get-Service -Name $serviceName -ComputerName $dc.HostName -ErrorAction Stop
                
                $isRunning = ($service.Status -eq 'Running')
                $isAutomatic = ($service.StartType -eq 'Automatic')
                
                # DNS is optional (only if DNS role is installed)
                $isOptional = ($serviceName -eq 'DNS')
                
                $hasIssue = -not $isRunning -and -not $isOptional
                
                $result = [PSCustomObject]@{
                    DomainController = $dc.Name
                    ServiceName = $serviceName
                    ServiceStatus = $service.Status.ToString()
                    StartupType = $service.StartType.ToString()
                    IsRunning = $isRunning
                    IsHealthy = $isRunning -or $isOptional
                    HasIssue = $hasIssue
                    Message = if ($hasIssue) {
                        "Critical service $serviceName is not running (Status: $($service.Status))"
                    } elseif (-not $isRunning -and $isOptional) {
                        "Optional service $serviceName is not running (may be expected)"
                    } else {
                        "Service is running normally"
                    }
                }
                
                $results += $result
            }
            catch {
                Write-Warning "[DC-001] Failed to query service $serviceName on $($dc.Name): $($_.Exception.Message)"
                
                # Service might not exist (e.g., DNS not installed)
                $serviceNotFound = $_.Exception.Message -like "*Cannot find any service*"
                
                $results += [PSCustomObject]@{
                    DomainController = $dc.Name
                    ServiceName = $serviceName
                    ServiceStatus = if ($serviceNotFound) { 'NotInstalled' } else { 'Error' }
                    StartupType = 'Unknown'
                    IsRunning = $false
                    IsHealthy = $serviceNotFound  # Not installed is OK for optional services
                    HasIssue = -not $serviceNotFound
                    Message = if ($serviceNotFound) {
                        "Service not installed (may be expected for $serviceName)"
                    } else {
                        "Failed to query service: $($_.Exception.Message)"
                    }
                }
            }
        }
    }
    
    Write-Verbose "[DC-001] Check complete. Services checked: $($results.Count)"
    
    # Summary
    $healthyCount = ($results | Where-Object { $_.IsHealthy }).Count
    $issueCount = ($results | Where-Object { $_.HasIssue }).Count
    
    Write-Verbose "[DC-001] Healthy: $healthyCount, Issues: $issueCount"
    
    return $results
}
catch {
    Write-Error "[DC-001] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        ServiceName = "Unknown"
        ServiceStatus = 'Error'
        StartupType = 'Unknown'
        IsRunning = $false
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
