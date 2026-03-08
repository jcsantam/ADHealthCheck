<#
.SYNOPSIS
    Trust Validation Check (TRUST-001)

.DESCRIPTION
    Validates trust relationships between domains and forests.
    Tests trust connectivity and reports broken trusts.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: TRUST-001
    Category: Operational
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

Write-Verbose "[TRUST-001] Starting trust validation check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[TRUST-001] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[TRUST-001] Checking trusts for domain: $($domain.Name)"
        
        try {
            # Get all trusts
            $trusts = Get-ADTrust -Filter * -Server $domain.Name -ErrorAction Stop
            
            if (-not $trusts -or $trusts.Count -eq 0) {
                Write-Verbose "[TRUST-001] No trusts found for $($domain.Name)"
                continue
            }
            
            foreach ($trust in $trusts) {
                Write-Verbose "[TRUST-001] Validating trust: $($trust.Name)"
                
                try {
                    # Test trust connectivity
                    $trustTest = Test-ComputerSecureChannel -Server $trust.Name -ErrorAction SilentlyContinue
                    
                    # Get trust properties
                    $trustDirection = $trust.Direction
                    $trustType = $trust.TrustType
                    $selectiveAuth = $trust.SelectiveAuthentication
                    
                    # Determine status
                    $hasIssue = -not $trustTest
                    $severity = if (-not $trustTest) { 'Critical' } else { 'Info' }
                    
                    $result = [PSCustomObject]@{
                        SourceDomain = $domain.Name
                        TargetDomain = $trust.Name
                        TrustDirection = $trustDirection
                        TrustType = $trustType
                        SelectiveAuth = $selectiveAuth
                        TrustWorking = $trustTest
                        Severity = $severity
                        Status = if ($trustTest) { 'Healthy' } else { 'Failed' }
                        IsHealthy = -not $hasIssue
                        HasIssue = $hasIssue
                        Message = if ($trustTest) {
                            "Trust operational ($trustDirection, $trustType)"
                        }
                        else {
                            "CRITICAL: Trust to $($trust.Name) is broken!"
                        }
                    }
                    
                    $results += $result
                }
                catch {
                    Write-Warning "[TRUST-001] Could not test trust $($trust.Name): $_"
                    
                    $results += [PSCustomObject]@{
                        SourceDomain = $domain.Name
                        TargetDomain = $trust.Name
                        TrustDirection = $trust.Direction
                        TrustType = $trust.TrustType
                        SelectiveAuth = $trust.SelectiveAuthentication
                        TrustWorking = $false
                        Severity = 'Error'
                        Status = 'Error'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = "Could not test trust: $_"
                    }
                }
            }
        }
        catch {
            Write-Warning "[TRUST-001] Failed to check trusts for $($domain.Name): $_"
        }
    }
    
    Write-Verbose "[TRUST-001] Check complete. Trusts checked: $($results.Count)"
    
    # Summary
    $brokenTrusts = ($results | Where-Object { -not $_.TrustWorking }).Count
    if ($brokenTrusts -gt 0) {
        Write-Warning "[TRUST-001] WARNING: $brokenTrusts broken trust(s) detected!"
    }
    
    return $results
}
catch {
    Write-Error "[TRUST-001] Check failed: $_"
    
    return @([PSCustomObject]@{
        SourceDomain = "Unknown"
        TargetDomain = "Unknown"
        TrustDirection = "Unknown"
        TrustType = "Unknown"
        SelectiveAuth = $null
        TrustWorking = $false
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
