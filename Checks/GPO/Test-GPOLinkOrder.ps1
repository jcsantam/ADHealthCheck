<#
.SYNOPSIS
    GPO Link Order Analysis (GPO-010)
.DESCRIPTION
    Scans all containers with gpLink attributes and flags two conditions:
    1. Duplicate GPO links - the same GPO linked more than once to the same container.
    2. Excessive GPO links - containers with more than 20 GPO links (performance concern).
    Both conditions indicate GPO management issues that should be remediated.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: GPO-010
    Category: GPO
    Severity: Medium (duplicates), Low (excessive)
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[GPO-010] Starting GPO link order analysis..."

try {
    $domains = $Inventory.Domains
    if (-not $domains) {
        Write-Warning "[GPO-010] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        Write-Verbose "[GPO-010] Analysing GPO link order in domain: $($domain.Name)"

        $domainDN   = 'DC=' + ($domain.Name -replace '\.', ',DC=')
        $foundIssue = $false

        # Collect all objects with gpLink attribute
        $linkedObjects = @()

        try {
            $subtreeObjects = @(Get-ADObject -Filter { gpLink -like '*' } `
                -SearchBase $domainDN `
                -SearchScope Subtree `
                -Properties gpLink, DistinguishedName `
                -Server $domain.Name -ErrorAction Stop)
            $linkedObjects += $subtreeObjects
        }
        catch {
            Write-Warning "[GPO-010] Failed to query linked objects in $($domain.Name): $_"
            $results += [PSCustomObject]@{
                Domain       = $domain.Name
                Container    = 'N/A'
                GPOGUID      = 'N/A'
                LinkCount    = 0
                IsDuplicate  = $false
                IsHealthy    = $false
                HasIssue     = $true
                Status       = 'Error'
                Severity     = 'Error'
                Message      = "Failed to query GPO links in $($domain.Name): $($_.Exception.Message)"
            }
            continue
        }

        # Also query domain root
        try {
            $domainRoot = Get-ADObject -Identity $domainDN -Properties gpLink -Server $domain.Name -ErrorAction Stop
            if ($domainRoot -and $domainRoot.gpLink) {
                $alreadyFound = $false
                foreach ($obj in $linkedObjects) {
                    if ($obj.DistinguishedName -eq $domainDN) {
                        $alreadyFound = $true
                        break
                    }
                }
                if (-not $alreadyFound) {
                    $linkedObjects += $domainRoot
                }
            }
        }
        catch {
            Write-Verbose "[GPO-010] Could not query domain root gpLink in $($domain.Name): $_"
        }

        Write-Verbose "[GPO-010] Found $($linkedObjects.Count) container(s) with gpLink in $($domain.Name)"

        $guidPattern = '\{([0-9A-Fa-f-]+)\}'

        foreach ($obj in $linkedObjects) {
            $gpLinkValue = $obj.gpLink
            if (-not $gpLinkValue) { continue }

            $containerDN = $obj.DistinguishedName

            # Extract all GUIDs from gpLink for this container
            $guidMatches = [regex]::Matches($gpLinkValue, $guidPattern)
            $allGuids    = @()
            foreach ($gm in $guidMatches) {
                $allGuids += $gm.Groups[1].Value.ToUpper()
            }

            $totalLinks = $allGuids.Count

            # Check for excessive link count (> 20)
            if ($totalLinks -gt 20) {
                $foundIssue = $true
                $results += [PSCustomObject]@{
                    Domain       = $domain.Name
                    Container    = $containerDN
                    GPOGUID      = 'N/A'
                    LinkCount    = $totalLinks
                    IsDuplicate  = $false
                    IsHealthy    = $false
                    HasIssue     = $true
                    Status       = 'Warning'
                    Severity     = 'Low'
                    Message      = "Container has $totalLinks GPO links (>20) in $($domain.Name): $containerDN - this may impact logon/startup performance"
                }
            }

            # Build a count table per GUID to detect duplicates
            $guidCounts = @{}
            foreach ($guid in $allGuids) {
                if ($guidCounts.ContainsKey($guid)) {
                    $guidCounts[$guid]++
                } else {
                    $guidCounts[$guid] = 1
                }
            }

            foreach ($guid in $guidCounts.Keys) {
                $count = $guidCounts[$guid]
                if ($count -gt 1) {
                    $foundIssue = $true
                    $results += [PSCustomObject]@{
                        Domain       = $domain.Name
                        Container    = $containerDN
                        GPOGUID      = $guid
                        LinkCount    = $count
                        IsDuplicate  = $true
                        IsHealthy    = $false
                        HasIssue     = $true
                        Status       = 'Warning'
                        Severity     = 'Medium'
                        Message      = "Duplicate GPO link detected in $($domain.Name) - GPO $guid is linked $count times to: $containerDN"
                    }
                }
            }
        }

        if (-not $foundIssue) {
            $results += [PSCustomObject]@{
                Domain       = $domain.Name
                Container    = 'N/A'
                GPOGUID      = 'N/A'
                LinkCount    = 0
                IsDuplicate  = $false
                IsHealthy    = $true
                HasIssue     = $false
                Status       = 'Pass'
                Severity     = 'Info'
                Message      = "$($domain.Name): No duplicate or excessive GPO links detected ($($linkedObjects.Count) container(s) checked)"
            }
        }
    }

    Write-Verbose "[GPO-010] Check complete. Results: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[GPO-010] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain       = 'Unknown'
        Container    = 'N/A'
        GPOGUID      = 'N/A'
        LinkCount    = 0
        IsDuplicate  = $false
        IsHealthy    = $false
        HasIssue     = $true
        Status       = 'Error'
        Severity     = 'Error'
        Message      = "Check execution failed: $($_.Exception.Message)"
    })
}
