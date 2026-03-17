<#
.SYNOPSIS
    DNS Recursion Settings Check (DNS-011)
.DESCRIPTION
    Checks DNS recursion settings on each DC. Disabled recursion without
    forwarders means the DNS server cannot resolve external names, breaking
    client DNS resolution entirely.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DNS-011
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

Write-Verbose "[DNS-011] Starting DNS recursion settings check..."

# Check if DnsServer module is available
if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Warning "[DNS-011] DnsServer module not available - skipping check"
    return @([PSCustomObject]@{
        DomainController  = 'N/A'
        RecursionEnabled  = $true
        ForwardersPresent = $false
        IsHealthy         = $true
        HasIssue          = $false
        Status            = 'Pass'
        Severity          = 'Info'
        Message           = 'DnsServer module not available - DNS recursion check skipped'
    })
}

Import-Module DnsServer -ErrorAction SilentlyContinue

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DNS-011] No reachable DCs found"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DNS-011] Checking DNS recursion on: $($dc.Name)"

        try {
            $dnsServer = Get-DnsServer -ComputerName $dc.Name -ErrorAction Stop

            # Try DisableRecursion first, fall back to NoRecursion
            $disableRecursion = $null
            if ($dnsServer.ServerSetting.PSObject.Properties['DisableRecursion']) {
                $disableRecursion = $dnsServer.ServerSetting.DisableRecursion
            }
            elseif ($dnsServer.ServerSetting.PSObject.Properties['NoRecursion']) {
                $disableRecursion = $dnsServer.ServerSetting.NoRecursion
            }
            elseif ($dnsServer.ServerRecursion -and $dnsServer.ServerRecursion.PSObject.Properties['Enable']) {
                # ServerRecursion.Enable = $true means recursion IS enabled
                $disableRecursion = -not $dnsServer.ServerRecursion.Enable
            }
            else {
                # Cannot determine - assume enabled (most common default)
                $disableRecursion = $false
            }

            $recursionEnabled = -not $disableRecursion

            # Check if forwarders are present
            $forwardersPresent = $false
            try {
                $forwarders = Get-DnsServerForwarder -ComputerName $dc.Name -ErrorAction Stop
                if ($forwarders.IPAddress -and $forwarders.IPAddress.Count -gt 0) {
                    $forwardersPresent = $true
                }
            }
            catch {
                Write-Warning "[DNS-011] Could not retrieve forwarders from $($dc.Name): $_"
            }

            # Determine issue status
            # Recursion disabled AND no forwarders = DNS resolution will break
            # Recursion disabled AND forwarders present = unusual but may be intentional
            # Recursion enabled = normal

            if ($recursionEnabled) {
                $hasIssue = $false
                $status   = 'Pass'
                $severity = 'Info'
                $message  = "DNS recursion is enabled on $($dc.Name) - clients can resolve external names"
            }
            elseif (-not $forwardersPresent) {
                $hasIssue = $true
                $status   = 'Fail'
                $severity = 'High'
                $message  = "DNS recursion is disabled on $($dc.Name) and no forwarders are configured - external DNS resolution will fail"
            }
            else {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'Low'
                $message  = "DNS recursion is disabled on $($dc.Name) but forwarders are present - external resolution depends on forwarders only"
            }

            $results += [PSCustomObject]@{
                DomainController  = $dc.Name
                RecursionEnabled  = $recursionEnabled
                ForwardersPresent = $forwardersPresent
                IsHealthy         = -not $hasIssue
                HasIssue          = $hasIssue
                Status            = $status
                Severity          = $severity
                Message           = $message
            }
        }
        catch {
            Write-Warning "[DNS-011] Failed to query DNS server settings on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController  = $dc.Name
                RecursionEnabled  = $false
                ForwardersPresent = $false
                IsHealthy         = $false
                HasIssue          = $true
                Status            = 'Error'
                Severity          = 'Error'
                Message           = "Failed to query DNS server settings on $($dc.Name): $_"
            }
        }
    }

    if (@($results).Count -eq 0) {
        return @([PSCustomObject]@{
            DomainController  = 'N/A'
            RecursionEnabled  = $true
            ForwardersPresent = $false
            IsHealthy         = $true
            HasIssue          = $false
            Status            = 'Pass'
            Severity          = 'Info'
            Message           = 'No DNS server settings could be evaluated'
        })
    }

    Write-Verbose "[DNS-011] Check complete. DCs evaluated: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DNS-011] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController  = 'Unknown'
        RecursionEnabled  = $false
        ForwardersPresent = $false
        IsHealthy         = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        Message           = "Check execution failed: $($_.Exception.Message)"
    })
}
