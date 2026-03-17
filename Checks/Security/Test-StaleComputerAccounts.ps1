<#
.SYNOPSIS
    Stale Computer Accounts Detailed Check (SEC-015)

.DESCRIPTION
    Detailed analysis of stale computer accounts in Active Directory.
    Identifies enabled computer accounts that have not authenticated in 90+ days,
    broken down by OU, OS type, and whether they are workstations vs. servers.

    Unlike SEC-001 (basic stale computers check), this check provides:
    - Breakdown by OU
    - Server vs. workstation classification
    - Password age vs. last logon age analysis
    - Identifies accounts where password is also stale (double stale)

    Stale computer accounts create security risks:
    - Unused accounts can be hijacked for lateral movement
    - Old machine accounts may have known vulnerabilities
    - Inflate the computer count, complicating license management

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-StaleComputerAccounts.ps1 -Inventory $inventory

.OUTPUTS
    Array of stale computer account results per domain

.NOTES
    Check ID: SEC-015
    Category: Security
    Severity: Medium
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

Write-Verbose "[SEC-015] Starting detailed stale computer accounts check..."

$staleThresholdDays = 90
$cutoffDate = (Get-Date).AddDays(-$staleThresholdDays)
# lastLogonTimestamp is stored as Windows file time (100-ns intervals since 1601)
$cutoffFileTime = $cutoffDate.ToFileTime()

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[SEC-015] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        $domainName = $domain.Name
        $domainDN   = 'DC=' + ($domainName -replace '\.', ',DC=')

        Write-Verbose "[SEC-015] Checking stale computer accounts in domain: $domainName"

        try {
            # Get enabled computers with last logon info
            $computers = @(Get-ADComputer -Filter { Enabled -eq $true } `
                -Server $domainName `
                -Properties lastLogonTimestamp, PasswordLastSet, OperatingSystem, DistinguishedName `
                -SearchBase $domainDN `
                -ErrorAction SilentlyContinue)

            Write-Verbose "[SEC-015] Found $($computers.Count) enabled computers in $domainName"

            $staleCount    = 0
            $serverCount   = 0
            $workstCount   = 0
            $doubleStale   = 0
            $ouBreakdown   = @{}

            foreach ($comp in $computers) {
                $lastLogon = $null
                if ($comp.lastLogonTimestamp -and $comp.lastLogonTimestamp -gt 0) {
                    $lastLogon = [DateTime]::FromFileTime($comp.lastLogonTimestamp)
                }

                $isStale = (-not $lastLogon -or $lastLogon -lt $cutoffDate)
                if (-not $isStale) { continue }

                $staleCount++

                # Classify OS
                $os = if ($comp.OperatingSystem) { $comp.OperatingSystem } else { 'Unknown' }
                $isServer = ($os -match 'Server|Domain Controller')
                if ($isServer) { $serverCount++ } else { $workstCount++ }

                # Check password age
                $pwdStale = $false
                if ($comp.PasswordLastSet -and $comp.PasswordLastSet -lt $cutoffDate) {
                    $pwdStale = $true
                    $doubleStale++
                }

                # Extract OU from DN
                $dn  = $comp.DistinguishedName
                $ou  = 'Unknown'
                if ($dn -match ',OU=([^,]+)') { $ou = $matches[1] }
                elseif ($dn -match ',CN=([^,]+)') { $ou = "CN=$($matches[1])" }

                if (-not $ouBreakdown.ContainsKey($ou)) { $ouBreakdown[$ou] = 0 }
                $ouBreakdown[$ou]++

                $lastLogonStr = if ($lastLogon) { $lastLogon.ToString('yyyy-MM-dd') } else { 'Never' }
                $pwdAge       = if ($comp.PasswordLastSet) { [math]::Round(((Get-Date) - $comp.PasswordLastSet).TotalDays) } else { 9999 }

                $issueDetail = if ($pwdStale) { 'stale logon AND stale password' } else { 'stale logon' }

                $results += [PSCustomObject]@{
                    Domain          = $domainName
                    ComputerName    = $comp.Name
                    OperatingSystem = $os
                    IsServer        = $isServer
                    LastLogon       = $lastLogonStr
                    PasswordAgeDays = $pwdAge
                    OU              = $ou
                    IsDoubleStale   = $pwdStale
                    HasIssue        = $true
                    Status          = 'Warning'
                    Severity        = 'Medium'
                    IsHealthy       = $false
                    Message         = "Stale computer '$($comp.Name)' ($os) in OU '$ou' - $issueDetail (last logon: $lastLogonStr, pwd age: $pwdAge days)"
                }
            }

            if ($staleCount -eq 0) {
                $results += [PSCustomObject]@{
                    Domain          = $domainName
                    ComputerName    = 'Summary'
                    OperatingSystem = 'N/A'
                    IsServer        = $false
                    LastLogon       = 'N/A'
                    PasswordAgeDays = 0
                    OU              = 'N/A'
                    IsDoubleStale   = $false
                    HasIssue        = $false
                    Status          = 'Pass'
                    Severity        = 'Info'
                    IsHealthy       = $true
                    Message         = "No stale computer accounts detected in $domainName (all $($computers.Count) computers authenticated within $staleThresholdDays days)"
                }
            }
            else {
                Write-Verbose "[SEC-015] $domainName`: $staleCount stale ($serverCount servers, $workstCount workstations, $doubleStale double-stale)"
            }
        }
        catch {
            Write-Warning "[SEC-015] Failed to check computers in $domainName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain          = $domainName
                ComputerName    = 'Unknown'
                OperatingSystem = 'Unknown'
                IsServer        = $false
                LastLogon       = 'Unknown'
                PasswordAgeDays = 0
                OU              = 'Unknown'
                IsDoubleStale   = $false
                HasIssue        = $true
                Status          = 'Error'
                Severity        = 'Error'
                IsHealthy       = $false
                Message         = "Failed to check stale computers in $domainName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[SEC-015] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[SEC-015] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain          = 'Unknown'
        ComputerName    = 'Unknown'
        OperatingSystem = 'Unknown'
        IsServer        = $false
        LastLogon       = 'Unknown'
        PasswordAgeDays = 0
        OU              = 'Unknown'
        IsDoubleStale   = $false
        HasIssue        = $true
        Status          = 'Error'
        Severity        = 'Error'
        IsHealthy       = $false
        Message         = "Check execution failed: $($_.Exception.Message)"
    })
}
