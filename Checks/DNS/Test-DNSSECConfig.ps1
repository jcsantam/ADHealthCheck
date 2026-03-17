<#
.SYNOPSIS
    DNSSEC Configuration Check (DNS-012)
.DESCRIPTION
    Checks if DNS zones are signed with DNSSEC. DNSSEC prevents DNS cache
    poisoning and man-in-the-middle attacks by cryptographically signing DNS
    responses. Also checks for the presence of the TrustAnchors zone.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DNS-012
    Category: DNS
    Severity: Low
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[DNS-012] Starting DNSSEC configuration check..."

# Check if DnsServer module is available
if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Warning "[DNS-012] DnsServer module not available - skipping check"
    return @([PSCustomObject]@{
        Domain               = 'N/A'
        DomainController     = 'N/A'
        IsSigned             = $false
        TrustAnchorsPresent  = $false
        IsHealthy            = $true
        HasIssue             = $false
        Status               = 'Pass'
        Severity             = 'Info'
        Message              = 'DnsServer module not available - DNSSEC check skipped'
    })
}

Import-Module DnsServer -ErrorAction SilentlyContinue

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DNS-012] No reachable DCs found"
        return @()
    }

    $domains = $Inventory.Domains

    if (-not $domains) {
        Write-Warning "[DNS-012] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        Write-Verbose "[DNS-012] Checking DNSSEC for domain: $($domain.Name)"

        # Find a reachable DC for this domain
        $dc = $domainControllers | Select-Object -First 1

        $isSigned           = $false
        $trustAnchorsPresent = $false
        $checkedDc          = $dc.Name

        try {
            # Check if the domain zone is signed
            $zone = Get-DnsServerZone -ComputerName $dc.Name -Name $domain.Name -ErrorAction SilentlyContinue

            if ($zone) {
                if ($zone.PSObject.Properties['IsSigned']) {
                    $isSigned = $zone.IsSigned
                }
            }

            # Check for TrustAnchors zone as secondary indicator of DNSSEC use
            $allZones = @(Get-DnsServerZone -ComputerName $dc.Name -ErrorAction SilentlyContinue)
            $trustAnchorsZone = $allZones | Where-Object { $_.ZoneName -eq 'TrustAnchors' }
            if ($trustAnchorsZone) {
                $trustAnchorsPresent = $true
            }
        }
        catch {
            Write-Warning "[DNS-012] Failed to query DNSSEC settings for domain $($domain.Name) on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                Domain               = $domain.Name
                DomainController     = $checkedDc
                IsSigned             = $false
                TrustAnchorsPresent  = $false
                IsHealthy            = $false
                HasIssue             = $true
                Status               = 'Error'
                Severity             = 'Error'
                Message              = "Failed to query DNSSEC settings for domain $($domain.Name): $_"
            }
            continue
        }

        if ($isSigned) {
            $hasIssue = $false
            $status   = 'Pass'
            $severity = 'Info'
            $message  = "Domain zone '$($domain.Name)' is signed with DNSSEC"
        }
        else {
            $hasIssue = $true
            $status   = 'Warning'
            $severity = 'Low'
            if ($trustAnchorsPresent) {
                $message = "Domain zone '$($domain.Name)' is not signed with DNSSEC (TrustAnchors zone exists - may be partially configured)"
            }
            else {
                $message = "Domain zone '$($domain.Name)' is not signed with DNSSEC - DNS responses are not cryptographically verified"
            }
        }

        $results += [PSCustomObject]@{
            Domain               = $domain.Name
            DomainController     = $checkedDc
            IsSigned             = $isSigned
            TrustAnchorsPresent  = $trustAnchorsPresent
            IsHealthy            = -not $hasIssue
            HasIssue             = $hasIssue
            Status               = $status
            Severity             = $severity
            Message              = $message
        }
    }

    if (@($results).Count -eq 0) {
        return @([PSCustomObject]@{
            Domain               = 'N/A'
            DomainController     = 'N/A'
            IsSigned             = $false
            TrustAnchorsPresent  = $false
            IsHealthy            = $true
            HasIssue             = $false
            Status               = 'Pass'
            Severity             = 'Info'
            Message              = 'No domains found to evaluate for DNSSEC'
        })
    }

    Write-Verbose "[DNS-012] Check complete. Domains evaluated: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DNS-012] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain               = 'Unknown'
        DomainController     = 'Unknown'
        IsSigned             = $false
        TrustAnchorsPresent  = $false
        IsHealthy            = $false
        HasIssue             = $true
        Status               = 'Error'
        Severity             = 'Error'
        Message              = "Check execution failed: $($_.Exception.Message)"
    })
}
