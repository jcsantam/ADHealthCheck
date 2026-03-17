<#
.SYNOPSIS
    Conditional Forwarders Check (DNS-010)
.DESCRIPTION
    Enumerates conditional forwarders and tests reachability of their target
    master servers on TCP port 53. Unreachable conditional forwarder targets
    cause DNS resolution failures for those namespaces.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DNS-010
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

Write-Verbose "[DNS-010] Starting conditional forwarders check..."

# Check if DnsServer module is available
if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Warning "[DNS-010] DnsServer module not available - skipping check"
    return @([PSCustomObject]@{
        DomainController    = 'N/A'
        ZoneName            = 'N/A'
        MasterServers       = 'N/A'
        UnreachableMasters  = 'N/A'
        IsReachable         = $true
        IsHealthy           = $true
        HasIssue            = $false
        Status              = 'Pass'
        Severity            = 'Info'
        Message             = 'DnsServer module not available - conditional forwarder check skipped'
    })
}

Import-Module DnsServer -ErrorAction SilentlyContinue

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DNS-010] No reachable DCs found"
        return @()
    }

    # Track conditional forwarder zones already checked to deduplicate across DCs
    $checkedZones = @{}

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DNS-010] Querying conditional forwarders on: $($dc.Name)"

        try {
            $allZones = @(Get-DnsServerZone -ComputerName $dc.Name -ErrorAction Stop)

            $conditionalZones = @($allZones | Where-Object { $_.ZoneType -eq 'Forwarder' })

            foreach ($zone in $conditionalZones) {
                # Deduplicate zones across DCs
                if ($checkedZones.ContainsKey($zone.ZoneName)) {
                    continue
                }
                $checkedZones[$zone.ZoneName] = $true

                $masterServers = @()
                if ($zone.MasterServers) {
                    foreach ($ms in $zone.MasterServers) {
                        $masterServers += $ms.IPAddressToString
                    }
                }

                $unreachableMasters = @()
                $allReachable = $true

                foreach ($ip in $masterServers) {
                    Write-Verbose "[DNS-010] Testing TCP port 53 to $ip for zone $($zone.ZoneName)"
                    $tcpTest = Test-NetConnection -ComputerName $ip -Port 53 -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
                    if (-not $tcpTest.TcpTestSucceeded) {
                        $unreachableMasters += $ip
                        $allReachable = $false
                    }
                }

                $masterList = $masterServers -join ', '
                $unreachableList = $unreachableMasters -join ', '

                if (-not $allReachable) {
                    $hasIssue = $true
                    $status   = 'Fail'
                    $severity = 'High'
                    $isReachable = $false
                    $message  = "Conditional forwarder '$($zone.ZoneName)' has unreachable master server(s): $unreachableList"
                }
                else {
                    $hasIssue = $false
                    $status   = 'Pass'
                    $severity = 'Info'
                    $isReachable = $true
                    $message  = "Conditional forwarder '$($zone.ZoneName)' master server(s) are reachable: $masterList"
                }

                $results += [PSCustomObject]@{
                    DomainController   = $dc.Name
                    ZoneName           = $zone.ZoneName
                    MasterServers      = $masterList
                    UnreachableMasters = $unreachableList
                    IsReachable        = $isReachable
                    IsHealthy          = -not $hasIssue
                    HasIssue           = $hasIssue
                    Status             = $status
                    Severity           = $severity
                    Message            = $message
                }
            }
        }
        catch {
            Write-Warning "[DNS-010] Failed to query DNS zones on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController   = $dc.Name
                ZoneName           = 'Unknown'
                MasterServers      = 'Unknown'
                UnreachableMasters = 'Unknown'
                IsReachable        = $false
                IsHealthy          = $false
                HasIssue           = $true
                Status             = 'Error'
                Severity           = 'Error'
                Message            = "Failed to query DNS zones on $($dc.Name): $_"
            }
        }
    }

    if (@($results).Count -eq 0) {
        Write-Verbose "[DNS-010] No conditional forwarders found - no issues"
        return @([PSCustomObject]@{
            DomainController   = 'N/A'
            ZoneName           = 'N/A'
            MasterServers      = 'N/A'
            UnreachableMasters = 'N/A'
            IsReachable        = $true
            IsHealthy          = $true
            HasIssue           = $false
            Status             = 'Pass'
            Severity           = 'Info'
            Message            = 'No conditional forwarders configured - no issues to report'
        })
    }

    Write-Verbose "[DNS-010] Check complete. Conditional forwarders evaluated: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DNS-010] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController   = 'Unknown'
        ZoneName           = 'Unknown'
        MasterServers      = 'Unknown'
        UnreachableMasters = 'Unknown'
        IsReachable        = $false
        IsHealthy          = $false
        HasIssue           = $true
        Status             = 'Error'
        Severity           = 'Error'
        Message            = "Check execution failed: $($_.Exception.Message)"
    })
}
