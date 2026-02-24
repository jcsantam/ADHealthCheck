<#
.SYNOPSIS
    Root Hints Validation Check (DNS-004)

.DESCRIPTION
    Validates DNS root hints configuration on domain controllers.
    Ensures root server list is present and correct.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DNS-004
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

# Standard root servers (subset for validation)
$standardRootServers = @(
    'a.root-servers.net',
    'b.root-servers.net',
    'c.root-servers.net',
    'd.root-servers.net'
)

Write-Verbose "[DNS-004] Starting root hints validation check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DNS-004] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DNS-004] Checking root hints on: $($dc.Name)"
        
        try {
            # Get root hints
            $rootHints = Get-DnsServerRootHint -ComputerName $dc.HostName -ErrorAction Stop
            
            if (-not $rootHints -or $rootHints.Count -eq 0) {
                $result = [PSCustomObject]@{
                    DomainController = $dc.Name
                    RootHintsConfigured = $false
                    RootHintCount = 0
                    StandardServersPresent = 0
                    MissingServers = ($standardRootServers -join ", ")
                    Severity = 'High'
                    Status = 'Failed'
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "CRITICAL: No root hints configured!"
                }
                
                $results += $result
                continue
            }
            
            # Check for standard root servers
            $configuredServers = $rootHints | ForEach-Object { $_.NameServer.RecordData.NameServer }
            $foundStandard = 0
            $missingServers = @()
            
            foreach ($standardServer in $standardRootServers) {
                if ($configuredServers -contains $standardServer) {
                    $foundStandard++
                }
                else {
                    $missingServers += $standardServer
                }
            }
            
            # Determine status
            $hasIssue = ($foundStandard -lt $standardRootServers.Count)
            $severity = if ($foundStandard -eq 0) { 'Critical' }
                       elseif ($foundStandard -lt ($standardRootServers.Count / 2)) { 'High' }
                       elseif ($hasIssue) { 'Medium' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                RootHintsConfigured = $true
                RootHintCount = $rootHints.Count
                StandardServersPresent = $foundStandard
                MissingServers = if ($missingServers.Count -gt 0) { ($missingServers -join ", ") } else { "None" }
                Severity = $severity
                Status = if ($foundStandard -eq 0) { 'Failed' }
                        elseif ($hasIssue) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($foundStandard -eq 0) {
                    "CRITICAL: No standard root servers configured!"
                }
                elseif ($hasIssue) {
                    "WARNING: Only $foundStandard of $($standardRootServers.Count) standard root servers present"
                }
                else {
                    "All standard root servers present ($($rootHints.Count) total hints)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DNS-004] Failed to check root hints on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                RootHintsConfigured = $null
                RootHintCount = 0
                StandardServersPresent = 0
                MissingServers = "Unknown"
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query root hints: $_"
            }
        }
    }
    
    Write-Verbose "[DNS-004] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DNS-004] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        RootHintsConfigured = $null
        RootHintCount = 0
        StandardServersPresent = 0
        MissingServers = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
