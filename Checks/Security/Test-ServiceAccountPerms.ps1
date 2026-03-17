<#
.SYNOPSIS
    Service Account Permissions Check (SEC-014)

.DESCRIPTION
    Identifies service accounts (accounts with SPNs) that have excessive Active
    Directory privileges. Service accounts are common targets for Kerberoasting
    attacks. If a Kerberoastable account also has Domain Admin or other sensitive
    group membership, compromise leads directly to domain takeover.

    Checks:
    - Service accounts (accounts with non-empty servicePrincipalName) that are
      members of highly privileged groups (Domain Admins, Enterprise Admins,
      Schema Admins, Account Operators, Backup Operators)
    - Service accounts with PasswordNeverExpires = true (increases window for
      offline cracking after Kerberoasting)

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ServiceAccountPerms.ps1 -Inventory $inventory

.OUTPUTS
    Array of service account permission results per domain

.NOTES
    Check ID: SEC-014
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

Write-Verbose "[SEC-014] Starting service account permissions check..."

$sensitiveGroups = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Account Operators', 'Backup Operators', 'Print Operators', 'Server Operators')

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[SEC-014] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        $domainName = $domain.Name
        $domainDN   = 'DC=' + ($domainName -replace '\.', ',DC=')

        Write-Verbose "[SEC-014] Checking service account permissions in domain: $domainName"

        try {
            # Get all enabled users with SPNs (Kerberoastable accounts)
            $serviceAccounts = @(Get-ADUser -Filter { Enabled -eq $true -and ServicePrincipalName -like '*' } `
                -Server $domainName `
                -Properties ServicePrincipalName, MemberOf, PasswordNeverExpires, Description `
                -SearchBase $domainDN `
                -ErrorAction SilentlyContinue)

            Write-Verbose "[SEC-014] Found $($serviceAccounts.Count) service accounts with SPNs in $domainName"

            if ($serviceAccounts.Count -eq 0) {
                $results += [PSCustomObject]@{
                    Domain                = $domainName
                    AccountName           = 'N/A'
                    SPN                   = 'N/A'
                    SensitiveGroups       = 'N/A'
                    PasswordNeverExpires  = $false
                    IssueType             = 'None'
                    HasIssue              = $false
                    Status                = 'Pass'
                    Severity              = 'Info'
                    IsHealthy             = $true
                    Message               = "No Kerberoastable service accounts found in $domainName"
                }
                continue
            }

            # Build lookup of sensitive group members
            $sensitiveMembers = @{}
            foreach ($groupName in $sensitiveGroups) {
                try {
                    $grp = Get-ADGroup -Filter { Name -eq $groupName } -Server $domainName -ErrorAction SilentlyContinue
                    if (-not $grp) { continue }
                    $members = @(Get-ADGroupMember -Identity $grp -Recursive -Server $domainName -ErrorAction SilentlyContinue)
                    foreach ($m in $members) {
                        if (-not $sensitiveMembers.ContainsKey($m.SamAccountName)) {
                            $sensitiveMembers[$m.SamAccountName] = @()
                        }
                        $sensitiveMembers[$m.SamAccountName] += $groupName
                    }
                }
                catch {
                    Write-Verbose "[SEC-014] Could not enumerate $groupName in $domainName"
                }
            }

            $domainFoundIssue = $false

            foreach ($svcAcct in $serviceAccounts) {
                $spnList   = ($svcAcct.ServicePrincipalName | Select-Object -First 3) -join ', '
                $inGroups  = @()
                $hasIssue  = $false
                $status    = 'Pass'
                $severity  = 'Info'
                $issueType = 'None'
                $message   = ''

                if ($sensitiveMembers.ContainsKey($svcAcct.SamAccountName)) {
                    $inGroups  = $sensitiveMembers[$svcAcct.SamAccountName]
                    $hasIssue  = $true
                    $status    = 'Fail'
                    $severity  = 'Critical'
                    $issueType = 'SensitiveGroupMember'
                    $domainFoundIssue = $true
                    $groupList = $inGroups -join ', '
                    $message   = "Service account '$($svcAcct.SamAccountName)' (SPN: $spnList) is Kerberoastable AND member of: $groupList - immediate privilege escalation risk"
                }
                elseif ($svcAcct.PasswordNeverExpires) {
                    $hasIssue  = $true
                    $status    = 'Warning'
                    $severity  = 'Medium'
                    $issueType = 'PasswordNeverExpires'
                    $domainFoundIssue = $true
                    $message   = "Service account '$($svcAcct.SamAccountName)' (SPN: $spnList) has PasswordNeverExpires=true - long window for offline Kerberoast cracking"
                }
                else {
                    $message = "Service account '$($svcAcct.SamAccountName)' (SPN: $spnList) - no excessive permissions detected"
                }

                if ($hasIssue) {
                    $results += [PSCustomObject]@{
                        Domain               = $domainName
                        AccountName          = $svcAcct.SamAccountName
                        SPN                  = $spnList
                        SensitiveGroups      = ($inGroups -join ', ')
                        PasswordNeverExpires = $svcAcct.PasswordNeverExpires
                        IssueType            = $issueType
                        HasIssue             = $hasIssue
                        Status               = $status
                        Severity             = $severity
                        IsHealthy            = $false
                        Message              = $message
                    }
                }
            }

            if (-not $domainFoundIssue) {
                $results += [PSCustomObject]@{
                    Domain               = $domainName
                    AccountName          = 'Summary'
                    SPN                  = 'N/A'
                    SensitiveGroups      = 'None'
                    PasswordNeverExpires = $false
                    IssueType            = 'None'
                    HasIssue             = $false
                    Status               = 'Pass'
                    Severity             = 'Info'
                    IsHealthy            = $true
                    Message              = "All $($serviceAccounts.Count) service accounts in $domainName have acceptable permission levels"
                }
            }
        }
        catch {
            Write-Warning "[SEC-014] Failed to check service accounts in $domainName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain               = $domainName
                AccountName          = 'Unknown'
                SPN                  = 'Unknown'
                SensitiveGroups      = 'Unknown'
                PasswordNeverExpires = $false
                IssueType            = 'Error'
                HasIssue             = $true
                Status               = 'Error'
                Severity             = 'Error'
                IsHealthy            = $false
                Message              = "Failed to check service account permissions in $domainName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[SEC-014] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[SEC-014] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain               = 'Unknown'
        AccountName          = 'Unknown'
        SPN                  = 'Unknown'
        SensitiveGroups      = 'Unknown'
        PasswordNeverExpires = $false
        IssueType            = 'Error'
        HasIssue             = $true
        Status               = 'Error'
        Severity             = 'Error'
        IsHealthy            = $false
        Message              = "Check execution failed: $($_.Exception.Message)"
    })
}
