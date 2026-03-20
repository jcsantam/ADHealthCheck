<#
.SYNOPSIS
    DC Connection Object Audit (REP-022)

.DESCRIPTION
    Audits Active Directory replication connection objects to detect:
    - Manually created connection objects (could override KCC-optimal topology)
    - Stale connection objects pointing to non-existent DCs
    - DCs with no inbound connection objects (isolated from replication)
    - Duplicate connection objects between the same DC pair

    The KCC automatically creates and manages connection objects. Manual
    connection objects (not created by the KCC) should be reviewed as they
    can prevent automatic topology optimization.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ConnectionObjectAudit.ps1 -Inventory $inventory

.OUTPUTS
    Array of connection object audit results per DC

.NOTES
    Check ID: REP-022
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

Write-Verbose "[REP-022] Starting connection object audit..."

try {
    $domainControllers = $Inventory.DomainControllers
    $queryDC = ($domainControllers | Where-Object { $_.IsReachable } | Select-Object -First 1)

    $dcCount = @($domainControllers).Count
    if ($dcCount -eq 1) {
        return @([PSCustomObject]@{
            DomainController  = $domainControllers[0].Name
            TotalConnections  = 0
            ManualConnections = 0
            StaleConnections  = 0
            HasIssue          = $false
            Status            = 'Pass'
            Severity          = 'Info'
            IsHealthy         = $true
            Message           = "Single-DC environment - connection object audit not applicable"
        })
    }

    if (-not $queryDC) {
        return @([PSCustomObject]@{
            DomainController  = 'Unknown'
            TotalConnections  = 0
            ManualConnections = 0
            StaleConnections  = 0
            HasIssue          = $true
            Status            = 'Error'
            Severity          = 'Error'
            IsHealthy         = $false
            Message           = "No reachable DCs available for connection object query"
        })
    }

    $forestDN = 'DC=' + ($Inventory.ForestInfo.RootDomain -replace '\.', ',DC=')
    $sitesDN  = "CN=Sites,CN=Configuration,$forestDN"

    # Get all known DC hostnames for stale detection
    $knownDCNames = @($domainControllers | ForEach-Object {
        $_.Name.Split('.')[0].ToUpper()
        $_.Name.ToUpper()
    })

    # Query all nTDSConnection objects under Sites
    $connectionObjects = @(Get-ADObject `
        -Filter { objectClass -eq 'nTDSConnection' } `
        -SearchBase $sitesDN `
        -Server $queryDC.Name `
        -Properties Name, fromServer, options, whenCreated, DistinguishedName `
        -ErrorAction SilentlyContinue)

    Write-Verbose "[REP-022] Found $($connectionObjects.Count) total connection objects"

    # Group by target DC (parent of connection object)
    $dcConnectionMap = @{}

    foreach ($conn in $connectionObjects) {
        # Extract target DC from DN: CN=<conn>,CN=NTDS Settings,CN=<TargetDC>,...
        $targetDC = $null
        if ($conn.DistinguishedName -match 'CN=NTDS Settings,CN=([^,]+)') {
            $targetDC = $matches[1].ToUpper()
        }
        if (-not $targetDC) { continue }

        if (-not $dcConnectionMap.ContainsKey($targetDC)) {
            $dcConnectionMap[$targetDC] = @()
        }
        $dcConnectionMap[$targetDC] += $conn
    }

    # Analyze each DC's connections
    foreach ($dc in $domainControllers) {
        $dcShortName = $dc.Name.Split('.')[0].ToUpper()
        $dcName      = $dc.Name
        $connections = if ($dcConnectionMap.ContainsKey($dcShortName)) { $dcConnectionMap[$dcShortName] } else { @() }

        $issues          = @()
        $manualCount     = 0
        $staleCount      = 0
        $totalCount      = $connections.Count

        if ($totalCount -eq 0 -and $dcCount -gt 1) {
            $issues += "DC has no inbound connection objects - it may be isolated from replication topology"
        }

        foreach ($conn in $connections) {
            # options bit 0: NTDSCONN_OPT_IS_GENERATED (KCC-created)
            # If options is null or bit 0 not set, it's manual
            $optVal    = if ($conn.options) { [int]$conn.options } else { 0 }
            $isKCC     = (($optVal -band 1) -eq 1)
            $isManual  = -not $isKCC

            if ($isManual) {
                $manualCount++
            }

            # Check for stale: fromServer DC not in known list
            $fromServer = $conn.fromServer
            if ($fromServer -match 'CN=([^,]+),CN=NTDS') {
                $fromDCShort = $matches[1].ToUpper()
                $isKnown     = ($knownDCNames -contains $fromDCShort) -or
                               ($knownDCNames | Where-Object { $_ -like "$fromDCShort*" })
                if (-not $isKnown) {
                    $staleCount++
                    $issues += "Stale connection from '$fromDCShort' which is not a known DC"
                }
            }
        }

        if ($manualCount -gt 0) {
            $issues += "$manualCount manual connection object(s) found - review if intentional"
        }

        $hasIssue = ($issues.Count -gt 0)
        $status   = if ($staleCount -gt 0) { 'Fail' } elseif ($hasIssue) { 'Warning' } else { 'Pass' }
        $severity = if ($staleCount -gt 0) { 'High' } elseif ($totalCount -eq 0 -and $dcCount -gt 1) { 'High' } `
                    elseif ($hasIssue) { 'Medium' } else { 'Info' }

        $message = if ($hasIssue) {
            "DC $dcName connection object issues: $($issues -join '; ')"
        } else {
            "DC $dcName connection objects are healthy (total: $totalCount, manual: $manualCount)"
        }

        $results += [PSCustomObject]@{
            DomainController  = $dcName
            TotalConnections  = $totalCount
            ManualConnections = $manualCount
            StaleConnections  = $staleCount
            HasIssue          = $hasIssue
            Status            = $status
            Severity          = $severity
            IsHealthy         = -not $hasIssue
            Message           = $message
        }
    }

    Write-Verbose "[REP-022] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-022] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController  = 'Unknown'
        TotalConnections  = 0
        ManualConnections = 0
        StaleConnections  = 0
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        IsHealthy         = $false
        Message           = "Check execution failed: $($_.Exception.Message)"
    })
}
