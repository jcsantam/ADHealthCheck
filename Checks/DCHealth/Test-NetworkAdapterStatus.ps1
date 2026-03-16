<#
.SYNOPSIS
    Network Adapter Status Check (DC-012)
.DESCRIPTION
    Checks network adapter connectivity and configuration on each domain controller.
    Flags physical adapters that are disconnected or have incorrect status.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: DC-012
    Category: DCHealth
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

Write-Verbose "[DC-012] Starting network adapter status check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[DC-012] No reachable DCs found"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-012] Checking network adapters on: $($dc.Name)"

        try {
            # Get physical/enabled network adapters via WMI
            $adapters = @(Get-WmiObject -Class Win32_NetworkAdapter `
                -ComputerName $dc.Name -ErrorAction Stop |
                Where-Object {
                    $_.PhysicalAdapter -eq $true -or
                    $_.AdapterTypeId -eq 0 -or
                    $_.NetEnabled -eq $true
                })

            if (@($adapters).Count -eq 0) {
                # Try without the PhysicalAdapter filter - some VMs don't expose it
                $adapters = @(Get-WmiObject -Class Win32_NetworkAdapter `
                    -ComputerName $dc.Name -ErrorAction Stop |
                    Where-Object { $_.AdapterType -and $_.AdapterType -notlike '*loopback*' })
            }

            # Get IP configurations
            $configs = @(Get-WmiObject -Class Win32_NetworkAdapterConfiguration `
                -ComputerName $dc.Name -ErrorAction Stop |
                Where-Object { $_.IPEnabled -eq $true })

            $configByIndex = @{}
            foreach ($cfg in $configs) {
                $configByIndex[$cfg.Index] = $cfg
            }

            foreach ($adapter in $adapters) {
                $cfg       = $configByIndex[$adapter.DeviceID]
                $ipAddress = if ($cfg -and $cfg.IPAddress) { ($cfg.IPAddress | Where-Object { $_ -notlike '*:*' } | Select-Object -First 1) } else { 'N/A' }

                # NetConnectionStatus: 2 = Connected, 7 = Media disconnected
                # See https://docs.microsoft.com/en-us/windows/win32/cimwin32prov/win32-networkadapter
                $connStatus = $adapter.NetConnectionStatus
                $isUp       = $connStatus -eq 2

                # Only flag adapters that are enabled (NetEnabled = true or have IP) but not connected
                $isEnabled = $adapter.NetEnabled -eq $true -or $cfg -ne $null
                $hasIssue  = $isEnabled -and (-not $isUp) -and ($connStatus -ne $null)

                $statusDesc = switch ($connStatus) {
                    0  { 'Disconnected' }
                    1  { 'Connecting' }
                    2  { 'Connected' }
                    3  { 'Disconnecting' }
                    4  { 'Hardware not present' }
                    5  { 'Hardware disabled' }
                    6  { 'Hardware malfunction' }
                    7  { 'Media disconnected' }
                    8  { 'Authenticating' }
                    9  { 'Authentication succeeded' }
                    10 { 'Authentication failed' }
                    11 { 'Invalid address' }
                    12 { 'Credentials required' }
                    default { "Status $connStatus" }
                }

                # Determine adapter speed display
                $speedDesc = if ($adapter.Speed) {
                    "$([math]::Round($adapter.Speed / 1000000, 0)) Mbps"
                } else { 'Unknown' }

                $results += [PSCustomObject]@{
                    DomainController = $dc.Name
                    AdapterName      = $adapter.Name
                    Status           = $statusDesc
                    IPAddress        = $ipAddress
                    Speed            = $speedDesc
                    IsHealthy        = -not $hasIssue
                    HasIssue         = $hasIssue
                    Severity         = if ($hasIssue) { 'High' } else { 'Info' }
                    Message          = if ($hasIssue) {
                        "Adapter '$($adapter.Name)' on $($dc.Name) is not connected: $statusDesc"
                    } else {
                        "Adapter '$($adapter.Name)' on $($dc.Name) is $statusDesc (IP: $ipAddress, Speed: $speedDesc)"
                    }
                }
            }

            if (@($adapters).Count -eq 0) {
                $results += [PSCustomObject]@{
                    DomainController = $dc.Name
                    AdapterName      = 'N/A'
                    Status           = 'Unknown'
                    IPAddress        = 'N/A'
                    Speed            = 'N/A'
                    IsHealthy        = $true
                    HasIssue         = $false
                    Severity         = 'Info'
                    Message          = "No physical network adapters found via WMI on $($dc.Name)"
                }
            }
        }
        catch {
            Write-Warning "[DC-012] Failed to check network adapters on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                AdapterName      = 'Unknown'
                Status           = 'Error'
                IPAddress        = 'N/A'
                Speed            = 'N/A'
                IsHealthy        = $false
                HasIssue         = $true
                Severity         = 'Error'
                Message          = "Failed to query network adapters on $($dc.Name): $_"
            }
        }
    }

    Write-Verbose "[DC-012] Check complete. Results: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[DC-012] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        AdapterName      = 'Unknown'
        Status           = 'Error'
        IPAddress        = 'N/A'
        Speed            = 'N/A'
        IsHealthy        = $false
        HasIssue         = $true
        Severity         = 'Error'
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
