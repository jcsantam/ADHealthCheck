<#
.SYNOPSIS
    Protected Users Group Check (SEC-012)

.DESCRIPTION
    Checks whether privileged accounts are members of the Protected Users
    security group. Members of Protected Users receive additional Kerberos
    protections including:
    - No NTLM authentication
    - No DES or RC4 Kerberos encryption
    - No unconstrained or constrained delegation
    - TGT lifetime reduced to 4 hours

    The Protected Users group is available on domains with Windows Server 2012 R2+
    DFL. This check verifies:
    - The Protected Users group exists (requires DFL 2012 R2+)
    - Tier-0 privileged accounts (DA, EA, Schema Admins) are members
    - Flags Tier-0 accounts NOT in Protected Users

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ProtectedUsersGroup.ps1 -Inventory $inventory

.OUTPUTS
    Array of Protected Users group membership results

.NOTES
    Check ID: SEC-012
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

Write-Verbose "[SEC-012] Starting Protected Users group check..."

# Privileged groups whose members should ideally be in Protected Users
$tier0Groups = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators')

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[SEC-012] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        $domainName = $domain.Name
        $domainDN   = 'DC=' + ($domainName -replace '\.', ',DC=')

        Write-Verbose "[SEC-012] Checking Protected Users in domain: $domainName"

        try {
            # Check if Protected Users group exists
            $protectedUsersGroup = $null
            try {
                $protectedUsersGroup = Get-ADGroup -Identity "CN=Protected Users,CN=Users,$domainDN" `
                    -Server $domainName `
                    -Properties Members `
                    -ErrorAction SilentlyContinue
            }
            catch {
                Write-Verbose "[SEC-012] Protected Users group not found in $domainName"
            }

            if (-not $protectedUsersGroup) {
                $results += [PSCustomObject]@{
                    Domain                  = $domainName
                    AccountName             = 'N/A'
                    IsInProtectedUsers      = $false
                    PrivilegedGroupMembership = 'N/A'
                    HasIssue                = $true
                    Status                  = 'Warning'
                    Severity                = 'Medium'
                    IsHealthy               = $false
                    Message                 = "Protected Users group not found in $domainName - requires Domain Functional Level 2012 R2 or higher"
                }
                continue
            }

            # Get members of Protected Users
            $protectedMembers = @(Get-ADGroupMember -Identity $protectedUsersGroup -Recursive `
                -Server $domainName `
                -ErrorAction SilentlyContinue | Select-Object -ExpandProperty SamAccountName)

            Write-Verbose "[SEC-012] Protected Users has $($protectedMembers.Count) members in $domainName"

            # Collect Tier-0 users from privileged groups
            $tier0Users = @{}
            foreach ($groupName in $tier0Groups) {
                try {
                    $grp = Get-ADGroup -Filter { Name -eq $groupName } -Server $domainName -ErrorAction SilentlyContinue
                    if (-not $grp) { continue }

                    $members = @(Get-ADGroupMember -Identity $grp -Recursive -Server $domainName -ErrorAction SilentlyContinue)
                    foreach ($m in $members) {
                        if ($m.objectClass -eq 'user') {
                            if (-not $tier0Users.ContainsKey($m.SamAccountName)) {
                                $tier0Users[$m.SamAccountName] = @()
                            }
                            $tier0Users[$m.SamAccountName] += $groupName
                        }
                    }
                }
                catch {
                    Write-Verbose "[SEC-012] Could not enumerate $groupName in $domainName"
                }
            }

            Write-Verbose "[SEC-012] Found $($tier0Users.Count) unique Tier-0 users in $domainName"

            $foundIssue = $false
            foreach ($userName in $tier0Users.Keys) {
                $groups  = $tier0Users[$userName] -join ', '
                $inGroup = $protectedMembers -contains $userName

                if (-not $inGroup) {
                    $foundIssue = $true
                    $results += [PSCustomObject]@{
                        Domain                    = $domainName
                        AccountName               = $userName
                        IsInProtectedUsers        = $false
                        PrivilegedGroupMembership = $groups
                        HasIssue                  = $true
                        Status                    = 'Warning'
                        Severity                  = 'Medium'
                        IsHealthy                 = $false
                        Message                   = "Privileged account '$userName' (member of: $groups) is NOT in the Protected Users group in $domainName"
                    }
                }
            }

            if (-not $foundIssue) {
                $results += [PSCustomObject]@{
                    Domain                    = $domainName
                    AccountName               = 'Summary'
                    IsInProtectedUsers        = $true
                    PrivilegedGroupMembership = 'N/A'
                    HasIssue                  = $false
                    Status                    = 'Pass'
                    Severity                  = 'Info'
                    IsHealthy                 = $true
                    Message                   = "All Tier-0 privileged accounts in $domainName are members of the Protected Users group"
                }
            }
        }
        catch {
            Write-Warning "[SEC-012] Failed to check Protected Users in $domainName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain                    = $domainName
                AccountName               = 'Unknown'
                IsInProtectedUsers        = $false
                PrivilegedGroupMembership = 'Unknown'
                HasIssue                  = $true
                Status                    = 'Error'
                Severity                  = 'Error'
                IsHealthy                 = $false
                Message                   = "Failed to check Protected Users in $domainName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[SEC-012] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[SEC-012] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain                    = 'Unknown'
        AccountName               = 'Unknown'
        IsInProtectedUsers        = $false
        PrivilegedGroupMembership = 'Unknown'
        HasIssue                  = $true
        Status                    = 'Error'
        Severity                  = 'Error'
        IsHealthy                 = $false
        Message                   = "Check execution failed: $($_.Exception.Message)"
    })
}
