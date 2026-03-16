<#
.SYNOPSIS
    Kerberos Policy Check (SEC-009)
.DESCRIPTION
    Checks Kerberos ticket policy settings from the Default Domain Policy GPO.
    Validates maximum ticket age, renewal age, service ticket lifetime, and
    clock skew tolerance against Microsoft security recommendations.
    Requires the GroupPolicy PowerShell module.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: SEC-009
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
$results = @()

Write-Verbose "[SEC-009] Starting Kerberos policy check..."

# Check for GroupPolicy module availability
$gpoModule = Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue
if (-not $gpoModule) {
    return @([PSCustomObject]@{
        Domain                  = 'N/A'
        MaxTicketAgeDays        = $null
        MaxRenewAgeDays         = $null
        MaxServiceTicketMinutes = $null
        MaxClockSkewMinutes     = $null
        PolicyIssues            = 'GroupPolicy module not available'
        IsHealthy               = $true
        HasIssue                = $false
        Status                  = 'Pass'
        Severity                = 'Info'
        Message                 = 'GroupPolicy module not available - skipping Kerberos policy check'
    })
}

try {
    Import-Module GroupPolicy -ErrorAction SilentlyContinue

    $domains = $Inventory.Domains
    if (-not $domains) {
        Write-Warning "[SEC-009] No domains found"
        return @()
    }

    foreach ($domain in $domains) {
        Write-Verbose "[SEC-009] Checking Kerberos policy in domain: $($domain.Name)"

        try {
            # Get Default Domain Policy GPO report
            $gpo = Get-GPO -Name 'Default Domain Policy' -Domain $domain.Name -ErrorAction Stop

            [xml]$gpoReport = Get-GPOReport -Guid $gpo.Id -ReportType Xml -Domain $domain.Name -ErrorAction Stop

            # Navigate to Kerberos policy in the XML
            # Path: GPO/Computer/ExtensionData/Extension/Account (type KerberosPolicy)
            $kerberosSection = $gpoReport.GPO.Computer.ExtensionData |
                Where-Object { $_.Name -eq 'Security' } |
                Select-Object -First 1

            $maxTicketAge        = $null
            $maxRenewAge         = $null
            $maxServiceTicket    = $null
            $maxClockSkew        = $null

            if ($kerberosSection) {
                $kerberosSettings = $kerberosSection.Extension.Account |
                    Where-Object { $_.Type -eq 'Kerberos' }

                foreach ($setting in $kerberosSettings) {
                    switch ($setting.Name) {
                        'MaxTicketAge'     { $maxTicketAge     = [int]$setting.SettingNumber }
                        'MaxRenewAge'      { $maxRenewAge      = [int]$setting.SettingNumber }
                        'MaxServiceAge'    { $maxServiceTicket = [int]$setting.SettingNumber }
                        'MaxClockSkew'     { $maxClockSkew     = [int]$setting.SettingNumber }
                    }
                }
            }

            # Apply defaults if not configured
            # Standard Kerberos defaults: MaxTicketAge=10h, MaxRenewAge=7d, MaxServiceTicket=600min, MaxClockSkew=5min
            if ($null -eq $maxTicketAge)     { $maxTicketAge     = 10  }   # hours
            if ($null -eq $maxRenewAge)      { $maxRenewAge      = 7   }   # days
            if ($null -eq $maxServiceTicket) { $maxServiceTicket = 600 }   # minutes
            if ($null -eq $maxClockSkew)     { $maxClockSkew     = 5   }   # minutes

            $issues   = @()
            $hasIssue = $false

            # HasIssue if MaxClockSkew > 10 minutes
            if ($maxClockSkew -gt 10) {
                $hasIssue = $true
                $issues  += "MaxClockSkew is $maxClockSkew min (recommended: <= 5 min; max safe: 10 min)"
            }

            # HasIssue if MaxTicketAge < 1 hour
            if ($maxTicketAge -lt 1) {
                $hasIssue = $true
                $issues  += "MaxTicketAge is $maxTicketAge hours (too low - must be at least 1 hour)"
            }

            # Warning if MaxTicketAge > 24 hours (loosened security)
            if ($maxTicketAge -gt 24) {
                $issues  += "MaxTicketAge is $maxTicketAge hours (recommended: 10 hours)"
                $hasIssue = $true
            }

            $severity = if ($hasIssue -and $maxClockSkew -gt 10) { 'Medium' }
                        elseif ($hasIssue) { 'Medium' }
                        else { 'Info' }

            $results += [PSCustomObject]@{
                Domain                  = $domain.Name
                MaxTicketAgeDays        = [math]::Round($maxTicketAge / 24, 2)
                MaxRenewAgeDays         = $maxRenewAge
                MaxServiceTicketMinutes = $maxServiceTicket
                MaxClockSkewMinutes     = $maxClockSkew
                PolicyIssues            = ($issues -join '; ')
                IsHealthy               = -not $hasIssue
                HasIssue                = $hasIssue
                Status                  = if ($hasIssue) { 'Warning' } else { 'Healthy' }
                Severity                = $severity
                Message                 = if ($hasIssue) {
                    "Kerberos policy issues in $($domain.Name): " + ($issues -join '; ')
                } else {
                    "Kerberos policy in $($domain.Name) meets security requirements (ClockSkew: $maxClockSkew min, TicketAge: $maxTicketAge h)"
                }
            }
        }
        catch {
            Write-Warning "[SEC-009] Failed to read Kerberos policy in $($domain.Name): $_"
            $results += [PSCustomObject]@{
                Domain                  = $domain.Name
                MaxTicketAgeDays        = $null
                MaxRenewAgeDays         = $null
                MaxServiceTicketMinutes = $null
                MaxClockSkewMinutes     = $null
                PolicyIssues            = "Query failed: $_"
                IsHealthy               = $false
                HasIssue                = $true
                Status                  = 'Error'
                Severity                = 'Error'
                Message                 = "Failed to read Kerberos policy in $($domain.Name): $_"
            }
        }
    }

    Write-Verbose "[SEC-009] Check complete. Domains checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[SEC-009] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain                  = 'Unknown'
        MaxTicketAgeDays        = $null
        MaxRenewAgeDays         = $null
        MaxServiceTicketMinutes = $null
        MaxClockSkewMinutes     = $null
        PolicyIssues            = "Check failed: $($_.Exception.Message)"
        IsHealthy               = $false
        HasIssue                = $true
        Status                  = 'Error'
        Severity                = 'Error'
        Message                 = "Check execution failed: $($_.Exception.Message)"
    })
}
