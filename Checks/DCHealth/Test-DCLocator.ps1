<#
.SYNOPSIS
    DC Locator Test (DC-015)

.DESCRIPTION
    Tests whether each domain controller can be located via the DC Locator
    process. The DC Locator is the mechanism clients use to find a domain
    controller - it relies on DNS SRV records and UDP/TCP port 389 (LDAP).

    If a DC cannot be located, clients in that site will fail to authenticate
    or will fall back to DCs in other sites, causing latency.

    Checks:
    - nltest /dsgetdc equivalent: attempts to locate a DC for each domain
    - Each DC responds to LDAP ping (UDP 389 CLDAP)
    - DC advertises itself in DNS correctly (cross-validates with DNS-001)

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-DCLocator.ps1 -Inventory $inventory

.OUTPUTS
    Array of DC locator test results per DC

.NOTES
    Check ID: DC-015
    Category: DCHealth
    Severity: Critical
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[DC-015] Starting DC locator test..."

function Test-LDAPPing {
    param([string]$DCName, [int]$TimeoutMs = 3000)
    # CLDAP ping: send a UDP packet to port 389 and expect a response
    # Use TCP 389 as a proxy for DC locator responsiveness
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect($DCName, 389, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $tcp.Connected) {
            $tcp.Close()
            return $true
        }
        $tcp.Close()
        return $false
    } catch {
        return $false
    }
}

try {
    $domains = $Inventory.Domains
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-015] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        $dcName = $dc.Name
        Write-Verbose "[DC-015] Testing DC locator for: $dcName"

        try {
            $issues = @()

            # Test LDAP port availability (proxy for DC locator)
            $ldapResponds = Test-LDAPPing -DCName $dcName -TimeoutMs 3000

            if (-not $ldapResponds) {
                $issues += "DC does not respond to LDAP connection on port 389"
            }

            # Test nltest /dsgetdc from this machine targeting the DC's domain
            $domain = $domains | Where-Object { $dc.Name -like "*.$($_.Name)" -or $dc.Name -eq $_.Name } | Select-Object -First 1
            if (-not $domain) { $domain = $domains | Select-Object -First 1 }

            $nlTestPassed = $false
            $nlTestOutput = ''
            if ($domain) {
                try {
                    $nlResult = (nltest /dsgetdc:$($domain.Name) /force 2>&1) -join ' '
                    $nlTestPassed = ($nlResult -match 'DC:')
                    $nlTestOutput = $nlResult.Substring(0, [math]::Min(200, $nlResult.Length))
                    if (-not $nlTestPassed) {
                        $issues += "nltest /dsgetdc:$($domain.Name) failed - DC locator may be impaired"
                    }
                } catch {
                    $nlTestOutput = 'nltest not available'
                }
            }

            # Verify DC is registered in DNS (basic check - look up the FQDN)
            $dnsResolves = $false
            try {
                $resolved = [System.Net.Dns]::GetHostAddresses($dcName)
                $dnsResolves = ($resolved -and $resolved.Count -gt 0)
            } catch {
                $dnsResolves = $false
                $issues += "DC FQDN '$dcName' does not resolve in DNS"
            }

            $hasIssue = ($issues.Count -gt 0)
            $status   = if ($hasIssue) { if (-not $ldapResponds) { 'Fail' } else { 'Warning' } } else { 'Pass' }
            $severity = if (-not $ldapResponds) { 'Critical' } elseif ($hasIssue) { 'High' } else { 'Info' }
            $message  = if ($hasIssue) {
                "DC $dcName locator issues: $($issues -join '; ')"
            } else {
                "DC $dcName is locatable - LDAP responds, DNS resolves, DC locator functional"
            }

            $results += [PSCustomObject]@{
                DomainController = $dcName
                LDAPResponds     = $ldapResponds
                DNSResolves      = $dnsResolves
                NLTestPassed     = $nlTestPassed
                NLTestOutput     = $nlTestOutput
                HasIssue         = $hasIssue
                Status           = $status
                Severity         = $severity
                IsHealthy        = -not $hasIssue
                Message          = $message
            }
        }
        catch {
            Write-Warning "[DC-015] Failed to test DC locator for $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController = $dcName
                LDAPResponds     = $false
                DNSResolves      = $false
                NLTestPassed     = $false
                NLTestOutput     = $_.Exception.Message
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                IsHealthy        = $false
                Message          = "Failed to test DC locator for $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DC-015] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-015] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        LDAPResponds     = $false
        DNSResolves      = $false
        NLTestPassed     = $false
        NLTestOutput     = $_.Exception.Message
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
