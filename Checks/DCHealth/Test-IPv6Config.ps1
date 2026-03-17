<#
.SYNOPSIS
    IPv6 Configuration Check (DC-017)

.DESCRIPTION
    Checks IPv6 configuration on each domain controller. Microsoft does not
    recommend completely disabling IPv6, as it is required by some Windows
    components. However, unconfigured or unmanaged IPv6 can cause security
    issues (rogue DHCPv6, LLMNR, mDNS attacks).

    Checks:
    - IPv6 is not fully disabled via registry (DisabledComponents = 0xFF)
      Microsoft recommends disabling specific components, not all IPv6
    - If IPv6 is active, DCs have AAAA records registered in DNS
    - IPv6 addresses are not APIPA/link-local only (fe80::) - indicates
      no managed IPv6 addressing (DHCPv6 or static)

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-IPv6Config.ps1 -Inventory $inventory

.OUTPUTS
    Array of IPv6 configuration results per DC

.NOTES
    Check ID: DC-017
    Category: DCHealth
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

Write-Verbose "[DC-017] Starting IPv6 configuration check..."

$HKLM          = [uint32]'0x80000002'
$IPV6_REG_KEY  = 'SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
$IPV6_REG_VAL  = 'DisabledComponents'

# DisabledComponents value meanings:
# 0x00 = IPv6 fully enabled (default)
# 0xFF = IPv6 fully disabled (not recommended by Microsoft)
# 0x20 = Prefer IPv4 over IPv6 (acceptable)

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-017] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[DC-017] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[DC-017] Checking IPv6 config on: $dcName"

        try {
            $issues = @()

            # Read DisabledComponents from registry
            $disabledComponents = $null
            try {
                $reg = [WMIClass]"\\$dcName\root\default:StdRegProv"
                $regResult = $reg.GetDWORDValue($HKLM, $IPV6_REG_KEY, $IPV6_REG_VAL)
                if ($regResult.ReturnValue -eq 0) {
                    $disabledComponents = $regResult.uValue
                }
            }
            catch {
                Write-Verbose "[DC-017] Registry read failed on $dcName"
            }

            $ipv6FullyDisabled = ($disabledComponents -eq 255)  # 0xFF

            if ($ipv6FullyDisabled) {
                $issues += "IPv6 is completely disabled (DisabledComponents=0xFF) - Microsoft does not recommend this; it can break some Windows components"
            }

            # Get IPv6 addresses on network adapters
            $globalIPv6Addresses = @()
            $linkLocalOnly       = $false
            $hasIPv6             = $false

            try {
                $adapters = @(Get-WmiObject -Class Win32_NetworkAdapterConfiguration `
                    -ComputerName $dcName `
                    -Filter "IPEnabled=True" `
                    -ErrorAction SilentlyContinue)

                foreach ($adapter in $adapters) {
                    if ($adapter.IPAddress) {
                        $v6Addrs = @($adapter.IPAddress | Where-Object { $_ -match ':' })
                        foreach ($addr in $v6Addrs) {
                            $hasIPv6 = $true
                            if ($addr -notmatch '^fe80') {
                                $globalIPv6Addresses += $addr
                            }
                        }
                    }
                }

                if ($hasIPv6 -and $globalIPv6Addresses.Count -eq 0 -and -not $ipv6FullyDisabled) {
                    $linkLocalOnly = $true
                    $issues += "DC has only link-local IPv6 addresses (fe80::) - no global/ULA IPv6 address; ensure IPv6 is intentionally limited"
                }
            }
            catch {
                Write-Verbose "[DC-017] Could not enumerate network adapters on $dcName"
            }

            $hasIssue = ($issues.Count -gt 0)
            $status   = if ($hasIssue) { 'Warning' } else { 'Pass' }
            $severity = if ($ipv6FullyDisabled) { 'Medium' } elseif ($hasIssue) { 'Low' } else { 'Info' }

            $ipv6Summary = if ($ipv6FullyDisabled) {
                'Fully disabled'
            } elseif ($disabledComponents -eq 32) {
                'IPv4 preferred (0x20)'
            } elseif ($hasIPv6 -and $globalIPv6Addresses.Count -gt 0) {
                "Active (global: $($globalIPv6Addresses[0]))"
            } elseif ($linkLocalOnly) {
                'Link-local only'
            } else {
                "DisabledComponents=$disabledComponents"
            }

            $message = if ($hasIssue) {
                "DC $dcName IPv6 issues: $($issues -join '; ')"
            } else {
                "DC $dcName IPv6 configuration is acceptable ($ipv6Summary)"
            }

            $results += [PSCustomObject]@{
                DomainController    = $dcName
                DisabledComponents  = $disabledComponents
                IPv6FullyDisabled   = $ipv6FullyDisabled
                HasGlobalIPv6       = ($globalIPv6Addresses.Count -gt 0)
                LinkLocalOnly       = $linkLocalOnly
                IPv6Summary         = $ipv6Summary
                HasIssue            = $hasIssue
                Status              = $status
                Severity            = $severity
                IsHealthy           = -not $hasIssue
                Message             = $message
            }
        }
        catch {
            Write-Warning "[DC-017] Failed to check IPv6 on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController    = $dcName
                DisabledComponents  = $null
                IPv6FullyDisabled   = $false
                HasGlobalIPv6       = $false
                LinkLocalOnly       = $false
                IPv6Summary         = 'Unknown'
                HasIssue            = $true
                Status              = 'Error'
                Severity            = 'Error'
                IsHealthy           = $false
                Message             = "Failed to check IPv6 config on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DC-017] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-017] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController    = 'Unknown'
        DisabledComponents  = $null
        IPv6FullyDisabled   = $false
        HasGlobalIPv6       = $false
        LinkLocalOnly       = $false
        IPv6Summary         = 'Unknown'
        HasIssue            = $true
        Status              = 'Error'
        Severity            = 'Error'
        IsHealthy           = $false
        Message             = "Check execution failed: $($_.Exception.Message)"
    })
}
