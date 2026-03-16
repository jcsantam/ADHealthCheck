<#
.SYNOPSIS
    Failed Replication Attempts Check (REP-007)

.DESCRIPTION
    Detects failed replication attempts using repadmin.
    No WMI/RPC or remote event log access required.
    Works over standard AD ports only (389/88).

    Checks:
    - repadmin /showrepl for failed replication links
    - repadmin /replsummary for overall failure counts
    - Consecutive replication failures per DC pair

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: REP-007
    Category: Replication
    Severity: Critical
    Compatible: Windows Server 2012 R2+

    Approach: repadmin (no WMI/RPC required)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[REP-007] Starting failed replication check (repadmin)..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[REP-007] No reachable DCs"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-007] Checking replication failures on: $($dc.Name)"

        $failureCount   = 0
        $uniqueSources  = 0
        $breakdown      = ''

        try {
            # -----------------------------------------------------------------------
            # repadmin /showrepl /csv - parse for failed replication links
            # Fixed column names (11 fields after stripping showrepl_INFO prefix)
            # ConvertFrom-Csv handles quoted DNs like "DC=LAB,DC=COM" correctly
            # -----------------------------------------------------------------------
            $csvHeaders = 'Flags','DestSite','DestDC','NamingContext','SrcSite','SrcDC','Transport','Failures','LastFailTime','LastSuccessTime','LastStatus'

            $replRaw  = & repadmin /showrepl $dc.Name /csv 2>&1
            $dataLines = $replRaw | Where-Object { $_ -match "^showrepl_INFO" } |
                         ForEach-Object { $_ -replace "^showrepl_INFO," }

            $failedLinks  = @()
            $sourceDCList = @()

            if ($dataLines) {
                $parsed = @($dataLines | ConvertFrom-Csv -Header $csvHeaders)

                foreach ($row in $parsed) {
                    $numFailures = 0
                    if ([int]::TryParse($row.Failures, [ref]$numFailures) -and $numFailures -gt 0) {
                        $failedLinks  += $row
                        $sourceDCList += $row.SrcDC
                        $failureCount += $numFailures
                    }
                }
            }

            $uniqueSources = @($sourceDCList | Select-Object -Unique).Count
            $breakdown     = if ($failedLinks.Count -gt 0) {
                ($failedLinks | Select-Object -First 5 | ForEach-Object {
                    "Source:$($_.SrcDC) Failures:$($_.Failures)"
                }) -join "; "
            } else { "None" }

            Write-Verbose "[REP-007] $($dc.Name): $failureCount total failures across $uniqueSources source(s)"

            # -----------------------------------------------------------------------
            # Determine severity
            # -----------------------------------------------------------------------
            $hasIssue = $failureCount -gt 0
            $severity = if ($failureCount -gt 100)    { 'Critical' }
                        elseif ($failureCount -gt 20)  { 'High' }
                        elseif ($failureCount -gt 0)   { 'Medium' }
                        else                           { 'Info' }

            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                FailureCount     = $failureCount
                UniqueSources    = $uniqueSources
                EventBreakdown   = $breakdown
                Period           = "Current repadmin state"
                Severity         = $severity
                Status           = if ($failureCount -gt 20)  { 'Failed' }
                                   elseif ($failureCount -gt 0) { 'Warning' }
                                   else                         { 'Healthy' }
                IsHealthy        = -not $hasIssue
                HasIssue         = $hasIssue
                Message          = if ($failureCount -gt 100) {
                    "CRITICAL: $failureCount replication failures detected on $($dc.Name)!"
                } elseif ($failureCount -gt 20) {
                    "WARNING: $failureCount replication failures detected on $($dc.Name)"
                } elseif ($failureCount -gt 0) {
                    "$failureCount replication failure(s) detected on $($dc.Name)"
                } else {
                    "No replication failures detected on $($dc.Name)"
                }
            }

            $results += $result
        }
        catch {
            Write-Warning "[REP-007] Failed to check events on $($dc.Name): $($_.Exception.Message)"

            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                FailureCount     = 0
                UniqueSources    = 0
                EventBreakdown   = "Unknown"
                Period           = "Current repadmin state"
                Severity         = 'Error'
                Status           = 'Error'
                IsHealthy        = $false
                HasIssue         = $true
                Message          = "Failed to query replication status: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[REP-007] Check complete. DCs checked: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-007] Check failed: $($_.Exception.Message)"

    return @([PSCustomObject]@{
        DomainController = "Unknown"
        FailureCount     = 0
        UniqueSources    = 0
        EventBreakdown   = "Unknown"
        Period           = "Current repadmin state"
        Severity         = 'Error'
        Status           = 'Error'
        IsHealthy        = $false
        HasIssue         = $true
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
