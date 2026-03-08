<#
.SYNOPSIS
    Metadata Consistency Check (REP-008)

.DESCRIPTION
    Validates Active Directory metadata consistency.
    Detects phantom DCs and stale metadata that should be cleaned up.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: REP-008
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

Write-Verbose "[REP-008] Starting metadata consistency check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[REP-008] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[REP-008] Checking metadata for domain: $($domain.Name)"
        
        try {
            # Get all DC computer objects from AD
            $dcComputers = Get-ADComputer -Filter {PrimaryGroupID -eq 516} `
                -Server $domain.Name -ErrorAction Stop
            
            # Get all DC server objects
            $dcServers = Get-ADObject -Filter {objectClass -eq 'server'} `
                -SearchBase "CN=Sites,CN=Configuration,$((Get-ADDomain -Server $domain.Name).DistinguishedName)" `
                -Server $domain.Name -ErrorAction Stop
            
            # Get reachable DCs from inventory
            $reachableDCs = $Inventory.DomainControllers | 
                Where-Object { $_.Domain -eq $domain.Name -and $_.IsReachable } |
                ForEach-Object { $_.Name }
            
            # Find phantom DCs (in metadata but not reachable)
            $phantomDCs = @()
            
            foreach ($dcServer in $dcServers) {
                $serverName = $dcServer.Name
                
                # Check if this DC is reachable
                $isReachable = $reachableDCs -contains $serverName
                
                # Check if computer object exists
                $computerExists = $dcComputers | Where-Object { $_.Name -eq $serverName }
                
                if (-not $isReachable -and $computerExists) {
                    # Potential phantom - in metadata but not responding
                    $phantomDCs += $serverName
                }
            }
            
            # Check for orphaned NTDS Settings objects
            $ntdsSettings = Get-ADObject -Filter {objectClass -eq 'nTDSDSA'} `
                -SearchBase "CN=Sites,CN=Configuration,$((Get-ADDomain -Server $domain.Name).DistinguishedName)" `
                -Server $domain.Name -ErrorAction Stop
            
            $orphanedNTDS = @()
            
            foreach ($ntds in $ntdsSettings) {
                # Extract server name from DN
                if ($ntds.DistinguishedName -match "CN=NTDS Settings,CN=([^,]+)") {
                    $serverName = $matches[1]
                    
                    # Check if server exists
                    $serverExists = $dcServers | Where-Object { $_.Name -eq $serverName }
                    
                    if (-not $serverExists) {
                        $orphanedNTDS += $serverName
                    }
                }
            }
            
            # Determine status
            $totalIssues = $phantomDCs.Count + $orphanedNTDS.Count
            $hasIssue = $totalIssues -gt 0
            $severity = if ($totalIssues -gt 5) { 'Critical' }
                       elseif ($totalIssues -gt 0) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                Domain = $domain.Name
                TotalDCServers = $dcServers.Count
                ReachableDCs = $reachableDCs.Count
                PhantomDCs = $phantomDCs.Count
                PhantomDCList = if ($phantomDCs.Count -gt 0) { ($phantomDCs -join ", ") } else { "None" }
                OrphanedNTDS = $orphanedNTDS.Count
                OrphanedNTDSList = if ($orphanedNTDS.Count -gt 0) { ($orphanedNTDS -join ", ") } else { "None" }
                TotalIssues = $totalIssues
                Severity = $severity
                Status = if ($totalIssues -gt 5) { 'Failed' }
                        elseif ($totalIssues -gt 0) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($totalIssues -gt 0) {
                    "Metadata cleanup needed: $($phantomDCs.Count) phantom DCs, $($orphanedNTDS.Count) orphaned NTDS objects"
                }
                else {
                    "Metadata consistency healthy - no cleanup needed"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[REP-008] Failed to check metadata for $($domain.Name): $_"
            
            $results += [PSCustomObject]@{
                Domain = $domain.Name
                TotalDCServers = 0
                ReachableDCs = 0
                PhantomDCs = 0
                PhantomDCList = "Unknown"
                OrphanedNTDS = 0
                OrphanedNTDSList = "Unknown"
                TotalIssues = 0
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query metadata: $_"
            }
        }
    }
    
    Write-Verbose "[REP-008] Check complete. Domains checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[REP-008] Check failed: $_"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        TotalDCServers = 0
        ReachableDCs = 0
        PhantomDCs = 0
        PhantomDCList = "Unknown"
        OrphanedNTDS = 0
        OrphanedNTDSList = "Unknown"
        TotalIssues = 0
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
