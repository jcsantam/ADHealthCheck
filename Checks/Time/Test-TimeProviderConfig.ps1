<#
.SYNOPSIS
    Time Provider Configuration Check (TIME-004)

.DESCRIPTION
    Validates W32Time provider configuration for all domain controllers.
    The PDC Emulator should be configured as Type=NTP with AnnounceFlags=5
    (reliable time source). All other DCs should be Type=NT5DS to sync from
    the domain hierarchy.

    Checks:
    - PDC Emulator: Type should be 'NTP', AnnounceFlags should be 5
    - Non-PDC DCs: Type should be 'NT5DS'

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-TimeProviderConfig.ps1 -Inventory $inventory

.OUTPUTS
    Array of time provider configuration results per DC

.NOTES
    Check ID: TIME-004
    Category: Time
    Severity: High
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[TIME-004] Starting time provider configuration check..."

try {
    $domainControllers = $Inventory.DomainControllers
    $domains = $Inventory.Domains

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[TIME-004] No domain controllers found in inventory"
        return @()
    }

    # Build a lookup of PDC names for quick reference
    $pdcNames = @{}
    foreach ($domain in $domains) {
        $pdcNames[$domain.PDCEmulator] = $domain.Name
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[TIME-004] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        $isPDC = $pdcNames.ContainsKey($dcName)

        Write-Verbose "[TIME-004] Checking time provider config on: $dcName (IsPDC: $isPDC)"

        try {
            $w32tmConfig = w32tm /query /computer:$dcName /configuration 2>&1

            # Parse Type
            $w32TimeType = 'Unknown'
            $typeLine = $w32tmConfig | Where-Object { $_ -match '^\s*Type:' }
            if ($typeLine -match 'Type:\s*(\S+)') {
                $w32TimeType = $matches[1].Trim()
                # Strip trailing "(Local)" annotation if present
                $w32TimeType = $w32TimeType -replace '\s*\(Local\)', ''
                $w32TimeType = $w32TimeType.Trim()
            }

            # Parse AnnounceFlags
            $announceFlags = $null
            $announceLine = $w32tmConfig | Where-Object { $_ -match 'AnnounceFlags:' }
            if ($announceLine -match 'AnnounceFlags:\s*(\d+)') {
                $announceFlags = [int]$matches[1]
            }

            # Evaluate correctness
            $hasIssue = $false
            $status = 'Pass'
            $severity = 'Info'
            $message = ''
            $isCorrectType = $false

            if ($isPDC) {
                $isCorrectType = ($w32TimeType -eq 'NTP')
                $isCorrectAnnounce = ($announceFlags -eq 5)

                if (-not $isCorrectType -and ($announceFlags -ne 5)) {
                    $hasIssue = $true
                    $status = 'Fail'
                    $severity = 'High'
                    $message = "PDC $dcName has incorrect time config: Type='$w32TimeType' (expected NTP) and AnnounceFlags=$announceFlags (expected 5)"
                }
                elseif (-not $isCorrectType) {
                    $hasIssue = $true
                    $status = 'Fail'
                    $severity = 'High'
                    $message = "PDC $dcName has incorrect Type='$w32TimeType' (expected NTP)"
                }
                elseif (-not $isCorrectAnnounce) {
                    $hasIssue = $true
                    $status = 'Fail'
                    $severity = 'High'
                    $message = "PDC $dcName has AnnounceFlags=$announceFlags (expected 5 for reliable time source)"
                }
                else {
                    $message = "PDC $dcName is correctly configured: Type=NTP, AnnounceFlags=5"
                }
            }
            else {
                $isCorrectType = ($w32TimeType -eq 'NT5DS')

                if (-not $isCorrectType) {
                    $hasIssue = $true
                    $status = 'Fail'
                    $severity = 'Medium'
                    $message = "DC $dcName has incorrect Type='$w32TimeType' (expected NT5DS for domain sync)"
                }
                else {
                    $message = "DC $dcName is correctly configured: Type=NT5DS"
                }
            }

            $results += [PSCustomObject]@{
                DomainController = $dcName
                IsPDC            = $isPDC
                W32TimeType      = $w32TimeType
                AnnounceFlags    = $announceFlags
                IsCorrectType    = $isCorrectType
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                IsHealthy        = -not $hasIssue
                Message          = $message
            }
        }
        catch {
            Write-Warning "[TIME-004] Failed to query time config on DC ${dcName}: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController = $dcName
                IsPDC            = $isPDC
                W32TimeType      = 'Unknown'
                AnnounceFlags    = $null
                IsCorrectType    = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to query time provider configuration: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[TIME-004] Check complete. DCs checked: $($results.Count)"
    return $results
}
catch {
    Write-Error "[TIME-004] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        IsPDC            = $false
        W32TimeType      = 'Unknown'
        AnnounceFlags    = $null
        IsCorrectType    = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
