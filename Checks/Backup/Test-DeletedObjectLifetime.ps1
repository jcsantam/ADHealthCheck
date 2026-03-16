<#
.SYNOPSIS
    Deleted Object Lifetime Check (BACKUP-004)
.DESCRIPTION
    Checks AD tombstone lifetime and deleted object lifetime settings.
    The tombstone lifetime determines how long deleted objects remain before
    permanent removal. Microsoft recommends at least 180 days. Values below
    60 days are critical as they may prevent proper recovery from backup.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: BACKUP-004
    Category: Backup
    Severity: High
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

$criticalThreshold = 60    # days - below this is critical
$warningThreshold  = 180   # days - below this is a warning

Write-Verbose "[BACKUP-004] Starting deleted object lifetime check..."

try {
    $forestName = $Inventory.ForestInfo.Name
    $forestDN   = 'DC=' + ($forestName -replace '\.', ',DC=')

    Write-Verbose "[BACKUP-004] Querying tombstone lifetime for forest: $forestName"

    $dsServiceDN = "CN=Directory Service,CN=Windows NT,CN=Services,CN=Configuration,$forestDN"

    try {
        $dsObject = Get-ADObject -Identity $dsServiceDN `
            -Properties tombstoneLifetime, 'msDS-DeletedObjectLifetime' `
            -Server $forestName -ErrorAction Stop
    }
    catch {
        Write-Warning "[BACKUP-004] Failed to query Directory Service object: $_"
        return @([PSCustomObject]@{
            ForestName                 = $forestName
            TombstoneLifetimeDays      = 0
            DeletedObjectLifetimeDays  = 0
            IsDefault60Days            = $false
            MeetsRecommendation        = $false
            IsHealthy                  = $false
            HasIssue                   = $true
            Status                     = 'Error'
            Severity                   = 'Error'
            Message                    = "Failed to query tombstone lifetime: $_"
        })
    }

    # tombstoneLifetime: if null/0, the default applies (60 days on old AD, 180 on newer)
    # We treat null as 60 days (conservative - older default)
    $tombstoneLifetime = if ($dsObject.tombstoneLifetime) {
        [int]$dsObject.tombstoneLifetime
    } else {
        60  # Older AD default
    }

    # msDS-DeletedObjectLifetime: if set, overrides for recycle bin objects
    $deletedObjLifetime = if ($dsObject.'msDS-DeletedObjectLifetime') {
        [int]$dsObject.'msDS-DeletedObjectLifetime'
    } else {
        $tombstoneLifetime  # Falls back to tombstoneLifetime
    }

    $isDefault60Days    = $tombstoneLifetime -eq 60
    $meetsRecommendation = $tombstoneLifetime -ge $warningThreshold

    $hasIssue = $tombstoneLifetime -lt $warningThreshold
    $severity = if ($tombstoneLifetime -lt $criticalThreshold) { 'Critical' }
                elseif ($tombstoneLifetime -lt $warningThreshold) { 'High' }
                else { 'Info' }
    $status   = if ($tombstoneLifetime -lt $criticalThreshold) { 'Fail' }
                elseif ($tombstoneLifetime -lt $warningThreshold) { 'Warning' }
                else { 'Healthy' }

    $results += [PSCustomObject]@{
        ForestName                = $forestName
        TombstoneLifetimeDays     = $tombstoneLifetime
        DeletedObjectLifetimeDays = $deletedObjLifetime
        IsDefault60Days           = $isDefault60Days
        MeetsRecommendation       = $meetsRecommendation
        CriticalThreshold         = $criticalThreshold
        WarningThreshold          = $warningThreshold
        IsHealthy                 = -not $hasIssue
        HasIssue                  = $hasIssue
        Status                    = $status
        Severity                  = $severity
        Message                   = if ($tombstoneLifetime -lt $criticalThreshold) {
            "CRITICAL: Tombstone lifetime is $tombstoneLifetime days (minimum recommended: $criticalThreshold days)"
        } elseif ($tombstoneLifetime -lt $warningThreshold) {
            "WARNING: Tombstone lifetime is $tombstoneLifetime days (Microsoft recommends: $warningThreshold days)"
        } else {
            "Tombstone lifetime is $tombstoneLifetime days - meets Microsoft recommendation of $warningThreshold days"
        }
    }

    Write-Verbose "[BACKUP-004] Check complete. TombstoneLifetime: $tombstoneLifetime days"
    return $results
}
catch {
    Write-Error "[BACKUP-004] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        ForestName                = 'Unknown'
        TombstoneLifetimeDays     = 0
        DeletedObjectLifetimeDays = 0
        IsDefault60Days           = $false
        MeetsRecommendation       = $false
        CriticalThreshold         = $criticalThreshold
        WarningThreshold          = $warningThreshold
        IsHealthy                 = $false
        HasIssue                  = $true
        Status                    = 'Error'
        Severity                  = 'Error'
        Message                   = "Check execution failed: $($_.Exception.Message)"
    })
}
