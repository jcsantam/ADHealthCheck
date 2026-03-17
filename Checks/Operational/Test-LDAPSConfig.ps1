<#
.SYNOPSIS
    LDAPS Configuration Check (OPS-014)

.DESCRIPTION
    Tests whether LDAPS (LDAP over SSL, port 636) is available on each domain
    controller. LDAPS encrypts all LDAP traffic and is required for secure
    credential operations. Uses an asynchronous TCP connection with a 3-second
    timeout to avoid long waits on unreachable ports.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-014
    Category: Operational
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

Write-Verbose "[OPS-014] Starting LDAPS configuration check..."

$reachableDCs = @($Inventory.DomainControllers | Where-Object { $_.IsReachable -eq $true })

if ($reachableDCs.Count -eq 0) {
    return @([PSCustomObject]@{
        DomainController = 'N/A'
        LDAPSAvailable   = $false
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = 'No reachable domain controllers found'
    })
}

foreach ($dc in $reachableDCs) {
    $dcName = $dc.Name
    Write-Verbose "[OPS-014] Testing LDAPS (port 636) on: $dcName"

    $ldapsAvailable = $false
    $tcp = $null

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect($dcName, 636, $null, $null)
        $wait = $ar.AsyncWaitHandle.WaitOne(3000, $false)

        if ($wait -and $tcp.Connected) {
            $ldapsAvailable = $true
        } else {
            $ldapsAvailable = $false
        }
    }
    catch {
        $ldapsAvailable = $false
    }
    finally {
        if ($null -ne $tcp) {
            try { $tcp.Close() } catch { }
        }
    }

    if ($ldapsAvailable) {
        $results += [PSCustomObject]@{
            DomainController = $dcName
            LDAPSAvailable   = $true
            IsHealthy        = $true
            HasIssue         = $false
            Status           = 'Pass'
            Severity         = 'Info'
            Message          = "LDAPS (port 636) is available on $dcName."
        }
    } else {
        $results += [PSCustomObject]@{
            DomainController = $dcName
            LDAPSAvailable   = $false
            IsHealthy        = $false
            HasIssue         = $true
            Status           = 'Warning'
            Severity         = 'Medium'
            Message          = "LDAPS (port 636) is NOT available on $dcName. Install a valid SSL certificate to enable LDAPS."
        }
    }
}

Write-Verbose "[OPS-014] Check complete. DCs checked: $($results.Count)"
return $results
