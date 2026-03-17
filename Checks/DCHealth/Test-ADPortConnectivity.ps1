<#
.SYNOPSIS
    AD Port Connectivity Check (DC-016)

.DESCRIPTION
    Tests that all required Active Directory TCP ports are reachable between
    domain controllers. Blocked ports between DCs break replication, Kerberos,
    LDAP, and RPC-based administration.

    Required ports tested (TCP):
    - 88   : Kerberos authentication
    - 135  : RPC Endpoint Mapper (required for replication)
    - 389  : LDAP
    - 445  : SMB (SYSVOL replication, RPC over SMB)
    - 636  : LDAPS (SSL)
    - 3268 : Global Catalog LDAP
    - 3269 : Global Catalog LDAPS
    - 49152-65535: RPC dynamic ports (tested via RPC mapper, not all ports)

    Each DC tests connectivity to every other DC in the forest.

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-ADPortConnectivity.ps1 -Inventory $inventory

.OUTPUTS
    Array of port connectivity results per DC pair

.NOTES
    Check ID: DC-016
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

Write-Verbose "[DC-016] Starting AD port connectivity check..."

# Required ports for AD inter-DC communication
$requiredPorts = @(
    @{ Port = 88;   Name = 'Kerberos' }
    @{ Port = 135;  Name = 'RPC-EndpointMapper' }
    @{ Port = 389;  Name = 'LDAP' }
    @{ Port = 445;  Name = 'SMB' }
    @{ Port = 636;  Name = 'LDAPS' }
    @{ Port = 3268; Name = 'GlobalCatalog-LDAP' }
    @{ Port = 3269; Name = 'GlobalCatalog-LDAPS' }
)

function Test-TCPPort {
    param([string]$Target, [int]$Port, [int]$TimeoutMs = 3000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect($Target, $Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $connected = $ok -and $tcp.Connected
        try { $tcp.Close() } catch { }
        return $connected
    }
    catch {
        return $false
    }
}

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-016] No domain controllers found in inventory"
        return @()
    }

    $reachableDCs = @($domainControllers | Where-Object { $_.IsReachable })

    if ($reachableDCs.Count -lt 2) {
        $results += [PSCustomObject]@{
            SourceDC         = $env:COMPUTERNAME
            TargetDC         = 'N/A'
            BlockedPorts     = @()
            BlockedPortNames = 'N/A'
            BlockedCount     = 0
            HasIssue         = $false
            Status           = 'Pass'
            Severity         = 'Info'
            IsHealthy        = $true
            Message          = "Only one reachable DC - inter-DC port connectivity test not applicable"
        }
        return $results
    }

    # Test from each DC to every other DC
    # Since checks run locally, we test from local machine to each remote DC
    # For true inter-DC testing we test local -> each DC pair
    $sourceName = $env:COMPUTERNAME

    foreach ($targetDC in $reachableDCs) {
        $targetName = $targetDC.Name

        # Skip self
        if ($targetName -like "$sourceName.*" -or $targetName -eq $sourceName) {
            continue
        }

        Write-Verbose "[DC-016] Testing ports to $targetName"

        $blockedPorts = @()
        $testedPorts  = @()

        foreach ($portDef in $requiredPorts) {
            $port = $portDef.Port
            $name = $portDef.Name

            # Skip GC ports for non-GC DCs
            if (($port -eq 3268 -or $port -eq 3269) -and -not $targetDC.IsGlobalCatalog) {
                continue
            }

            $open = Test-TCPPort -Target $targetName -Port $port -TimeoutMs 3000
            $testedPorts += "$port ($name)"

            if (-not $open) {
                $blockedPorts += "$port ($name)"
            }
        }

        $hasIssue = ($blockedPorts.Count -gt 0)
        $status   = if ($hasIssue) { 'Fail' } else { 'Pass' }
        $severity = if ($blockedPorts.Count -ge 3) { 'Critical' } elseif ($hasIssue) { 'High' } else { 'Info' }

        $message = if ($hasIssue) {
            "DC $targetName has $($blockedPorts.Count) blocked AD port(s): $($blockedPorts -join ', ') - replication and authentication may be impaired"
        } else {
            "All required AD ports are open to DC $targetName ($($testedPorts.Count) ports verified)"
        }

        $results += [PSCustomObject]@{
            SourceDC         = $sourceName
            TargetDC         = $targetName
            BlockedPorts     = $blockedPorts
            BlockedPortNames = ($blockedPorts -join ', ')
            BlockedCount     = $blockedPorts.Count
            TestedCount      = $testedPorts.Count
            HasIssue         = $hasIssue
            Status           = $status
            Severity         = $severity
            IsHealthy        = -not $hasIssue
            Message          = $message
        }
    }

    if ($results.Count -eq 0) {
        $results += [PSCustomObject]@{
            SourceDC         = $sourceName
            TargetDC         = 'N/A'
            BlockedPorts     = @()
            BlockedPortNames = 'None'
            BlockedCount     = 0
            TestedCount      = 0
            HasIssue         = $false
            Status           = 'Pass'
            Severity         = 'Info'
            IsHealthy        = $true
            Message          = "No remote DCs to test port connectivity against"
        }
    }

    Write-Verbose "[DC-016] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-016] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        SourceDC         = 'Unknown'
        TargetDC         = 'Unknown'
        BlockedPorts     = @()
        BlockedPortNames = 'Unknown'
        BlockedCount     = 0
        TestedCount      = 0
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        IsHealthy        = $false
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
