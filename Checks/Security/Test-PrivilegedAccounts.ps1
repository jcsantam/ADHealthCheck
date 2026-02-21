<#
.SYNOPSIS
    AdminSDHolder and Privileged Groups Check (SEC-002)

.DESCRIPTION
    Monitors privileged group membership and AdminSDHolder integrity:
    - Members of Domain Admins, Enterprise Admins, Schema Admins
    - Unexpected privileged group members
    - AdminSDHolder propagation issues
    - Protected accounts validation
    - Service accounts in privileged groups

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-PrivilegedAccounts.ps1 -Inventory $inventory

.OUTPUTS
    Array of privileged account results

.NOTES
    Check ID: SEC-002
    Category: Security
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

# Privileged groups to monitor
$privilegedGroups = @(
    'Domain Admins',
    'Enterprise Admins',
    'Schema Admins',
    'Administrators',
    'Account Operators',
    'Backup Operators',
    'Print Operators',
    'Server Operators',
    'Replicator'
)

Write-Verbose "[SEC-002] Starting privileged accounts check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[SEC-002] No domains found in inventory"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[SEC-002] Processing domain: $($domain.Name)"
        
        try {
            foreach ($groupName in $privilegedGroups) {
                try {
                    # Get group
                    $group = Get-ADGroup -Filter "Name -eq '$groupName'" -Server $domain.Name -ErrorAction SilentlyContinue
                    
                    if (-not $group) {
                        Write-Verbose "[SEC-002] Group '$groupName' not found in $($domain.Name)"
                        continue
                    }
                    
                    # Get group members
                    $members = Get-ADGroupMember -Identity $group -Server $domain.Name -ErrorAction Stop
                    
                    Write-Verbose "[SEC-002] Group '$groupName' has $($members.Count) members"
                    
                    foreach ($member in $members) {
                        # Get member details
                        $memberDetails = Get-ADObject -Identity $member.DistinguishedName `
                            -Properties whenCreated, whenChanged, adminCount, servicePrincipalName `
                            -Server $domain.Name -ErrorAction Stop
                        
                        $issues = @()
                        $severity = 'Info'
                        
                        # Check if recently added (last 30 days)
                        $daysSinceAdded = ((Get-Date) - $memberDetails.whenCreated).Days
                        if ($daysSinceAdded -le 30) {
                            $issues += "Recently added ($daysSinceAdded days ago)"
                            $severity = 'Medium'
                        }
                        
                        # Check if service account (has SPN)
                        if ($memberDetails.servicePrincipalName) {
                            $issues += "Service account in privileged group"
                            $severity = 'High'
                        }
                        
                        # Check AdminSDHolder protection
                        $hasAdminCount = ($memberDetails.adminCount -eq 1)
                        if (-not $hasAdminCount -and $groupName -in @('Domain Admins', 'Enterprise Admins', 'Schema Admins')) {
                            $issues += "Missing AdminSDHolder protection (adminCount not set)"
                            $severity = 'High'
                        }
                        
                        # Report all privileged members
                        $result = [PSCustomObject]@{
                            Domain = $domain.Name
                            PrivilegedGroup = $groupName
                            MemberName = $member.Name
                            MemberType = $member.objectClass
                            WhenCreated = $memberDetails.whenCreated
                            WhenChanged = $memberDetails.whenChanged
                            HasAdminCount = $hasAdminCount
                            IsServiceAccount = ($memberDetails.servicePrincipalName -ne $null)
                            DaysSinceAdded = $daysSinceAdded
                            Issues = if ($issues.Count -gt 0) { $issues -join "; " } else { "None" }
                            Severity = $severity
                            Status = if ($issues.Count -gt 0) { 'Warning' } else { 'Info' }
                            IsHealthy = ($issues.Count -eq 0)
                            HasIssue = ($issues.Count -gt 0)
                            Message = if ($issues.Count -gt 0) {
                                "Privileged account issue: $($issues -join ', ')"
                            } else {
                                "Member of $groupName"
                            }
                        }
                        
                        $results += $result
                    }
                    
                    # Add group summary
                    $summaryResult = [PSCustomObject]@{
                        Domain = $domain.Name
                        PrivilegedGroup = $groupName
                        MemberName = "SUMMARY"
                        MemberType = "Group"
                        WhenCreated = $group.whenCreated
                        WhenChanged = $group.whenChanged
                        HasAdminCount = $null
                        IsServiceAccount = $null
                        DaysSinceAdded = 0
                        Issues = "Total members: $($members.Count)"
                        Severity = 'Info'
                        Status = 'Info'
                        IsHealthy = $true
                        HasIssue = $false
                        Message = "$groupName has $($members.Count) members"
                    }
                    
                    $results += $summaryResult
                }
                catch {
                    Write-Warning "[SEC-002] Failed to check group '$groupName': $($_.Exception.Message)"
                }
            }
            
            # Check AdminSDHolder object itself
            try {
                $adminSDHolder = Get-ADObject -Filter "Name -eq 'AdminSDHolder'" `
                    -SearchBase "CN=System,$((Get-ADDomain -Server $domain.Name).DistinguishedName)" `
                    -Properties nTSecurityDescriptor, whenChanged `
                    -Server $domain.Name -ErrorAction Stop
                
                if ($adminSDHolder) {
                    $daysSinceUpdate = ((Get-Date) - $adminSDHolder.whenChanged).Days
                    
                    $result = [PSCustomObject]@{
                        Domain = $domain.Name
                        PrivilegedGroup = "AdminSDHolder"
                        MemberName = "Container Object"
                        MemberType = "AdminSDHolder"
                        WhenCreated = $null
                        WhenChanged = $adminSDHolder.whenChanged
                        HasAdminCount = $null
                        IsServiceAccount = $null
                        DaysSinceAdded = 0
                        Issues = "Last propagation: $daysSinceUpdate days ago"
                        Severity = if ($daysSinceUpdate -gt 60) { 'Medium' } else { 'Info' }
                        Status = if ($daysSinceUpdate -gt 60) { 'Warning' } else { 'Healthy' }
                        IsHealthy = ($daysSinceUpdate -le 60)
                        HasIssue = ($daysSinceUpdate -gt 60)
                        Message = "AdminSDHolder last updated $daysSinceUpdate days ago"
                    }
                    
                    $results += $result
                }
            }
            catch {
                Write-Warning "[SEC-002] Failed to check AdminSDHolder: $($_.Exception.Message)"
            }
        }
        catch {
            Write-Error "[SEC-002] Failed to check domain $($domain.Name): $($_.Exception.Message)"
        }
    }
    
    Write-Verbose "[SEC-002] Check complete. Total results: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[SEC-002] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        PrivilegedGroup = "Unknown"
        MemberName = "Unknown"
        MemberType = "Unknown"
        WhenCreated = $null
        WhenChanged = $null
        HasAdminCount = $null
        IsServiceAccount = $null
        DaysSinceAdded = 0
        Issues = "Check execution failed"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
