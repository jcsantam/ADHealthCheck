<#
.SYNOPSIS
    Blocked GPO Inheritance Detection (GPO-009)
.DESCRIPTION
    Identifies Organizational Units that have GPO inheritance blocked (gPOptions = 1).
    Blocked inheritance can hide security policies from being applied and is often
    a sign of misconfiguration or deliberate policy bypass.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: GPO-009
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

Write-Verbose "[GPO-009] Starting blocked inheritance detection..."

try {
    $domains = $Inventory.Domains
    if (-not $domains) {
        Write-Warning "[GPO-009] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        Write-Verbose "[GPO-009] Scanning OUs for blocked inheritance in domain: $($domain.Name)"

        $domainDN   = 'DC=' + ($domain.Name -replace '\.', ',DC=')
        $foundIssue = $false

        try {
            $allOUs = @(Get-ADOrganizationalUnit -Filter * `
                -Properties gPOptions, DistinguishedName `
                -Server $domain.Name -ErrorAction Stop)
            Write-Verbose "[GPO-009] Found $($allOUs.Count) OU(s) in $($domain.Name)"
        }
        catch {
            Write-Warning "[GPO-009] Failed to enumerate OUs in $($domain.Name): $_"
            $results += [PSCustomObject]@{
                Domain                = $domain.Name
                OUDistinguishedName   = 'N/A'
                IsBlocked             = $false
                IsHealthy             = $false
                HasIssue              = $true
                Status                = 'Error'
                Severity              = 'Error'
                Message               = "Failed to enumerate OUs in $($domain.Name): $($_.Exception.Message)"
            }
            continue
        }

        foreach ($ou in $allOUs) {
            # gPOptions value 1 = block inheritance
            if ($ou.gPOptions -eq 1) {
                $foundIssue = $true
                $results += [PSCustomObject]@{
                    Domain                = $domain.Name
                    OUDistinguishedName   = $ou.DistinguishedName
                    IsBlocked             = $true
                    IsHealthy             = $false
                    HasIssue              = $true
                    Status                = 'Warning'
                    Severity              = 'Low'
                    Message               = "OU has GPO inheritance blocked in $($domain.Name): $($ou.DistinguishedName)"
                }
            }
        }

        if (-not $foundIssue) {
            $results += [PSCustomObject]@{
                Domain                = $domain.Name
                OUDistinguishedName   = 'N/A'
                IsBlocked             = $false
                IsHealthy             = $true
                HasIssue              = $false
                Status                = 'Pass'
                Severity              = 'Info'
                Message               = "$($domain.Name): No OUs with blocked GPO inheritance detected ($($allOUs.Count) OUs checked)"
            }
        }
    }

    Write-Verbose "[GPO-009] Check complete. Results: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[GPO-009] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain                = 'Unknown'
        OUDistinguishedName   = 'N/A'
        IsBlocked             = $false
        IsHealthy             = $false
        HasIssue              = $true
        Status                = 'Error'
        Severity              = 'Error'
        Message               = "Check execution failed: $($_.Exception.Message)"
    })
}
