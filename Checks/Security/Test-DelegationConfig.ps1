<#
.SYNOPSIS
    Delegation Configuration Check (SEC-008)
.DESCRIPTION
    Detects user and computer accounts with unconstrained Kerberos delegation
    configured. Unconstrained delegation is a significant security risk as it
    allows the delegated account to impersonate any user to any service.
    Domain Controllers are excluded as they legitimately require this setting.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: SEC-008
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
$results = @()

Write-Verbose "[SEC-008] Starting delegation configuration check..."

try {
    $domains = $Inventory.Domains
    if (-not $domains) {
        Write-Warning "[SEC-008] No domains found"
        return @()
    }

    foreach ($domain in $domains) {
        Write-Verbose "[SEC-008] Checking delegation in domain: $($domain.Name)"

        $unconstrainedUsers     = @()
        $unconstrainedComputers = @()

        # Check user accounts with unconstrained delegation
        try {
            $unconstrainedUsers = @(Get-ADUser -Filter { TrustedForDelegation -eq $true } `
                -Server $domain.Name `
                -Properties TrustedForDelegation, SamAccountName, Enabled, DistinguishedName `
                -ErrorAction Stop)

            Write-Verbose "[SEC-008] Found $(@($unconstrainedUsers).Count) user(s) with unconstrained delegation in $($domain.Name)"
        }
        catch {
            Write-Warning "[SEC-008] Failed to query users in $($domain.Name): $_"
        }

        # Check computer accounts with unconstrained delegation
        # PrimaryGroupID 516 = Domain Controllers group (exclude these)
        try {
            $unconstrainedComputers = @(Get-ADComputer -Filter { TrustedForDelegation -eq $true -and PrimaryGroupID -ne 516 } `
                -Server $domain.Name `
                -Properties TrustedForDelegation, SamAccountName, Enabled, DistinguishedName `
                -ErrorAction Stop)

            Write-Verbose "[SEC-008] Found $(@($unconstrainedComputers).Count) computer(s) with unconstrained delegation in $($domain.Name)"
        }
        catch {
            Write-Warning "[SEC-008] Failed to query computers in $($domain.Name): $_"
        }

        $userCount     = @($unconstrainedUsers).Count
        $computerCount = @($unconstrainedComputers).Count
        $hasIssue      = $userCount -gt 0 -or $computerCount -gt 0

        # Build account list (max 10 entries)
        $allAccounts = @()
        $allAccounts += @($unconstrainedUsers | Select-Object -First 5 | ForEach-Object { "$($_.SamAccountName) (user)" })
        $allAccounts += @($unconstrainedComputers | Select-Object -First 5 | ForEach-Object { "$($_.SamAccountName) (computer)" })
        $accountList  = ($allAccounts | Select-Object -First 10) -join ', '

        $severity = if ($userCount -gt 0)     { 'Critical' }
                    elseif ($computerCount -gt 0) { 'High' }
                    else { 'Info' }
        $status   = if ($hasIssue) { 'Fail' } else { 'Healthy' }

        $results += [PSCustomObject]@{
            Domain                    = $domain.Name
            UnconstrainedUserCount    = $userCount
            UnconstrainedComputerCount = $computerCount
            AccountList               = $accountList
            IsHealthy                 = -not $hasIssue
            HasIssue                  = $hasIssue
            Status                    = $status
            Severity                  = $severity
            Message                   = if ($userCount -gt 0) {
                "CRITICAL: $userCount user account(s) with unconstrained delegation in $($domain.Name): $accountList"
            } elseif ($computerCount -gt 0) {
                "WARNING: $computerCount computer account(s) with unconstrained delegation in $($domain.Name): $accountList"
            } else {
                "No accounts with unconstrained delegation found in $($domain.Name)"
            }
        }
    }

    Write-Verbose "[SEC-008] Check complete. Domains checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[SEC-008] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain                     = 'Unknown'
        UnconstrainedUserCount     = 0
        UnconstrainedComputerCount = 0
        AccountList                = ''
        IsHealthy                  = $false
        HasIssue                   = $true
        Status                     = 'Error'
        Severity                   = 'Error'
        Message                    = "Check execution failed: $($_.Exception.Message)"
    })
}
