<#
.SYNOPSIS
    Global Catalog Availability Check (DC-009)

.DESCRIPTION
    Validates Global Catalog server availability and functionality.
    Ensures GC is advertising and responding to queries.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DC-009
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

Write-Verbose "[DC-009] Starting Global Catalog availability check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DC-009] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-009] Checking GC on: $($dc.Name)"
        
        try {
            # Check if DC is configured as GC
            $dcObject = Get-ADDomainController -Identity $dc.Name -Server $dc.HostName -ErrorAction Stop
            
            $isGC = $dcObject.IsGlobalCatalog
            
            if (-not $isGC) {
                # Not a GC - this is informational, not an error
                $result = [PSCustomObject]@{
                    DomainController = $dc.Name
                    IsGlobalCatalog = $false
                    GCAdvertising = $false
                    GCResponding = $false
                    GCPort3268Open = $false
                    GCPort3269Open = $false
                    Severity = 'Info'
                    Status = 'Info'
                    IsHealthy = $true
                    HasIssue = $false
                    Message = "DC is not configured as Global Catalog"
                }
                
                $results += $result
                continue
            }
            
            # DC is configured as GC - validate functionality
            
            # Check if GC is advertising
            $gcAdvertising = $dcObject.IsGlobalCatalog
            
            # Test GC port 3268 (LDAP GC)
            $gcPort3268 = Test-NetConnection -ComputerName $dc.HostName -Port 3268 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            $port3268Open = if ($gcPort3268) { $gcPort3268.TcpTestSucceeded } else { $false }
            
            # Test GC port 3269 (LDAP GC SSL)
            $gcPort3269 = Test-NetConnection -ComputerName $dc.HostName -Port 3269 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            $port3269Open = if ($gcPort3269) { $gcPort3269.TcpTestSucceeded } else { $false }
            
            # Test GC query functionality
            $gcResponding = $false
            try {
                $searcher = New-Object DirectoryServices.DirectorySearcher
                $searcher.SearchRoot = "GC://$($dc.HostName)"
                $searcher.Filter = "(objectClass=*)"
                $searcher.PropertiesToLoad.Add("cn") | Out-Null
                $searcher.PageSize = 1
                $searcher.SizeLimit = 1
                
                $gcResults = $searcher.FindAll()
                $gcResponding = ($gcResults.Count -gt 0)
                $gcResults.Dispose()
                $searcher.Dispose()
            }
            catch {
                $gcResponding = $false
            }
            
            # Determine status
            $hasIssue = (-not $port3268Open -or -not $gcResponding)
            $severity = if (-not $gcResponding) { 'Critical' }
                       elseif (-not $port3268Open) { 'High' }
                       elseif (-not $port3269Open) { 'Medium' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                IsGlobalCatalog = $isGC
                GCAdvertising = $gcAdvertising
                GCResponding = $gcResponding
                GCPort3268Open = $port3268Open
                GCPort3269Open = $port3269Open
                Severity = $severity
                Status = if (-not $gcResponding) { 'Failed' }
                        elseif (-not $port3268Open) { 'Failed' }
                        elseif (-not $port3269Open) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if (-not $gcResponding) {
                    "CRITICAL: GC not responding to queries!"
                }
                elseif (-not $port3268Open) {
                    "CRITICAL: GC port 3268 not accessible!"
                }
                elseif (-not $port3269Open) {
                    "WARNING: GC SSL port 3269 not accessible"
                }
                else {
                    "Global Catalog healthy and responding"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DC-009] Failed to check GC on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                IsGlobalCatalog = $null
                GCAdvertising = $false
                GCResponding = $false
                GCPort3268Open = $false
                GCPort3269Open = $false
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query GC: $_"
            }
        }
    }
    
    # Summary: Check if any GC is available
    $gcServers = ($results | Where-Object { $_.IsGlobalCatalog -and $_.GCResponding }).Count
    
    if ($gcServers -eq 0 -and $results.Count -gt 0) {
        Write-Warning "[DC-009] CRITICAL: No responding Global Catalog servers found!"
    }
    
    Write-Verbose "[DC-009] Check complete. DCs checked: $($results.Count), GC servers: $gcServers"
    
    return $results
}
catch {
    Write-Error "[DC-009] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        IsGlobalCatalog = $null
        GCAdvertising = $false
        GCResponding = $false
        GCPort3268Open = $false
        GCPort3269Open = $false
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
