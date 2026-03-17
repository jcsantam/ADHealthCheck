<#
.SYNOPSIS
    Garbage Collection Interval Check (OPS-009)

.DESCRIPTION
    Checks the AD garbage collection interval and tombstone lifetime settings.
    Infrequent garbage collection allows deleted objects to accumulate and bloat
    the AD database. Reads from the Directory Service configuration object.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-009
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

Write-Verbose "[OPS-009] Starting garbage collection interval check..."

$forestName = $Inventory.ForestInfo.Name

if ([string]::IsNullOrEmpty($forestName)) {
    return @([PSCustomObject]@{
        ForestName           = 'Unknown'
        GarbageCollPeriod    = $null
        TombstoneLifetime    = $null
        IsHealthy            = $false
        HasIssue             = $true
        Status               = 'Error'
        Severity             = 'Error'
        Message              = 'Could not determine forest name from inventory'
    })
}

try {
    $forestDN = 'DC=' + $forestName.Replace('.', ',DC=')

    $dsPath = "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$forestDN"
    Write-Verbose "[OPS-009] Querying Directory Service object: $dsPath"

    $dsObject = Get-ADObject -Identity $dsPath -Properties garbageCollPeriod, tombstoneLifetime -Server $forestName -ErrorAction Stop

    $gcPeriod  = $dsObject.garbageCollPeriod
    $tombstone = $dsObject.tombstoneLifetime

    # Null or 0 means default of 12 hours - treat as pass
    $effectiveGC = $gcPeriod
    if ($null -eq $gcPeriod -or $gcPeriod -eq 0) {
        $effectiveGC = 12
    }

    if ($effectiveGC -gt 24) {
        $results += [PSCustomObject]@{
            ForestName        = $forestName
            GarbageCollPeriod = $gcPeriod
            TombstoneLifetime = $tombstone
            IsHealthy         = $false
            HasIssue          = $true
            Status            = 'Warning'
            Severity          = 'Low'
            Message           = "Garbage collection interval is $effectiveGC hours (recommended: 12). Deleted objects may accumulate."
        }
    } else {
        $displayGC = $gcPeriod
        if ($null -eq $gcPeriod -or $gcPeriod -eq 0) {
            $displayGC = '12 (default)'
        }
        $results += [PSCustomObject]@{
            ForestName        = $forestName
            GarbageCollPeriod = $gcPeriod
            TombstoneLifetime = $tombstone
            IsHealthy         = $true
            HasIssue          = $false
            Status            = 'Pass'
            Severity          = 'Info'
            Message           = "Garbage collection interval is within acceptable range ($displayGC hours). Tombstone lifetime: $tombstone days."
        }
    }
}
catch {
    $results += [PSCustomObject]@{
        ForestName        = $forestName
        GarbageCollPeriod = $null
        TombstoneLifetime = $null
        IsHealthy         = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        Message           = "Failed to check garbage collection settings for $forestName - $_"
    }
}

Write-Verbose "[OPS-009] Check complete."
return $results
