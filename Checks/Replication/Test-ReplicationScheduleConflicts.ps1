<#
.SYNOPSIS
    Replication Schedule Conflicts Check (REP-014)
.DESCRIPTION
    Checks site link replication schedules for restrictions that block replication
    during business hours or provide insufficient replication windows. A site link
    with no schedule set replicates 24/7 (healthy). Restricted schedules with less
    than 50% availability are flagged.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: REP-014
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

Write-Verbose "[REP-014] Starting replication schedule conflict check..."

try {
    $forestName = $Inventory.ForestInfo.Name
    $forestDN   = 'DC=' + ($forestName -replace '\.', ',DC=')

    Write-Verbose "[REP-014] Querying site links with schedule from: $forestName"

    try {
        $siteLinks = @(Get-ADObject -Filter { objectClass -eq 'siteLink' } `
            -SearchBase "CN=Sites,CN=Configuration,$forestDN" `
            -Properties schedule, replInterval `
            -Server $forestName -ErrorAction Stop)
    }
    catch {
        Write-Warning "[REP-014] Failed to query site links: $_"
        return @([PSCustomObject]@{
            SiteLinkName        = 'Unknown'
            ScheduleRestricted  = $false
            WindowsPerDay       = 0
            AvailabilityPercent = 0
            IsHealthy           = $false
            HasIssue            = $true
            Status              = 'Error'
            Severity            = 'Error'
            Message             = "Failed to query site links: $_"
        })
    }

    if (@($siteLinks).Count -eq 0) {
        return @([PSCustomObject]@{
            SiteLinkName        = 'N/A'
            ScheduleRestricted  = $false
            WindowsPerDay       = 96
            AvailabilityPercent = 100
            IsHealthy           = $true
            HasIssue            = $false
            Status              = 'Pass'
            Severity            = 'Info'
            Message             = 'No site links found to evaluate'
        })
    }

    foreach ($sl in $siteLinks) {
        $scheduleRestricted  = $false
        $windowsPerDay       = 96   # 24h * 4 (15-min intervals) = 96 slots/day = 100% available
        $availabilityPercent = 100

        if ($sl.schedule -and @($sl.schedule).Count -gt 0) {
            # The schedule is a 188-byte array. Bytes 0-3 are header.
            # Bytes 4-187 represent 7 days * 24 hours * 4 quarter-hours = 672 quarter-hour slots
            # But typically the array is 168 bytes (7 days * 24 hours) where each byte encodes
            # 4 quarter-hour availability slots as bit flags (bits 0-3 for each 15-min window).
            # We check the ratio of non-zero availability bytes.
            $schedBytesRaw = @($sl.schedule)

            # Skip the 4-byte header if present
            $headerOffset = 0
            if ($schedBytesRaw.Count -eq 188) { $headerOffset = 4 }
            elseif ($schedBytesRaw.Count -eq 168) { $headerOffset = 0 }

            $schedBytes = $schedBytesRaw[$headerOffset..($schedBytesRaw.Count - 1)]

            # Count available 15-min slots (each byte has up to 4 bits for 4 quarter-hours)
            $totalSlots     = 0
            $availableSlots = 0
            foreach ($b in $schedBytes) {
                for ($bit = 0; $bit -lt 4; $bit++) {
                    $totalSlots++
                    if ($b -band (1 -shl $bit)) { $availableSlots++ }
                }
            }

            if ($totalSlots -gt 0) {
                $availabilityPercent = [math]::Round(($availableSlots / $totalSlots) * 100, 1)
                $windowsPerDay       = [math]::Round($availableSlots / 7, 1)  # avg per day
                $scheduleRestricted  = $availabilityPercent -lt 100
            }
        }

        $hasIssue = $scheduleRestricted -and $availabilityPercent -lt 50
        $severity = if ($hasIssue -and $availabilityPercent -lt 25) { 'High' }
                    elseif ($hasIssue) { 'Medium' }
                    else { 'Info' }
        $status   = if ($hasIssue) { 'Warning' } else { 'Healthy' }

        $results += [PSCustomObject]@{
            SiteLinkName        = $sl.Name
            ScheduleRestricted  = $scheduleRestricted
            WindowsPerDay       = $windowsPerDay
            AvailabilityPercent = $availabilityPercent
            IsHealthy           = -not $hasIssue
            HasIssue            = $hasIssue
            Status              = $status
            Severity            = $severity
            Message             = if (-not $scheduleRestricted) {
                "Site link '$($sl.Name)' has no schedule restriction - replication available 24/7"
            } elseif ($hasIssue) {
                "Site link '$($sl.Name)' has heavily restricted schedule: only $availabilityPercent% availability (~$windowsPerDay windows/day)"
            } else {
                "Site link '$($sl.Name)' has a custom schedule with $availabilityPercent% availability"
            }
        }
    }

    Write-Verbose "[REP-014] Check complete. Site links evaluated: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[REP-014] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        SiteLinkName        = 'Unknown'
        ScheduleRestricted  = $false
        WindowsPerDay       = 0
        AvailabilityPercent = 0
        IsHealthy           = $false
        HasIssue            = $true
        Status              = 'Error'
        Severity            = 'Error'
        Message             = "Check execution failed: $($_.Exception.Message)"
    })
}
