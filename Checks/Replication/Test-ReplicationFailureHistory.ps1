<#
.SYNOPSIS
    Replication Failure History (REP-021)

.DESCRIPTION
    Analyzes the pattern of consecutive replication failures per replication
    partnership. Unlike a point-in-time check, this detects partnerships that
    have been failing for an extended period by examining consecutive failure
    counts from repadmin output.

    Consecutive failure counts indicate:
    - 1-5:   Transient issue (warning)
    - 6-10:  Persistent issue (fail)
    - 10+:   Critical - replication may be tombstoned

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ReplicationFailureHistory.ps1 -Inventory $inventory

.OUTPUTS
    Array of replication failure history results per DC/partner pair

.NOTES
    Check ID: REP-021
    Category: Replication
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

Write-Verbose "[REP-021] Starting replication failure history analysis..."

try {
    $domainControllers = $Inventory.DomainControllers
    $reachableDCs      = @($domainControllers | Where-Object { $_.IsReachable })

    $dcCount = @($domainControllers).Count
    if ($dcCount -eq 1) {
        return @([PSCustomObject]@{
            DomainController = $domainControllers[0].Name
            PartnerDC        = 'N/A'
            ConsecFailures   = 0
            LastFailure      = 'N/A'
            HasIssue         = $false
            Status           = 'Pass'
            Severity         = 'Info'
            IsHealthy        = $true
            Message          = "Single-DC environment - replication failure history not applicable"
        })
    }

    $anyFailureFound = $false

    foreach ($dc in $reachableDCs) {
        $dcName = $dc.Name
        Write-Verbose "[REP-021] Analyzing failure history on: $dcName"

        try {
            $replOutput = & repadmin /showrepl $dcName /csv 2>$null
            if (-not $replOutput) { continue }

            $lines = $replOutput | Select-Object -Skip 1

            foreach ($line in $lines) {
                if (-not $line -or $line.Trim() -eq '') { continue }
                $cols = $line -split ','
                # CSV columns: ShowRepl_CSV,DestSite,DestDSA,NC,SrcSite,SrcDSA,Transport,NumFail,LastFailTime,LastFailStatus,LastSuccessTime
                if ($cols.Count -lt 11) { continue }

                $sourceDC    = ($cols[5] -replace '"', '').Trim()
                $lastFailure = ($cols[8] -replace '"', '').Trim()
                $failCount   = 0
                $rawFail     = ($cols[7] -replace '"', '').Trim()
                if ($rawFail -match '^\d+$') { $failCount = [int]$rawFail }
                $lastError = ($cols[9] -replace '"', '').Trim()

                if (-not $sourceDC -or $failCount -eq 0) { continue }

                $anyFailureFound = $true

                $status   = if ($failCount -ge 10) { 'Fail' } elseif ($failCount -ge 6) { 'Fail' } else { 'Warning' }
                $severity = if ($failCount -ge 10) { 'Critical' } elseif ($failCount -ge 6) { 'High' } else { 'Medium' }

                $message = "DC $dcName replication from $sourceDC has $failCount consecutive failure(s)"
                if ($lastFailure) { $message += " (last failure: $lastFailure)" }
                if ($lastError)   { $message += " - Error: $lastError" }
                if ($failCount -ge 10) {
                    $message += " - CRITICAL: partition may approach tombstone lifetime"
                }

                $results += [PSCustomObject]@{
                    DomainController = $dcName
                    PartnerDC        = $sourceDC
                    ConsecFailures   = $failCount
                    LastFailure      = $lastFailure
                    LastError        = $lastError
                    HasIssue         = $true
                    Status           = $status
                    Severity         = $severity
                    IsHealthy        = $false
                    Message          = $message
                }
            }
        }
        catch {
            Write-Warning "[REP-021] Failed to analyze failure history on $dcName`: $($_.Exception.Message)"
        }
    }

    if ($results.Count -eq 0) {
        $results += [PSCustomObject]@{
            DomainController = 'All DCs'
            PartnerDC        = 'N/A'
            ConsecFailures   = 0
            LastFailure      = 'N/A'
            LastError        = ''
            HasIssue         = $false
            Status           = 'Pass'
            Severity         = 'Info'
            IsHealthy        = $true
            Message          = "No consecutive replication failures detected across all DC partnerships"
        }
    }

    Write-Verbose "[REP-021] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-021] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        PartnerDC        = 'Unknown'
        ConsecFailures   = 0
        LastFailure      = 'Unknown'
        LastError        = ''
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
