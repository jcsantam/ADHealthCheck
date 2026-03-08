<#
.SYNOPSIS
    SID Filtering Status Check (TRUST-002)

.DESCRIPTION
    Validates SID filtering configuration on trust relationships.
    Ensures security is maintained on external trusts.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: TRUST-002
    Category: Operational
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

Write-Verbose "[TRUST-002] Starting SID filtering status check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[TRUST-002] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[TRUST-002] Checking SID filtering for domain: $($domain.Name)"
        
        try {
            # Get all trusts
            $trusts = Get-ADTrust -Filter * -Server $domain.Name -ErrorAction Stop
            
            if (-not $trusts -or $trusts.Count -eq 0) {
                Write-Verbose "[TRUST-002] No trusts found for $($domain.Name)"
                continue
            }
            
            foreach ($trust in $trusts) {
                Write-Verbose "[TRUST-002] Checking SID filtering: $($trust.Name)"
                
                try {
                    # Get SID filtering status
                    $sidFilteringEnabled = $trust.SIDFilteringQuarantined
                    $trustType = $trust.TrustType
                    $trustDirection = $trust.Direction
                    
                    # Analyze based on trust type
                    $expectedSIDFiltering = $false
                    $recommendation = ""
                    
                    if ($trustType -eq 'External' -or $trustType -eq 'Forest') {
                        $expectedSIDFiltering = $true
                        $recommendation = "SID filtering should be enabled for external/forest trusts"
                    }
                    elseif ($trustType -eq 'TreeRoot' -or $trustType -eq 'ParentChild') {
                        $expectedSIDFiltering = $false
                        $recommendation = "SID filtering typically disabled for intra-forest trusts"
                    }
                    
                    # Determine if configuration is appropriate
                    $isAppropriate = ($sidFilteringEnabled -eq $expectedSIDFiltering)
                    
                    # Determine status
                    $hasIssue = -not $isAppropriate
                    $severity = if ($trustType -match 'External|Forest' -and -not $sidFilteringEnabled) { 'High' }
                               elseif (-not $isAppropriate) { 'Medium' }
                               else { 'Info' }
                    
                    $result = [PSCustomObject]@{
                        SourceDomain = $domain.Name
                        TargetDomain = $trust.Name
                        TrustType = $trustType
                        TrustDirection = $trustDirection
                        SIDFilteringEnabled = $sidFilteringEnabled
                        ExpectedSIDFiltering = $expectedSIDFiltering
                        IsAppropriate = $isAppropriate
                        Recommendation = $recommendation
                        Severity = $severity
                        Status = if ($trustType -match 'External|Forest' -and -not $sidFilteringEnabled) { 'Failed' }
                                elseif (-not $isAppropriate) { 'Warning' }
                                else { 'Healthy' }
                        IsHealthy = -not $hasIssue
                        HasIssue = $hasIssue
                        Message = if ($trustType -match 'External|Forest' -and -not $sidFilteringEnabled) {
                            "WARNING: SID filtering disabled on external/forest trust (security risk!)"
                        }
                        elseif (-not $isAppropriate) {
                            "SID filtering configuration may not be optimal for $trustType trust"
                        }
                        else {
                            "SID filtering appropriately configured for $trustType trust"
                        }
                    }
                    
                    $results += $result
                }
                catch {
                    Write-Warning "[TRUST-002] Could not check SID filtering for $($trust.Name): $_"
                }
            }
        }
        catch {
            Write-Warning "[TRUST-002] Failed to check SID filtering for $($domain.Name): $_"
        }
    }
    
    Write-Verbose "[TRUST-002] Check complete. Trusts checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[TRUST-002] Check failed: $_"
    
    return @([PSCustomObject]@{
        SourceDomain = "Unknown"
        TargetDomain = "Unknown"
        TrustType = "Unknown"
        TrustDirection = "Unknown"
        SIDFilteringEnabled = $null
        ExpectedSIDFiltering = $null
        IsAppropriate = $false
        Recommendation = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
