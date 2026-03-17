<#
.SYNOPSIS
    Schema Version Check (OPS-010)

.DESCRIPTION
    Checks the current AD schema version (objectVersion) and maps it to a
    Windows Server release. Warns if the schema is older than Windows Server 2016,
    which may block OS upgrades or prevent use of newer AD features.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-010
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

Write-Verbose "[OPS-010] Starting schema version check..."

$forestName = $Inventory.ForestInfo.Name

if ([string]::IsNullOrEmpty($forestName)) {
    return @([PSCustomObject]@{
        ForestName         = 'Unknown'
        SchemaVersion      = $null
        SchemaVersionName  = 'Unknown'
        IsCurrentVersion   = $false
        IsHealthy          = $false
        HasIssue           = $true
        Status             = 'Error'
        Severity           = 'Error'
        Message            = 'Could not determine forest name from inventory'
    })
}

# Schema version to Windows Server mapping
$schemaVersionMap = @{
    13 = 'Windows Server 2000'
    30 = 'Windows Server 2003'
    31 = 'Windows Server 2003 R2'
    44 = 'Windows Server 2008'
    47 = 'Windows Server 2008 R2'
    56 = 'Windows Server 2012'
    69 = 'Windows Server 2012 R2'
    87 = 'Windows Server 2016'
    88 = 'Windows Server 2019'
    90 = 'Windows Server 2022'
}

$minCurrentVersion = 87

try {
    $forestDN = 'DC=' + $forestName.Replace('.', ',DC=')
    $schemaPath = "CN=Schema,CN=Configuration,$forestDN"

    Write-Verbose "[OPS-010] Querying schema NC: $schemaPath"

    $schemaObject = Get-ADObject -Identity $schemaPath -Properties objectVersion -Server $forestName -ErrorAction Stop
    $schemaVersion = $schemaObject.objectVersion

    $versionName = $schemaVersionMap[$schemaVersion]
    if ([string]::IsNullOrEmpty($versionName)) {
        $versionName = "Unknown (objectVersion=$schemaVersion)"
    }

    $isCurrentVersion = $false
    if ($schemaVersion -ge $minCurrentVersion) {
        $isCurrentVersion = $true
    }

    if ($isCurrentVersion) {
        $results += [PSCustomObject]@{
            ForestName        = $forestName
            SchemaVersion     = $schemaVersion
            SchemaVersionName = $versionName
            IsCurrentVersion  = $true
            IsHealthy         = $true
            HasIssue          = $false
            Status            = 'Pass'
            Severity          = 'Info'
            Message           = "Schema version $schemaVersion ($versionName) meets the Windows Server 2016 baseline."
        }
    } else {
        $results += [PSCustomObject]@{
            ForestName        = $forestName
            SchemaVersion     = $schemaVersion
            SchemaVersionName = $versionName
            IsCurrentVersion  = $false
            IsHealthy         = $false
            HasIssue          = $true
            Status            = 'Warning'
            Severity          = 'Low'
            Message           = "Schema version $schemaVersion ($versionName) is below Windows Server 2016 (objectVersion 87). Run adprep /forestprep to update."
        }
    }
}
catch {
    $results += [PSCustomObject]@{
        ForestName        = $forestName
        SchemaVersion     = $null
        SchemaVersionName = 'Unknown'
        IsCurrentVersion  = $false
        IsHealthy         = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        Message           = "Failed to check schema version for $forestName - $_"
    }
}

Write-Verbose "[OPS-010] Check complete."
return $results
