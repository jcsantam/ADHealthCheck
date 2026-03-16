<#
.SYNOPSIS
    WMI Filter Validation (GPO-005)
.DESCRIPTION
    Checks for GPOs with WMI filters and validates filter syntax. Identifies
    orphaned WMI filters (not linked to any GPO) which are cleanup candidates.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: GPO-005
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

Write-Verbose "[GPO-005] Starting WMI filter validation..."

try {
    $domains = $Inventory.Domains
    if (-not $domains) {
        Write-Warning "[GPO-005] No domains found"
        return @()
    }

    foreach ($domain in $domains) {
        Write-Verbose "[GPO-005] Checking WMI filters in domain: $($domain.Name)"

        $domainDN = 'DC=' + ($domain.Name -replace '\.', ',DC=')

        $wmiFilters        = @()
        $orphanedFilters   = @()
        $invalidFilters    = @()

        # Search common WMI filter locations
        $wmiSearchBases = @(
            "CN=SOM,CN=WMIPolicy,CN=System,$domainDN",
            "CN=Microsoft,CN=Program Data,$domainDN"
        )

        foreach ($searchBase in $wmiSearchBases) {
            try {
                $found = @(Get-ADObject -Filter { objectClass -eq 'msWMI-Som' } `
                    -SearchBase $searchBase `
                    -Properties 'msWMI-Parm1', 'msWMI-Parm2', 'msWMI-Name' `
                    -Server $domain.Name -ErrorAction Stop)
                $wmiFilters += $found
            }
            catch {
                # Search base may not exist in all domains - continue silently
                Write-Verbose "[GPO-005] Search base not found or inaccessible: $searchBase"
            }
        }

        $totalWMIFilters = @($wmiFilters).Count
        Write-Verbose "[GPO-005] Found $totalWMIFilters WMI filter(s) in $($domain.Name)"

        # Get all GPOs to check which ones use WMI filters
        $gposWithWMIFilters = 0
        $usedFilterGuids    = @{}

        try {
            # GPO objects have gPCWQLFilter attribute linking to WMI filter GUID
            $gpoObjects = @(Get-ADObject -Filter { objectClass -eq 'groupPolicyContainer' } `
                -SearchBase "CN=Policies,CN=System,$domainDN" `
                -Properties gPCWQLFilter `
                -Server $domain.Name -ErrorAction Stop)

            foreach ($gpo in $gpoObjects) {
                if ($gpo.gPCWQLFilter) {
                    $gposWithWMIFilters++
                    # Extract GUID from the filter reference: [Domain;{GUID};0;0]
                    if ($gpo.gPCWQLFilter -match '\{([0-9A-Fa-f\-]+)\}') {
                        $usedFilterGuids[$matches[1].ToLower()] = $true
                    }
                }
            }
        }
        catch {
            Write-Warning "[GPO-005] Failed to query GPO objects in $($domain.Name): $_"
        }

        # Identify orphaned WMI filters (not referenced by any GPO)
        foreach ($filter in $wmiFilters) {
            # Extract GUID from the filter's CN
            $filterGuid = ''
            if ($filter.Name -match '\{([0-9A-Fa-f\-]+)\}') {
                $filterGuid = $matches[1].ToLower()
            } elseif ($filter.DistinguishedName -match 'CN=\{([0-9A-Fa-f\-]+)\}') {
                $filterGuid = $matches[1].ToLower()
            }

            if ($filterGuid -and -not $usedFilterGuids.ContainsKey($filterGuid)) {
                $orphanedFilters += $filter
            }

            # Basic WQL syntax validation: must contain SELECT and FROM
            $wql = $filter.'msWMI-Parm2'
            if ($wql) {
                if ($wql -notmatch '\bSELECT\b' -or $wql -notmatch '\bFROM\b') {
                    $invalidFilters += $filter
                }
            }
        }

        $orphanedCount = @($orphanedFilters).Count
        $invalidCount  = @($invalidFilters).Count
        $hasIssue      = $orphanedCount -gt 0 -or $invalidCount -gt 0

        $results += [PSCustomObject]@{
            Domain              = $domain.Name
            TotalWMIFilters     = $totalWMIFilters
            OrphanedWMIFilters  = $orphanedCount
            InvalidWMIFilters   = $invalidCount
            GPOsWithWMIFilters  = $gposWithWMIFilters
            IsHealthy           = -not $hasIssue
            HasIssue            = $hasIssue
            Status              = if ($hasIssue) { 'Warning' } else { 'Healthy' }
            Severity            = if ($hasIssue) { 'Low' } else { 'Info' }
            Message             = if ($invalidCount -gt 0) {
                "WARNING: $invalidCount invalid WMI filter(s) and $orphanedCount orphaned WMI filter(s) in $($domain.Name)"
            } elseif ($orphanedCount -gt 0) {
                "WARNING: $orphanedCount orphaned WMI filter(s) found in $($domain.Name) (not linked to any GPO)"
            } else {
                "$($domain.Name): $totalWMIFilters WMI filter(s) found, $gposWithWMIFilters GPO(s) use WMI filters - all healthy"
            }
        }
    }

    Write-Verbose "[GPO-005] Check complete. Domains checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[GPO-005] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain             = 'Unknown'
        TotalWMIFilters    = 0
        OrphanedWMIFilters = 0
        InvalidWMIFilters  = 0
        GPOsWithWMIFilters = 0
        IsHealthy          = $false
        HasIssue           = $true
        Status             = 'Error'
        Severity           = 'Error'
        Message            = "Check execution failed: $($_.Exception.Message)"
    })
}
