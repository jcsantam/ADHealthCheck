<#
.SYNOPSIS
    DNS Dynamic Update Security Check (DNS-007)
.DESCRIPTION
    Checks that AD-integrated DNS zones use Secure dynamic updates.
    Non-secure (NonsecureAndSecure) or disabled dynamic updates on
    AD-integrated zones represent a security risk.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DNS-007
    Category: DNS
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

# System zones to exclude from security checks
$excludedZones = @(
    'TrustAnchors',
    '0.in-addr.arpa',
    '127.in-addr.arpa',
    '255.in-addr.arpa',
    'RootDNSServers'
)

Write-Verbose "[DNS-007] Starting DNS dynamic update security check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DNS-007] No reachable DCs found"
        return @()
    }

    # Track zones already checked to avoid duplicates across DCs
    $checkedZones = @{}

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DNS-007] Checking DNS zones on: $($dc.Name)"

        try {
            $zones = @(Get-DnsServerZone -ComputerName $dc.Name -ErrorAction Stop)

            foreach ($zone in $zones) {
                # Only check AD-integrated primary zones
                if ($zone.ZoneType -ne 'Primary' -or -not $zone.IsDsIntegrated) {
                    continue
                }

                # Skip system zones
                if ($excludedZones -contains $zone.ZoneName) {
                    continue
                }

                # Skip if already checked this zone from another DC (use first DC result)
                if ($checkedZones.ContainsKey($zone.ZoneName)) {
                    continue
                }
                $checkedZones[$zone.ZoneName] = $true

                $dynamicUpdate = $zone.DynamicUpdate
                $isSecure      = $dynamicUpdate -eq 'Secure'
                $hasIssue      = -not $isSecure

                # NonsecureAndSecure = High risk; None = depends on zone purpose
                $severity = if ($dynamicUpdate -eq 'NonsecureAndSecure' -or $dynamicUpdate -eq 'NonSecure') { 'High' }
                            elseif ($dynamicUpdate -eq 'None') { 'Medium' }
                            else { 'Info' }
                $status   = if ($hasIssue -and $severity -eq 'High') { 'Fail' }
                            elseif ($hasIssue) { 'Warning' }
                            else { 'Healthy' }

                $results += [PSCustomObject]@{
                    DomainController = $dc.Name
                    ZoneName         = $zone.ZoneName
                    DynamicUpdate    = $dynamicUpdate
                    IsSecure         = $isSecure
                    IsHealthy        = -not $hasIssue
                    HasIssue         = $hasIssue
                    Status           = $status
                    Severity         = $severity
                    Message          = if ($dynamicUpdate -eq 'NonsecureAndSecure' -or $dynamicUpdate -eq 'NonSecure') {
                        "SECURITY RISK: Zone '$($zone.ZoneName)' allows non-secure dynamic updates (DynamicUpdate: $dynamicUpdate)"
                    } elseif ($dynamicUpdate -eq 'None') {
                        "WARNING: Zone '$($zone.ZoneName)' has dynamic updates disabled (DynamicUpdate: None)"
                    } else {
                        "Zone '$($zone.ZoneName)' uses secure dynamic updates"
                    }
                }
            }
        }
        catch {
            Write-Warning "[DNS-007] Failed to query DNS zones on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                ZoneName         = 'Unknown'
                DynamicUpdate    = 'Unknown'
                IsSecure         = $false
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                Message          = "Failed to query DNS zones on $($dc.Name): $_"
            }
        }
    }

    if (@($results).Count -eq 0) {
        return @([PSCustomObject]@{
            DomainController = 'N/A'
            ZoneName         = 'N/A'
            DynamicUpdate    = 'N/A'
            IsSecure         = $true
            IsHealthy        = $true
            HasIssue         = $false
            Status           = 'Pass'
            Severity         = 'Info'
            Message          = 'No AD-integrated primary DNS zones found to evaluate'
        })
    }

    Write-Verbose "[DNS-007] Check complete. Zones evaluated: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DNS-007] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        ZoneName         = 'Unknown'
        DynamicUpdate    = 'Unknown'
        IsSecure         = $false
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
