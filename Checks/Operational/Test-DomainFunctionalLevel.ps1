<#
.SYNOPSIS
    Domain Functional Level Check (OPS-012)

.DESCRIPTION
    Checks the domain functional level for each domain. A low domain functional
    level prevents use of features such as fine-grained password policies and
    managed service accounts. Warns if any domain is below Windows Server 2016.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-012
    Category: Operational
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

Write-Verbose "[OPS-012] Starting domain functional level check..."

$domains = @($Inventory.Domains)

if ($domains.Count -eq 0) {
    return @([PSCustomObject]@{
        Domain            = 'Unknown'
        DomainMode        = 'Unknown'
        DomainModeVersion = 'Unknown'
        IsCurrentLevel    = $false
        IsHealthy         = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        Message           = 'No domains found in inventory'
    })
}

# Map domain mode string to ordering and friendly names
$domainModeOrder = @{
    'Windows2000Domain'   = 0
    'Windows2003Domain'   = 1
    'Windows2008Domain'   = 2
    'Windows2008R2Domain' = 3
    'Windows2012Domain'   = 4
    'Windows2012R2Domain' = 5
    'Windows2016Domain'   = 6
}

$domainModeNames = @{
    'Windows2000Domain'   = 'Windows Server 2000'
    'Windows2003Domain'   = 'Windows Server 2003'
    'Windows2008Domain'   = 'Windows Server 2008'
    'Windows2008R2Domain' = 'Windows Server 2008 R2'
    'Windows2012Domain'   = 'Windows Server 2012'
    'Windows2012R2Domain' = 'Windows Server 2012 R2'
    'Windows2016Domain'   = 'Windows Server 2016'
}

foreach ($domain in $domains) {
    $domainName = $domain.Name
    Write-Verbose "[OPS-012] Checking domain functional level for: $domainName"

    try {
        $domainObj  = Get-ADDomain -Identity $domainName -ErrorAction Stop
        $domainMode = $domainObj.DomainMode.ToString()

        $friendlyName = $domainModeNames[$domainMode]
        if ([string]::IsNullOrEmpty($friendlyName)) {
            $friendlyName = $domainMode
        }

        $modeLevel = $domainModeOrder[$domainMode]
        $isCurrentLevel = $false
        if ($null -ne $modeLevel -and $modeLevel -ge 6) {
            $isCurrentLevel = $true
        }

        if ($isCurrentLevel) {
            $results += [PSCustomObject]@{
                Domain            = $domainName
                DomainMode        = $domainMode
                DomainModeVersion = $friendlyName
                IsCurrentLevel    = $true
                IsHealthy         = $true
                HasIssue          = $false
                Status            = 'Pass'
                Severity          = 'Info'
                Message           = "Domain $domainName functional level is $friendlyName - meets the Windows Server 2016 baseline."
            }
        } else {
            $results += [PSCustomObject]@{
                Domain            = $domainName
                DomainMode        = $domainMode
                DomainModeVersion = $friendlyName
                IsCurrentLevel    = $false
                IsHealthy         = $false
                HasIssue          = $true
                Status            = 'Warning'
                Severity          = 'Low'
                Message           = "Domain $domainName functional level is $friendlyName - below Windows Server 2016. Upgrade DCs and raise the functional level."
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            Domain            = $domainName
            DomainMode        = 'Unknown'
            DomainModeVersion = 'Unknown'
            IsCurrentLevel    = $false
            IsHealthy         = $false
            HasIssue          = $true
            Status            = 'Error'
            Severity          = 'Error'
            Message           = "Failed to check domain functional level for $domainName - $_"
        }
    }
}

Write-Verbose "[OPS-012] Check complete. Domains checked: $($results.Count)"
return $results
