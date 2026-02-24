<#
.SYNOPSIS
    LDAP Response Time Check (DC-007)

.DESCRIPTION
    Measures LDAP query response time on domain controllers.
    High response time indicates performance issues affecting authentication.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DC-007
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
$warningThreshold = 100
$criticalThreshold = 500

Write-Verbose "[DC-007] Starting LDAP response time check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DC-007] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-007] Testing LDAP on: $($dc.Name)"
        
        try {
            # Test LDAP query performance
            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            
            $searcher = New-Object DirectoryServices.DirectorySearcher
            $searcher.SearchRoot = "LDAP://$($dc.HostName)"
            $searcher.Filter = "(objectClass=user)"
            $searcher.PropertiesToLoad.Add("cn") | Out-Null
            $searcher.PageSize = 100
            $searcher.SizeLimit = 100
            
            $results_search = $searcher.FindAll()
            $stopwatch.Stop()
            
            $responseTimeMs = $stopwatch.ElapsedMilliseconds
            
            # Determine status
            $hasIssue = $responseTimeMs -gt $warningThreshold
            $severity = if ($responseTimeMs -gt $criticalThreshold) { 'Critical' }
                       elseif ($responseTimeMs -gt $warningThreshold) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                ResponseTimeMs = $responseTimeMs
                ResultCount = $results_search.Count
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = $severity
                Status = if ($responseTimeMs -gt $criticalThreshold) { 'Failed' }
                        elseif ($responseTimeMs -gt $warningThreshold) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($responseTimeMs -gt $criticalThreshold) {
                    "CRITICAL: LDAP response time $responseTimeMs ms (threshold: $criticalThreshold ms)"
                }
                elseif ($responseTimeMs -gt $warningThreshold) {
                    "WARNING: LDAP response time $responseTimeMs ms (threshold: $warningThreshold ms)"
                }
                else {
                    "LDAP response healthy ($responseTimeMs ms)"
                }
            }
            
            $results += $result
            
            # Cleanup
            $results_search.Dispose()
            $searcher.Dispose()
        }
        catch {
            Write-Warning "[DC-007] Failed to test LDAP on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                ResponseTimeMs = 9999
                ResultCount = 0
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query LDAP: $_"
            }
        }
    }
    
    Write-Verbose "[DC-007] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DC-007] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        ResponseTimeMs = 9999
        ResultCount = 0
        WarningThreshold = $warningThreshold
        CriticalThreshold = $criticalThreshold
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
