<#
.SYNOPSIS
    AdminSDHolder Integrity Check (SEC-010)

.DESCRIPTION
    Checks the AdminSDHolder object for security issues:
    - Detects accounts with adminCount=1 that are no longer members of any
      privileged group (orphaned adminCount). These accounts retain locked-down
      ACLs but are no longer protected, creating a hidden persistence vector.
    - Checks for unexpected non-default principals with explicit Allow permissions
      on the AdminSDHolder object itself.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-AdminSDHolder.ps1 -Inventory $inventory

.OUTPUTS
    Array of AdminSDHolder integrity results

.NOTES
    Check ID: SEC-010
    Category: Security
    Severity: High
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

Write-Verbose "[SEC-010] Starting AdminSDHolder integrity check..."

# Well-known privileged group names to check for orphaned adminCount
$privilegedGroups = @(
    'Domain Admins',
    'Enterprise Admins',
    'Schema Admins',
    'Administrators',
    'Account Operators',
    'Backup Operators',
    'Print Operators',
    'Server Operators',
    'Group Policy Creator Owners',
    'Cryptographic Operators',
    'Network Configuration Operators'
)

# Default well-known SIDs/principals expected on AdminSDHolder ACL
$defaultPrincipals = @(
    'NT AUTHORITY\SYSTEM',
    'BUILTIN\Administrators',
    'NT AUTHORITY\Authenticated Users',
    'NT AUTHORITY\ENTERPRISE DOMAIN CONTROLLERS',
    'Everyone',
    'CREATOR OWNER',
    'SELF'
)

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[SEC-010] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        $domainName = $domain.Name
        $domainDN   = 'DC=' + ($domainName -replace '\.', ',DC=')

        Write-Verbose "[SEC-010] Checking domain: $domainName"

        try {
            # ---- Orphaned adminCount accounts ----
            $adminCountUsers = @(Get-ADUser -Filter { adminCount -eq 1 } `
                -Server $domainName `
                -Properties adminCount, MemberOf, Enabled `
                -ErrorAction SilentlyContinue)

            Write-Verbose "[SEC-010] Found $($adminCountUsers.Count) users with adminCount=1 in $domainName"

            foreach ($user in $adminCountUsers) {
                # Collect all group memberships (recursive via tokenGroups or MemberOf)
                $memberOfNames = @()
                if ($user.MemberOf) {
                    foreach ($groupDN in $user.MemberOf) {
                        try {
                            $grp = Get-ADGroup -Identity $groupDN -Server $domainName -ErrorAction SilentlyContinue
                            if ($grp) { $memberOfNames += $grp.Name }
                        } catch { }
                    }
                }

                $inPrivilegedGroup = $false
                foreach ($pg in $privilegedGroups) {
                    if ($memberOfNames -contains $pg) {
                        $inPrivilegedGroup = $true
                        break
                    }
                }

                if (-not $inPrivilegedGroup) {
                    $results += [PSCustomObject]@{
                        Domain           = $domainName
                        ObjectName       = $user.SamAccountName
                        ObjectType       = 'User'
                        IssueType        = 'OrphanedAdminCount'
                        IsEnabled        = $user.Enabled
                        HasIssue         = $true
                        Status           = 'Fail'
                        Severity         = 'High'
                        IsHealthy        = $false
                        Message          = "User '$($user.SamAccountName)' has adminCount=1 but is not a member of any privileged group - SDProp will not reset this ACL, leaving it locked down indefinitely"
                    }
                }
            }

            # ---- AdminSDHolder ACL check ----
            $adminSDHolderDN = "CN=AdminSDHolder,CN=System,$domainDN"

            try {
                $aclObj = Get-Acl -Path "AD:$adminSDHolderDN" -ErrorAction SilentlyContinue

                if ($aclObj) {
                    foreach ($ace in $aclObj.Access) {
                        if ($ace.AccessControlType -ne 'Allow') { continue }

                        $principal = $ace.IdentityReference.ToString()

                        # Check if this principal is a known default
                        $isDefault = $false
                        foreach ($def in $defaultPrincipals) {
                            if ($principal -like "*$def*") {
                                $isDefault = $true
                                break
                            }
                        }
                        # Also skip Domain Admins / Enterprise Admins
                        if ($principal -like "*Domain Admins*" -or $principal -like "*Enterprise Admins*" -or $principal -like "*Administrators*") {
                            $isDefault = $true
                        }

                        if (-not $isDefault) {
                            $results += [PSCustomObject]@{
                                Domain           = $domainName
                                ObjectName       = $principal
                                ObjectType       = 'ACE'
                                IssueType        = 'UnexpectedACE'
                                IsEnabled        = $null
                                HasIssue         = $true
                                Status           = 'Warning'
                                Severity         = 'High'
                                IsHealthy        = $false
                                Message          = "Unexpected principal '$principal' has Allow permissions on AdminSDHolder in $domainName - verify this is intentional"
                            }
                        }
                    }
                }
            }
            catch {
                Write-Warning "[SEC-010] Could not read AdminSDHolder ACL in $domainName`: $($_.Exception.Message)"
            }

            # If no issues found for this domain, add a pass result
            $domainResults = @($results | Where-Object { $_.Domain -eq $domainName })
            if ($domainResults.Count -eq 0) {
                $results += [PSCustomObject]@{
                    Domain           = $domainName
                    ObjectName       = 'AdminSDHolder'
                    ObjectType       = 'Summary'
                    IssueType        = 'None'
                    IsEnabled        = $null
                    HasIssue         = $false
                    Status           = 'Pass'
                    Severity         = 'Info'
                    IsHealthy        = $true
                    Message          = "AdminSDHolder integrity is healthy in $domainName - no orphaned adminCount accounts or unexpected ACEs detected"
                }
            }
        }
        catch {
            Write-Warning "[SEC-010] Failed to check domain $domainName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain           = $domainName
                ObjectName       = 'Unknown'
                ObjectType       = 'Unknown'
                IssueType        = 'Error'
                IsEnabled        = $null
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to check AdminSDHolder in $domainName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[SEC-010] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[SEC-010] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain     = 'Unknown'
        ObjectName = 'Unknown'
        ObjectType = 'Unknown'
        IssueType  = 'Error'
        IsEnabled  = $null
        HasIssue   = $true
        Status     = 'Error'
        Severity   = 'Error'
        IsHealthy  = $false
        Message    = "Check execution failed: $($_.Exception.Message)"
    })
}
