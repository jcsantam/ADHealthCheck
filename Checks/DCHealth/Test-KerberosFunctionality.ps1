<#
.SYNOPSIS
    Kerberos Functionality Check (DC-008)

.DESCRIPTION
    Validates Kerberos Key Distribution Center (KDC) service functionality.
    Checks service status and recent authentication errors.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DC-008
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

# Kerberos error event IDs
$kerberosErrors = @(
    4,      # KDC cannot find certificate
    11,     # Encryption type not supported
    14,     # No domain controller available
    27      # KDC policy failure
)

Write-Verbose "[DC-008] Starting Kerberos functionality check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DC-008] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-008] Checking Kerberos on: $($dc.Name)"
        
        try {
            # Check KDC service
            $kdcService = Get-Service -Name "Kdc" -ComputerName $dc.HostName -ErrorAction Stop
            
            $serviceRunning = ($kdcService.Status -eq 'Running')
            
            # Check for Kerberos errors in last 24 hours
            $errorCount = 0
            try {
                $events = Get-WinEvent -ComputerName $dc.HostName -FilterHashtable @{
                    LogName = 'System'
                    ProviderName = 'Microsoft-Windows-Kerberos-Key-Distribution-Center'
                    Level = 2  # Error
                    StartTime = (Get-Date).AddHours(-24)
                } -ErrorAction SilentlyContinue
                
                $errorCount = if ($events) { $events.Count } else { 0 }
            }
            catch {
                # No events or can't query
                $errorCount = 0
            }
            
            # Determine status
            $hasIssue = (-not $serviceRunning) -or ($errorCount -gt 10)
            $severity = if (-not $serviceRunning) { 'Critical' }
                       elseif ($errorCount -gt 50) { 'High' }
                       elseif ($errorCount -gt 10) { 'Medium' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                KDCServiceStatus = $kdcService.Status
                KDCServiceRunning = $serviceRunning
                ErrorsLast24Hours = $errorCount
                Severity = $severity
                Status = if (-not $serviceRunning) { 'Failed' }
                        elseif ($errorCount -gt 50) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if (-not $serviceRunning) {
                    "CRITICAL: KDC service not running!"
                }
                elseif ($errorCount -gt 50) {
                    "WARNING: $errorCount Kerberos errors in last 24 hours"
                }
                elseif ($errorCount -gt 10) {
                    "Moderate Kerberos errors: $errorCount in last 24 hours"
                }
                else {
                    "Kerberos healthy (KDC running, $errorCount errors)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DC-008] Failed to check Kerberos on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                KDCServiceStatus = "Unknown"
                KDCServiceRunning = $false
                ErrorsLast24Hours = 0
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query Kerberos: $_"
            }
        }
    }
    
    Write-Verbose "[DC-008] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DC-008] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        KDCServiceStatus = "Unknown"
        KDCServiceRunning = $false
        ErrorsLast24Hours = 0
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
