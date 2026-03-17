<#
.SYNOPSIS
    Reverse Lookup Zones Check (DNS-009)
.DESCRIPTION
    Checks that reverse lookup (PTR) zones exist and are AD-integrated.
    Reverse lookup zones enable IP-to-hostname resolution required by security
    tools, audit logs, and network diagnostics.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DNS-009
    Category: DNS
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

Write-Verbose "[DNS-009] Starting reverse lookup zone check..."

# Check if DnsServer module is available
if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Warning "[DNS-009] DnsServer module not available - skipping check"
    return @([PSCustomObject]@{
        DomainController         = 'N/A'
        ReverseLookupZoneCount   = 0
        HasNonIntegratedZones    = $false
        ZoneNames                = 'N/A'
        IsHealthy                = $true
        HasIssue                 = $false
        Status                   = 'Pass'
        Severity                 = 'Info'
        Message                  = 'DnsServer module not available - reverse lookup zone check skipped'
    })
}

Import-Module DnsServer -ErrorAction SilentlyContinue

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DNS-009] No reachable DCs found"
        return @()
    }

    # Check only the first reachable DC (deduplicated by design)
    $dc = $domainControllers | Select-Object -First 1
    Write-Verbose "[DNS-009] Checking reverse lookup zones on: $($dc.Name)"

    try {
        $allZones = @(Get-DnsServerZone -ComputerName $dc.Name -ErrorAction Stop)

        # Filter to reverse lookup zones only
        $reverseZones = @($allZones | Where-Object {
            $_.ZoneType -eq 'Primary' -and $_.ZoneName -match 'in-addr\.arpa$'
        })

        if ($reverseZones.Count -eq 0) {
            $results += [PSCustomObject]@{
                DomainController         = $dc.Name
                ReverseLookupZoneCount   = 0
                HasNonIntegratedZones    = $false
                ZoneNames                = 'None'
                IsHealthy                = $false
                HasIssue                 = $true
                Status                   = 'Warning'
                Severity                 = 'Medium'
                Message                  = "No reverse lookup zones found on $($dc.Name) - IP-to-hostname resolution will fail"
            }
        }
        else {
            $nonIntegrated = @($reverseZones | Where-Object { -not $_.IsDsIntegrated })
            $hasNonIntegrated = ($nonIntegrated.Count -gt 0)
            $zoneNameList = ($reverseZones | ForEach-Object { $_.ZoneName }) -join ', '

            if ($hasNonIntegrated) {
                $nonIntNames = ($nonIntegrated | ForEach-Object { $_.ZoneName }) -join ', '
                $results += [PSCustomObject]@{
                    DomainController         = $dc.Name
                    ReverseLookupZoneCount   = $reverseZones.Count
                    HasNonIntegratedZones    = $true
                    ZoneNames                = $zoneNameList
                    IsHealthy                = $false
                    HasIssue                 = $true
                    Status                   = 'Warning'
                    Severity                 = 'Low'
                    Message                  = "Reverse lookup zone(s) are not AD-integrated: $nonIntNames - these will not replicate automatically"
                }
            }
            else {
                $results += [PSCustomObject]@{
                    DomainController         = $dc.Name
                    ReverseLookupZoneCount   = $reverseZones.Count
                    HasNonIntegratedZones    = $false
                    ZoneNames                = $zoneNameList
                    IsHealthy                = $true
                    HasIssue                 = $false
                    Status                   = 'Pass'
                    Severity                 = 'Info'
                    Message                  = "$($reverseZones.Count) AD-integrated reverse lookup zone(s) found: $zoneNameList"
                }
            }
        }
    }
    catch {
        Write-Warning "[DNS-009] Failed to query DNS zones on $($dc.Name): $_"
        $results += [PSCustomObject]@{
            DomainController         = $dc.Name
            ReverseLookupZoneCount   = 0
            HasNonIntegratedZones    = $false
            ZoneNames                = 'Unknown'
            IsHealthy                = $false
            HasIssue                 = $true
            Status                   = 'Error'
            Severity                 = 'Error'
            Message                  = "Failed to query DNS zones on $($dc.Name): $_"
        }
    }

    Write-Verbose "[DNS-009] Check complete."
    return $results
}
catch {
    Write-Error "[DNS-009] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController         = 'Unknown'
        ReverseLookupZoneCount   = 0
        HasNonIntegratedZones    = $false
        ZoneNames                = 'Unknown'
        IsHealthy                = $false
        HasIssue                 = $true
        Status                   = 'Error'
        Severity                 = 'Error'
        Message                  = "Check execution failed: $($_.Exception.Message)"
    })
}
