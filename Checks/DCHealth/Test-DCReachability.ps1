<#
.SYNOPSIS
    Test check - DC Reachability

.DESCRIPTION
    Simple test check that validates domain controller reachability.
    Tests ping and DNS resolution for each DC discovered.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-DCReachability.ps1 -Inventory $inventory

.NOTES
    Check ID: TEST-001
    Category: DCHealth
    This is a test check to validate the execution framework
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

# =============================================================================
# TEST CHECK: DC REACHABILITY
# =============================================================================

$results = @()

Write-Verbose "Testing reachability for $($Inventory.DomainControllers.Count) domain controllers..."

foreach ($dc in $Inventory.DomainControllers) {
    Write-Verbose "  Testing: $($dc.Name)"
    
    $result = [PSCustomObject]@{
        DomainController = $dc.Name
        IPAddress = $dc.IPAddress
        Site = $dc.SiteName
        PingSuccess = $dc.IsReachable
        ResponseTimeMs = $dc.ResponseTimeMs
        IsGlobalCatalog = $dc.IsGlobalCatalog
        Status = if ($dc.IsReachable) { 'Healthy' } else { 'Failed' }
        IsHealthy = $dc.IsReachable
        Message = if ($dc.IsReachable) { 
            "DC is reachable (${$dc.ResponseTimeMs}ms)" 
        } else { 
            "DC is NOT reachable" 
        }
    }
    
    $results += $result
}

# Return results
return $results
