<#
.SYNOPSIS
    Disabled GPO Link Detection (GPO-008)
.DESCRIPTION
    Scans all containers (OUs, domain root, sites) with gpLink attributes and
    identifies GPO links that have been disabled (link option 1 or 3).
    Disabled links waste processing overhead and are typically cleanup candidates.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: GPO-008
    Category: GPO
    Severity: Low
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[GPO-008] Starting disabled GPO link detection..."

try {
    $domains = $Inventory.Domains
    if (-not $domains) {
        Write-Warning "[GPO-008] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        Write-Verbose "[GPO-008] Scanning GPO links in domain: $($domain.Name)"

        $domainDN    = 'DC=' + ($domain.Name -replace '\.', ',DC=')
        $foundIssue  = $false

        # Collect all objects with gpLink attribute - subtree search
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
            Write-Warning "[GPO-008] Failed to query linked objects in $($domain.Name): $_"
            $results += [PSCustomObject]@{
                Domain          = $domain.Name
                LinkedContainer = 'N/A'
                GPOGUID         = 'N/A'
                LinkOption      = $null
                IsHealthy       = $false
                HasIssue        = $true
                Status          = 'Error'
                Severity        = 'Error'
                Message         = "Failed to query GPO links in $($domain.Name): $($_.Exception.Message)"
            }
            continue
        }

        # Also query the domain root object explicitly
        try {
            $domainRoot = Get-ADObject -Identity $domainDN -Properties gpLink -Server $domain.Name -ErrorAction Stop
            if ($domainRoot -and $domainRoot.gpLink) {
                # Add if not already present from subtree search
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
            Write-Verbose "[GPO-008] Could not query domain root gpLink in $($domain.Name): $_"
        }

        Write-Verbose "[GPO-008] Found $($linkedObjects.Count) container(s) with gpLink in $($domain.Name)"

        foreach ($obj in $linkedObjects) {
            $gpLinkValue = $obj.gpLink
            if (-not $gpLinkValue) { continue }

            $containerDN = $obj.DistinguishedName

            # Parse each link entry from gpLink value
            # Format: [LDAP://CN={GUID},CN=Policies,CN=System,DC=...;N][...]
            $linkPattern = '\[LDAP://[^\]]+;(\d+)\]'
            $guidPattern = '\{([0-9A-Fa-f-]+)\}'

            $linkMatches = [regex]::Matches($gpLinkValue, $linkPattern)

            foreach ($linkMatch in $linkMatches) {
                $linkOption = [int]$linkMatch.Groups[1].Value

                # Link option 1 = link disabled, 3 = disabled + enforced
                if ($linkOption -eq 1 -or $linkOption -eq 3) {
                    # Extract GUID from the full link entry
                    $guidMatch = [regex]::Match($linkMatch.Value, $guidPattern)
                    $gpoGuid   = if ($guidMatch.Success) { $guidMatch.Groups[1].Value } else { 'Unknown' }

                    $enforced = if ($linkOption -eq 3) { ' (also enforced)' } else { '' }

                    $results += [PSCustomObject]@{
                        Domain          = $domain.Name
                        LinkedContainer = $containerDN
                        GPOGUID         = $gpoGuid
                        LinkOption      = $linkOption
                        IsHealthy       = $false
                        HasIssue        = $true
                        Status          = 'Warning'
                        Severity        = 'Low'
                        Message         = "Disabled GPO link found in $($domain.Name) - Container: $containerDN - GPO GUID: $gpoGuid - LinkOption: $linkOption$enforced"
                    }
                    $foundIssue = $true
                }
            }
        }

        if (-not $foundIssue) {
            $results += [PSCustomObject]@{
                Domain          = $domain.Name
                LinkedContainer = 'N/A'
                GPOGUID         = 'N/A'
                LinkOption      = $null
                IsHealthy       = $true
                HasIssue        = $false
                Status          = 'Pass'
                Severity        = 'Info'
                Message         = "$($domain.Name): No disabled GPO links detected"
            }
        }
    }

    Write-Verbose "[GPO-008] Check complete. Results: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[GPO-008] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain          = 'Unknown'
        LinkedContainer = 'N/A'
        GPOGUID         = 'N/A'
        LinkOption      = $null
        IsHealthy       = $false
        HasIssue        = $true
        Status          = 'Error'
        Severity        = 'Error'
        Message         = "Check execution failed: $($_.Exception.Message)"
    })
}
