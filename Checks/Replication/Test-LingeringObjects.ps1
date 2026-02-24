<#
.SYNOPSIS
    Lingering Objects Detection Check (REP-009)

.DESCRIPTION
    Detects lingering objects in Active Directory - objects that should have been
    deleted but remain due to replication issues. Uses advisory mode (read-only).

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: REP-009
    Category: Replication
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

Write-Verbose "[REP-009] Starting lingering objects detection check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[REP-009] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[REP-009] Checking domain: $($domain.Name)"
        
        try {
            $domainDCs = $Inventory.DomainControllers | 
                Where-Object { $_.Domain -eq $domain.Name -and $_.IsReachable }
            
            if ($domainDCs.Count -lt 2) {
                Write-Verbose "[REP-009] Only one DC - skipping check"
                continue
            }
            
            # Get domain DN
            $domainDN = (Get-ADDomain -Server $domain.Name).DistinguishedName
            
            # Use PDC as reference server
            $pdcName = $domain.PDCEmulator
            
            foreach ($dc in $domainDCs) {
                if ($dc.Name -eq $pdcName) { continue }
                
                Write-Verbose "[REP-009] Checking for lingering objects on: $($dc.Name)"
                
                try {
                    # Run repadmin in advisory mode (read-only, no changes)
                    $repadminOutput = & repadmin /removelingeringobjects $dc.HostName $pdcName $domainDN /advisory_mode 2>&1 | Out-String
                    
                    # Parse output for lingering objects count
                    $lingeringCount = 0
                    
                    if ($repadminOutput -match "(\d+) lingering object") {
                        $lingeringCount = [int]$matches[1]
                    }
                    
                    # Check for errors
                    $hasError = $repadminOutput -match "error|failed"
                    
                    # Determine status
                    $hasIssue = ($lingeringCount -gt 0)
                    $severity = if ($lingeringCount -gt 100) { 'Critical' }
                               elseif ($lingeringCount -gt 10) { 'High' }
                               elseif ($lingeringCount -gt 0) { 'Medium' }
                               else { 'Info' }
                    
                    $result = [PSCustomObject]@{
                        DomainController = $dc.Name
                        Domain = $domain.Name
                        ReferenceServer = $pdcName
                        LingeringObjectCount = $lingeringCount
                        HasError = $hasError
                        Severity = $severity
                        Status = if ($hasError) { 'Error' }
                                elseif ($lingeringCount -gt 10) { 'Failed' }
                                elseif ($lingeringCount -gt 0) { 'Warning' }
                                else { 'Healthy' }
                        IsHealthy = -not $hasIssue
                        HasIssue = $hasIssue
                        Message = if ($hasError) {
                            "Error checking for lingering objects"
                        }
                        elseif ($lingeringCount -gt 100) {
                            "CRITICAL: $lingeringCount lingering objects detected! Database corruption risk!"
                        }
                        elseif ($lingeringCount -gt 10) {
                            "WARNING: $lingeringCount lingering objects detected - cleanup needed"
                        }
                        elseif ($lingeringCount -gt 0) {
                            "$lingeringCount lingering objects detected"
                        }
                        else {
                            "No lingering objects detected"
                        }
                    }
                    
                    $results += $result
                }
                catch {
                    Write-Warning "[REP-009] Failed to check $($dc.Name): $_"
                    
                    $results += [PSCustomObject]@{
                        DomainController = $dc.Name
                        Domain = $domain.Name
                        ReferenceServer = $pdcName
                        LingeringObjectCount = 0
                        HasError = $true
                        Severity = 'Error'
                        Status = 'Error'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = "Failed to check lingering objects: $_"
                    }
                }
            }
        }
        catch {
            Write-Warning "[REP-009] Failed to process domain $($domain.Name): $_"
        }
    }
    
    Write-Verbose "[REP-009] Check complete. Results: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[REP-009] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        Domain = "Unknown"
        ReferenceServer = "Unknown"
        LingeringObjectCount = 0
        HasError = $true
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
