<#
.SYNOPSIS
    Cross-Domain GPO Link Detection (GPO-011)
.DESCRIPTION
    In multi-domain forests, identifies GPO links in a domain that reference GPO GUIDs
    not present in that domain's own CN=Policies,CN=System container.
    Cross-domain GPO links are unsupported and will fail to apply correctly.
    Single-domain forests are automatically skipped with a Pass result.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: GPO-011
    Category: GPO
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

Write-Verbose "[GPO-011] Starting cross-domain GPO link detection..."

try {
    $domains = $Inventory.Domains
    if (-not $domains) {
        Write-Warning "[GPO-011] No domains found in inventory"
        return @()
    }

    # Single-domain forest - check is not applicable
    if (@($domains).Count -le 1) {
        Write-Verbose "[GPO-011] Single-domain forest detected - check not applicable"
        return @([PSCustomObject]@{
            Domain         = if ($domains) { $domains[0].Name } else { 'N/A' }
            Container      = 'N/A'
            ForeignGPOGUID = 'N/A'
            IsHealthy      = $true
            HasIssue       = $false
            Status         = 'Pass'
            Severity       = 'Info'
            Message        = 'Single-domain forest - cross-domain GPO link check not applicable'
        })
    }

    foreach ($domain in $domains) {
        Write-Verbose "[GPO-011] Checking for cross-domain GPO links in domain: $($domain.Name)"

        $domainDN   = 'DC=' + ($domain.Name -replace '\.', ',DC=')
        $foundIssue = $false

        # Build the set of GPO GUIDs that belong to this domain
        $localGPOGuids = @{}

        try {
            $localGPOs = @(Get-ADObject -Filter { objectClass -eq 'groupPolicyContainer' } `
                -SearchBase "CN=Policies,CN=System,$domainDN" `
                -Server $domain.Name -ErrorAction Stop)

            foreach ($gpo in $localGPOs) {
                # GPO object Name is the GUID in {GUID} format
                $guidMatch = [regex]::Match($gpo.Name, '\{([0-9A-Fa-f-]+)\}')
                if ($guidMatch.Success) {
                    $localGPOGuids[$guidMatch.Groups[1].Value.ToUpper()] = $true
                }
            }
            Write-Verbose "[GPO-011] Found $($localGPOGuids.Count) local GPO(s) in $($domain.Name)"
        }
        catch {
            Write-Warning "[GPO-011] Failed to enumerate local GPOs in $($domain.Name): $_"
            $results += [PSCustomObject]@{
                Domain         = $domain.Name
                Container      = 'N/A'
                ForeignGPOGUID = 'N/A'
                IsHealthy      = $false
                HasIssue       = $true
                Status         = 'Error'
                Severity       = 'Error'
                Message        = "Failed to enumerate local GPOs in $($domain.Name): $($_.Exception.Message)"
            }
            continue
        }

        # Collect all objects with gpLink attribute in this domain
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
            Write-Warning "[GPO-011] Failed to query linked objects in $($domain.Name): $_"
            $results += [PSCustomObject]@{
                Domain         = $domain.Name
                Container      = 'N/A'
                ForeignGPOGUID = 'N/A'
                IsHealthy      = $false
                HasIssue       = $true
                Status         = 'Error'
                Severity       = 'Error'
                Message        = "Failed to query GPO links in $($domain.Name): $($_.Exception.Message)"
            }
            continue
        }

        # Also check domain root
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
            Write-Verbose "[GPO-011] Could not query domain root gpLink in $($domain.Name): $_"
        }

        Write-Verbose "[GPO-011] Found $($linkedObjects.Count) container(s) with gpLink in $($domain.Name)"

        $guidPattern = '\{([0-9A-Fa-f-]+)\}'

        foreach ($obj in $linkedObjects) {
            $gpLinkValue = $obj.gpLink
            if (-not $gpLinkValue) { continue }

            $containerDN = $obj.DistinguishedName

            # Extract all GUIDs from this container's gpLink
            $guidMatches = [regex]::Matches($gpLinkValue, $guidPattern)

            foreach ($gm in $guidMatches) {
                $linkedGuid = $gm.Groups[1].Value.ToUpper()

                # If this GUID is not in the local domain's GPO set, it is foreign
                if (-not $localGPOGuids.ContainsKey($linkedGuid)) {
                    $foundIssue = $true
                    $results += [PSCustomObject]@{
                        Domain         = $domain.Name
                        Container      = $containerDN
                        ForeignGPOGUID = $linkedGuid
                        IsHealthy      = $false
                        HasIssue       = $true
                        Status         = 'Warning'
                        Severity       = 'Medium'
                        Message        = "Cross-domain GPO link detected in $($domain.Name) - GPO $linkedGuid does not belong to this domain - Container: $containerDN"
                    }
                }
            }
        }

        if (-not $foundIssue) {
            $results += [PSCustomObject]@{
                Domain         = $domain.Name
                Container      = 'N/A'
                ForeignGPOGUID = 'N/A'
                IsHealthy      = $true
                HasIssue       = $false
                Status         = 'Pass'
                Severity       = 'Info'
                Message        = "$($domain.Name): No cross-domain GPO links detected ($($linkedObjects.Count) container(s) checked)"
            }
        }
    }

    Write-Verbose "[GPO-011] Check complete. Results: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[GPO-011] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain         = 'Unknown'
        Container      = 'N/A'
        ForeignGPOGUID = 'N/A'
        IsHealthy      = $false
        HasIssue       = $true
        Status         = 'Error'
        Severity       = 'Error'
        Message        = "Check execution failed: $($_.Exception.Message)"
    })
}
