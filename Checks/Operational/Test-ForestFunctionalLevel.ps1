<#
.SYNOPSIS
    Forest Functional Level Check (OPS-011)

.DESCRIPTION
    Checks the forest functional level. A low forest functional level prevents
    enabling features like the AD Recycle Bin and Privileged Access Management.
    Warns if the forest is below Windows Server 2016 level.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-011
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

Write-Verbose "[OPS-011] Starting forest functional level check..."

$forestName = $Inventory.ForestInfo.Name

if ([string]::IsNullOrEmpty($forestName)) {
    return @([PSCustomObject]@{
        ForestName       = 'Unknown'
        ForestMode       = 'Unknown'
        ForestModeVersion = 'Unknown'
        IsCurrentLevel   = $false
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = 'Could not determine forest name from inventory'
    })
}

# Map forest mode string to friendly version name and ordering
$forestModeOrder = @{
    'Windows2000Forest'   = 0
    'Windows2003Forest'   = 1
    'Windows2008Forest'   = 2
    'Windows2008R2Forest' = 3
    'Windows2012Forest'   = 4
    'Windows2012R2Forest' = 5
    'Windows2016Forest'   = 6
}

$forestModeNames = @{
    'Windows2000Forest'   = 'Windows Server 2000'
    'Windows2003Forest'   = 'Windows Server 2003'
    'Windows2008Forest'   = 'Windows Server 2008'
    'Windows2008R2Forest' = 'Windows Server 2008 R2'
    'Windows2012Forest'   = 'Windows Server 2012'
    'Windows2012R2Forest' = 'Windows Server 2012 R2'
    'Windows2016Forest'   = 'Windows Server 2016'
}

try {
    Write-Verbose "[OPS-011] Querying forest: $forestName"
    $forestObj = Get-ADForest -Identity $forestName -ErrorAction Stop
    $forestMode = $forestObj.ForestMode.ToString()

    $friendlyName = $forestModeNames[$forestMode]
    if ([string]::IsNullOrEmpty($friendlyName)) {
        $friendlyName = $forestMode
    }

    $modeLevel = $forestModeOrder[$forestMode]
    $isCurrentLevel = $false
    if ($null -ne $modeLevel -and $modeLevel -ge 6) {
        $isCurrentLevel = $true
    }

    if ($isCurrentLevel) {
        $results += [PSCustomObject]@{
            ForestName        = $forestName
            ForestMode        = $forestMode
            ForestModeVersion = $friendlyName
            IsCurrentLevel    = $true
            IsHealthy         = $true
            HasIssue          = $false
            Status            = 'Pass'
            Severity          = 'Info'
            Message           = "Forest functional level is $friendlyName - meets the Windows Server 2016 baseline."
        }
    } else {
        $results += [PSCustomObject]@{
            ForestName        = $forestName
            ForestMode        = $forestMode
            ForestModeVersion = $friendlyName
            IsCurrentLevel    = $false
            IsHealthy         = $false
            HasIssue          = $true
            Status            = 'Warning'
            Severity          = 'Low'
            Message           = "Forest functional level is $friendlyName - below Windows Server 2016. Modern features such as AD Recycle Bin and PAM may not be available."
        }
    }
}
catch {
    $results += [PSCustomObject]@{
        ForestName        = $forestName
        ForestMode        = 'Unknown'
        ForestModeVersion = 'Unknown'
        IsCurrentLevel    = $false
        IsHealthy         = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        Message           = "Failed to check forest functional level for $forestName - $_"
    }
}

Write-Verbose "[OPS-011] Check complete."
return $results
