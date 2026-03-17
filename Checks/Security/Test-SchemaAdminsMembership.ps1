<#
.SYNOPSIS
    Schema Admins Membership Check (SEC-016)

.DESCRIPTION
    Verifies that the Schema Admins group contains only expected members.
    Schema Admins have the ability to modify the Active Directory schema,
    which is an irreversible forest-wide operation. Best practice is to
    keep Schema Admins empty (or contain only the built-in Administrator)
    except when actively performing schema upgrades.

    Checks:
    - Schema Admins group membership count
    - Flags any non-built-in-Administrator members as suspicious
    - Alerts when Schema Admins has more than 1 member

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-SchemaAdminsMembership.ps1 -Inventory $inventory

.OUTPUTS
    Array of Schema Admins membership results

.NOTES
    Check ID: SEC-016
    Category: Security
    Severity: Critical
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
Import-Module ActiveDirectory -ErrorAction SilentlyContinue
$results = @()

Write-Verbose "[SEC-016] Starting Schema Admins membership check..."

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[SEC-016] No domains found in inventory"
        return @()
    }

    # Schema Admins exists only in the forest root domain
    $forestRoot = $null
    if ($Inventory.ForestInfo -and $Inventory.ForestInfo.RootDomain) {
        $forestRoot = $Inventory.ForestInfo.RootDomain
    }
    else {
        # Fall back to first domain
        $forestRoot = $domains[0].Name
    }

    Write-Verbose "[SEC-016] Forest root domain: $forestRoot"

    $forestRootDN = 'DC=' + ($forestRoot -replace '\.', ',DC=')

    try {
        $schemaAdminsGroup = Get-ADGroup -Identity "CN=Schema Admins,CN=Users,$forestRootDN" `
            -Server $forestRoot `
            -Properties Members `
            -ErrorAction SilentlyContinue

        if (-not $schemaAdminsGroup) {
            $results += [PSCustomObject]@{
                Domain       = $forestRoot
                MemberName   = 'N/A'
                MemberType   = 'N/A'
                IsBuiltIn    = $false
                MemberCount  = 0
                HasIssue     = $true
                Status       = 'Error'
                Severity     = 'Error'
                IsHealthy    = $false
                Message      = "Schema Admins group not found in forest root $forestRoot"
            }
            return $results
        }

        $members = @(Get-ADGroupMember -Identity $schemaAdminsGroup `
            -Server $forestRoot `
            -ErrorAction SilentlyContinue)

        $memberCount = $members.Count
        Write-Verbose "[SEC-016] Schema Admins has $memberCount members in $forestRoot"

        if ($memberCount -eq 0) {
            $results += [PSCustomObject]@{
                Domain       = $forestRoot
                MemberName   = 'Empty'
                MemberType   = 'N/A'
                IsBuiltIn    = $true
                MemberCount  = 0
                HasIssue     = $false
                Status       = 'Pass'
                Severity     = 'Info'
                IsHealthy    = $true
                Message      = "Schema Admins group is empty in $forestRoot - recommended configuration"
            }
            return $results
        }

        foreach ($member in $members) {
            # Built-in Administrator is acceptable
            $isBuiltIn = ($member.SamAccountName -eq 'Administrator' -or
                          $member.SamAccountName -eq 'administrator')

            if ($memberCount -eq 1 -and $isBuiltIn) {
                $results += [PSCustomObject]@{
                    Domain       = $forestRoot
                    MemberName   = $member.SamAccountName
                    MemberType   = $member.objectClass
                    IsBuiltIn    = $true
                    MemberCount  = $memberCount
                    HasIssue     = $false
                    Status       = 'Pass'
                    Severity     = 'Info'
                    IsHealthy    = $true
                    Message      = "Schema Admins contains only the built-in Administrator in $forestRoot - acceptable configuration"
                }
            }
            elseif (-not $isBuiltIn) {
                $results += [PSCustomObject]@{
                    Domain       = $forestRoot
                    MemberName   = $member.SamAccountName
                    MemberType   = $member.objectClass
                    IsBuiltIn    = $false
                    MemberCount  = $memberCount
                    HasIssue     = $true
                    Status       = 'Fail'
                    Severity     = 'Critical'
                    IsHealthy    = $false
                    Message      = "Schema Admins contains non-standard member '$($member.SamAccountName)' ($($member.objectClass)) in $forestRoot - Schema Admins should be empty when not performing schema changes"
                }
            }
            else {
                # Built-in admin but there are additional members - flag as warning
                $results += [PSCustomObject]@{
                    Domain       = $forestRoot
                    MemberName   = $member.SamAccountName
                    MemberType   = $member.objectClass
                    IsBuiltIn    = $true
                    MemberCount  = $memberCount
                    HasIssue     = $true
                    Status       = 'Warning'
                    Severity     = 'High'
                    IsHealthy    = $false
                    Message      = "Schema Admins has $memberCount members including built-in Administrator in $forestRoot - group should be empty when not doing schema work"
                }
            }
        }
    }
    catch {
        Write-Warning "[SEC-016] Failed to check Schema Admins in $forestRoot`: $($_.Exception.Message)"
        $results += [PSCustomObject]@{
            Domain       = $forestRoot
            MemberName   = 'Unknown'
            MemberType   = 'Unknown'
            IsBuiltIn    = $false
            MemberCount  = 0
            HasIssue     = $true
            Status       = 'Error'
            Severity     = 'Error'
            IsHealthy    = $false
            Message      = "Failed to check Schema Admins membership: $($_.Exception.Message)"
        }
    }

    Write-Verbose "[SEC-016] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[SEC-016] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain       = 'Unknown'
        MemberName   = 'Unknown'
        MemberType   = 'Unknown'
        IsBuiltIn    = $false
        MemberCount  = 0
        HasIssue     = $true
        Status       = 'Error'
        Severity     = 'Error'
        IsHealthy    = $false
        Message      = "Check execution failed: $($_.Exception.Message)"
    })
}
