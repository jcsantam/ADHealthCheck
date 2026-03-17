<#
.SYNOPSIS
    Deleted Object Accumulation Check (DB-007)

.DESCRIPTION
    Counts tombstoned (deleted) objects in Active Directory and checks whether
    accumulation is unusually high. Excessive deleted objects indicate:
    - A large bulk deletion event that may warrant investigation
    - AD Recycle Bin not enabled (objects remain as tombstones for 180 days)
    - Objects approaching tombstone lifetime without cleanup

    Also checks the tombstone lifetime setting and flags if it is set too low
    (below 60 days) which could cause replication inconsistencies (USN rollback
    scenarios) if a DC is restored from backup.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-DeletedObjectAccumulation.ps1 -Inventory $inventory

.OUTPUTS
    Array of deleted object accumulation results per domain

.NOTES
    Check ID: DB-007
    Category: Database
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

Write-Verbose "[DB-007] Starting deleted object accumulation check..."

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[DB-007] No domains found in inventory"
        return @()
    }

    # Get tombstone lifetime from forest configuration
    $forestRoot = $null
    $tombstoneDays = 180  # default
    if ($Inventory.ForestInfo -and $Inventory.ForestInfo.RootDomain) {
        $forestRoot = $Inventory.ForestInfo.RootDomain
    }
    else {
        $forestRoot = $domains[0].Name
    }

    $forestRootDN = 'DC=' + ($forestRoot -replace '\.', ',DC=')

    try {
        $configNC    = "CN=Configuration,$forestRootDN"
        $tombstoneObj = Get-ADObject -Identity "CN=Directory Service,CN=Windows NT,CN=Services,$configNC" `
            -Server $forestRoot `
            -Properties tombstoneLifetime `
            -ErrorAction SilentlyContinue

        if ($tombstoneObj -and $tombstoneObj.tombstoneLifetime) {
            $tombstoneDays = [int]$tombstoneObj.tombstoneLifetime
        }
    }
    catch {
        Write-Verbose "[DB-007] Could not read tombstone lifetime: $($_.Exception.Message)"
    }

    Write-Verbose "[DB-007] Tombstone lifetime: $tombstoneDays days"

    foreach ($domain in $domains) {
        $domainName = $domain.Name
        $domainDN   = 'DC=' + ($domainName -replace '\.', ',DC=')

        Write-Verbose "[DB-007] Checking deleted objects in domain: $domainName"

        try {
            # Count objects in the Deleted Objects container
            $deletedObjectsDN = "CN=Deleted Objects,$domainDN"

            $deletedCount = 0
            $recentDeletedCount = 0  # deleted in last 30 days
            $thirtyDaysAgo = (Get-Date).AddDays(-30)

            try {
                $deletedObjects = @(Get-ADObject -SearchBase $deletedObjectsDN `
                    -Filter { isDeleted -eq $true } `
                    -Server $domainName `
                    -IncludeDeletedObjects `
                    -Properties whenChanged, objectClass `
                    -SearchScope OneLevel `
                    -ErrorAction SilentlyContinue)

                $deletedCount = $deletedObjects.Count

                # Count recently deleted
                $recentDeletedCount = @($deletedObjects | Where-Object {
                    $_.whenChanged -and $_.whenChanged -gt $thirtyDaysAgo
                }).Count

                Write-Verbose "[DB-007] $domainName`: $deletedCount total deleted, $recentDeletedCount in last 30 days"
            }
            catch {
                Write-Verbose "[DB-007] Could not enumerate Deleted Objects container in $domainName`: $($_.Exception.Message)"
                # Try alternate approach - search entire domain for deleted objects
                try {
                    $deletedObjects = @(Get-ADObject -Filter { isDeleted -eq $true } `
                        -Server $domainName `
                        -SearchBase $domainDN `
                        -IncludeDeletedObjects `
                        -Properties whenChanged `
                        -ErrorAction SilentlyContinue)
                    $deletedCount = $deletedObjects.Count
                    $recentDeletedCount = @($deletedObjects | Where-Object {
                        $_.whenChanged -and $_.whenChanged -gt $thirtyDaysAgo
                    }).Count
                }
                catch {
                    Write-Verbose "[DB-007] Alternate deleted objects query also failed"
                }
            }

            $hasIssue = $false
            $status   = 'Pass'
            $severity = 'Info'
            $message  = ''

            # Flag if tombstone lifetime is too low
            $tombstoneLow = ($tombstoneDays -lt 60)

            if ($tombstoneLow) {
                $hasIssue = $true
                $status   = 'Fail'
                $severity = 'High'
                $message  = "Domain $domainName tombstone lifetime is $tombstoneDays days (recommended minimum: 60 days) - risk of replication inconsistency if DC is restored from old backup. Deleted objects: $deletedCount total, $recentDeletedCount in last 30 days"
            }
            elseif ($recentDeletedCount -gt 500) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'High'
                $message  = "$recentDeletedCount objects deleted in last 30 days in $domainName - large deletion event; verify this was intentional. Total tombstoned: $deletedCount"
            }
            elseif ($deletedCount -gt 10000) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'Medium'
                $message  = "Domain $domainName has $deletedCount tombstoned objects - high accumulation; consider enabling AD Recycle Bin or investigating deletion patterns"
            }
            else {
                $message = "Domain $domainName has $deletedCount tombstoned objects ($recentDeletedCount in last 30 days) - within normal range. Tombstone lifetime: $tombstoneDays days"
            }

            $results += [PSCustomObject]@{
                Domain               = $domainName
                DeletedCount         = $deletedCount
                RecentDeletedCount   = $recentDeletedCount
                TombstoneDays        = $tombstoneDays
                TombstoneTooLow      = $tombstoneLow
                HasIssue             = $hasIssue
                Status               = $status
                Severity             = $severity
                IsHealthy            = -not $hasIssue
                Message              = $message
            }
        }
        catch {
            Write-Warning "[DB-007] Failed to check deleted objects in $domainName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain               = $domainName
                DeletedCount         = 0
                RecentDeletedCount   = 0
                TombstoneDays        = $tombstoneDays
                TombstoneTooLow      = $false
                HasIssue             = $true
                Status               = 'Error'
                Severity             = 'Error'
                IsHealthy            = $false
                Message              = "Failed to check deleted objects in $domainName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DB-007] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DB-007] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain               = 'Unknown'
        DeletedCount         = 0
        RecentDeletedCount   = 0
        TombstoneDays        = 0
        TombstoneTooLow      = $false
        HasIssue             = $true
        Status               = 'Error'
        Severity             = 'Error'
        IsHealthy            = $false
        Message              = "Check execution failed: $($_.Exception.Message)"
    })
}
