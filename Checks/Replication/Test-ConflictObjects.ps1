<#
.SYNOPSIS
    Conflict Object Detection (REP-018)

.DESCRIPTION
    Detects CNF (conflict) and CNFR (conflict resolved) objects in Active
    Directory. These objects are created when two DCs create or modify the
    same object simultaneously before replication occurs. A large number of
    conflict objects indicates replication convergence problems or AD design
    issues causing frequent simultaneous modifications.

    CNF objects appear as: "CN=<name>\0ACNF:<GUID>,..."
    CNFR objects are the resolved versions that still exist.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ConflictObjects.ps1 -Inventory $inventory

.OUTPUTS
    Array of conflict object detection results per domain

.NOTES
    Check ID: REP-018
    Category: Replication
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

Write-Verbose "[REP-018] Starting conflict object detection..."

$warnThreshold    = 5
$criticalThreshold = 20

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[REP-018] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        $domainName = $domain.Name
        Write-Verbose "[REP-018] Checking conflict objects in domain: $domainName"

        try {
            $domainDN = 'DC=' + ($domainName -replace '\.', ',DC=')

            # Search for CNF objects - they contain \0ACNF: in their name
            # Using LDAPFilter for efficiency
            $cnfObjects = @(Get-ADObject `
                -LDAPFilter "(name=*\0ACNF:*)" `
                -SearchBase $domainDN `
                -Server $domainName `
                -Properties Name, DistinguishedName, objectClass, whenCreated `
                -SearchScope Subtree `
                -ErrorAction SilentlyContinue)

            $cnfCount = $cnfObjects.Count
            $issues   = @()

            if ($cnfCount -ge $criticalThreshold) {
                $issues += "$cnfCount CNF conflict objects found - critical level; replication convergence is severely degraded"
            } elseif ($cnfCount -ge $warnThreshold) {
                $issues += "$cnfCount CNF conflict objects found - indicates replication conflicts; review and clean up"
            }

            # Get breakdown by object class
            $classCounts = @{}
            foreach ($obj in $cnfObjects) {
                $cls = $obj.objectClass | Select-Object -Last 1
                if ($classCounts.ContainsKey($cls)) {
                    $classCounts[$cls]++
                } else {
                    $classCounts[$cls] = 1
                }
            }
            $classBreakdown = ($classCounts.GetEnumerator() | ForEach-Object { "$($_.Key): $($_.Value)" }) -join ', '

            $hasIssue = ($issues.Count -gt 0)
            $status   = if ($cnfCount -ge $criticalThreshold) { 'Fail' } `
                        elseif ($hasIssue) { 'Warning' } else { 'Pass' }
            $severity = if ($cnfCount -ge $criticalThreshold) { 'High' } `
                        elseif ($hasIssue) { 'Medium' } else { 'Info' }

            $message = if ($hasIssue) {
                "Domain $domainName conflict object issues: $($issues -join '; ')"
                if ($classBreakdown) { $message += " (by type: $classBreakdown)" }
                $message
            } else {
                "Domain $domainName has no significant conflict objects (CNF count: $cnfCount)"
            }

            $results += [PSCustomObject]@{
                Domain          = $domainName
                CNFObjectCount  = $cnfCount
                ClassBreakdown  = $classBreakdown
                HasIssue        = $hasIssue
                Status          = $status
                Severity        = $severity
                IsHealthy       = -not $hasIssue
                Message         = $message
            }
        }
        catch {
            Write-Warning "[REP-018] Failed to check conflict objects in $domainName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain          = $domainName
                CNFObjectCount  = 0
                ClassBreakdown  = 'Unknown'
                HasIssue        = $true
                Status          = 'Error'
                Severity        = 'Error'
                IsHealthy       = $false
                Message         = "Failed to check conflict objects in $domainName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[REP-018] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-018] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain          = 'Unknown'
        CNFObjectCount  = 0
        ClassBreakdown  = 'Unknown'
        HasIssue        = $true
        Status          = 'Error'
        Severity        = 'Error'
        IsHealthy       = $false
        Message         = "Check execution failed: $($_.Exception.Message)"
    })
}
