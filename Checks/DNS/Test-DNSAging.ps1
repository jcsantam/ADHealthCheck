<#
.SYNOPSIS
    DNS Aging Configuration Check (DNS-008)
.DESCRIPTION
    Checks DNS aging and scavenging settings on AD-integrated primary zones.
    Stale DNS records accumulate when aging is disabled, causing name resolution
    errors as computers are decommissioned.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DNS-008
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

# Zones to exclude from aging checks
$excludedZones = @(
    'TrustAnchors',
    '0.in-addr.arpa',
    '127.in-addr.arpa',
    '255.in-addr.arpa',
    'RootDNSServers'
)

Write-Verbose "[DNS-008] Starting DNS aging configuration check..."

# Check if DnsServer module is available
if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Warning "[DNS-008] DnsServer module not available - skipping check"
    return @([PSCustomObject]@{
        DomainController    = 'N/A'
        ZoneName            = 'N/A'
        IsAging             = $false
        AgingEnabled        = $false
        ScavengingInterval  = 0
        IsHealthy           = $true
        HasIssue            = $false
        Status              = 'Pass'
        Severity            = 'Info'
        Message             = 'DnsServer module not available - DNS aging check skipped'
    })
}

Import-Module DnsServer -ErrorAction SilentlyContinue

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DNS-008] No reachable DCs found"
        return @()
    }

    # Track zones already checked to deduplicate across DCs
    $checkedZones = @{}

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DNS-008] Checking DNS aging on: $($dc.Name)"

        # Get server-level scavenging interval
        $scavengingInterval = 0
        try {
            $dnsServer = Get-DnsServer -ComputerName $dc.Name -ErrorAction Stop
            $scavengingInterval = $dnsServer.ServerSetting.ScavengingInterval.TotalHours
        }
        catch {
            Write-Warning "[DNS-008] Could not retrieve server settings from $($dc.Name): $_"
        }

        try {
            $zones = @(Get-DnsServerZone -ComputerName $dc.Name -ErrorAction Stop)

            foreach ($zone in $zones) {
                # Only check AD-integrated primary zones
                if ($zone.ZoneType -ne 'Primary' -or -not $zone.IsDsIntegrated) {
                    continue
                }

                # Skip reverse lookup zones
                if ($zone.ZoneName -match 'in-addr\.arpa$' -or $zone.ZoneName -match 'ip6\.arpa$') {
                    continue
                }

                # Skip system zones
                if ($excludedZones -contains $zone.ZoneName) {
                    continue
                }

                # Deduplicate - use result from first responding DC
                if ($checkedZones.ContainsKey($zone.ZoneName)) {
                    continue
                }
                $checkedZones[$zone.ZoneName] = $true

                $isAging = $zone.IsAging
                $hasIssue = ($isAging -eq $false)

                if ($hasIssue) {
                    $status   = 'Warning'
                    $severity = 'Medium'
                    $message  = "Zone '$($zone.ZoneName)' has aging disabled - stale DNS records will not be removed automatically"
                }
                else {
                    $status   = 'Pass'
                    $severity = 'Info'
                    $message  = "Zone '$($zone.ZoneName)' has aging enabled"
                }

                $results += [PSCustomObject]@{
                    DomainController   = $dc.Name
                    ZoneName           = $zone.ZoneName
                    IsAging            = $isAging
                    AgingEnabled       = $isAging
                    ScavengingInterval = $scavengingInterval
                    IsHealthy          = -not $hasIssue
                    HasIssue           = $hasIssue
                    Status             = $status
                    Severity           = $severity
                    Message            = $message
                }
            }
        }
        catch {
            Write-Warning "[DNS-008] Failed to query DNS zones on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController   = $dc.Name
                ZoneName           = 'Unknown'
                IsAging            = $false
                AgingEnabled       = $false
                ScavengingInterval = 0
                IsHealthy          = $false
                HasIssue           = $true
                Status             = 'Error'
                Severity           = 'Error'
                Message            = "Failed to query DNS zones on $($dc.Name): $_"
            }
        }
    }

    if (@($results).Count -eq 0) {
        return @([PSCustomObject]@{
            DomainController   = 'N/A'
            ZoneName           = 'N/A'
            IsAging            = $true
            AgingEnabled       = $true
            ScavengingInterval = 0
            IsHealthy          = $true
            HasIssue           = $false
            Status             = 'Pass'
            Severity           = 'Info'
            Message            = 'No AD-integrated primary DNS zones found to evaluate'
        })
    }

    Write-Verbose "[DNS-008] Check complete. Zones evaluated: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DNS-008] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController   = 'Unknown'
        ZoneName           = 'Unknown'
        IsAging            = $false
        AgingEnabled       = $false
        ScavengingInterval = 0
        IsHealthy          = $false
        HasIssue           = $true
        Status             = 'Error'
        Severity           = 'Error'
        Message            = "Check execution failed: $($_.Exception.Message)"
    })
}
