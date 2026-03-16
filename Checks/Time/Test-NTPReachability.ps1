<#
.SYNOPSIS
    NTP Server Reachability Check (TIME-003)

.DESCRIPTION
    Tests UDP port 123 reachability for all NTP servers configured on the PDC Emulator
    of each domain. An unreachable NTP server means the PDC cannot synchronize time
    with its upstream source.

    Checks:
    - Parses NTP server list from w32tm configuration on PDC
    - Tests UDP port 123 connectivity with 3-second timeout per server
    - Reports any configured servers that cannot be reached

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-NTPReachability.ps1 -Inventory $inventory

.OUTPUTS
    Array of NTP server reachability results

.NOTES
    Check ID: TIME-003
    Category: Time
    Severity: High
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[TIME-003] Starting NTP server reachability check..."

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[TIME-003] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        $pdcName = $domain.PDCEmulator

        Write-Verbose "[TIME-003] Checking NTP servers on PDC: $pdcName for domain $($domain.Name)"

        $pdcDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $pdcName } | Select-Object -First 1

        if (-not $pdcDC -or -not $pdcDC.IsReachable) {
            Write-Warning "[TIME-003] PDC $pdcName is not reachable, skipping domain $($domain.Name)"
            $results += [PSCustomObject]@{
                Domain       = $domain.Name
                PDCEmulator  = $pdcName
                NTPServer    = 'N/A'
                IsReachable  = $false
                HasIssue     = $true
                Status       = 'Error'
                Severity     = 'Error'
                IsHealthy    = $false
                Message      = "PDC $pdcName is not reachable; cannot check NTP configuration"
            }
            continue
        }

        try {
            $w32tmConfig = w32tm /query /computer:$pdcName /configuration 2>&1

            # Find the NtpServer line
            $ntpLine = $w32tmConfig | Where-Object { $_ -match 'NtpServer:' }

            $ntpServers = @()

            if ($ntpLine -match 'NtpServer:\s*(.+)') {
                $rawValue = $matches[1].Trim()
                # Remove trailing "(Local)" or similar annotations added by w32tm
                $rawValue = $rawValue -replace '\s*\(Local\)', ''
                $rawValue = $rawValue.Trim()

                if ($rawValue -ne '' -and $rawValue -ne 'time.windows.com,0x9' -or $rawValue -ne '') {
                    # Split on spaces or commas to get individual server entries
                    $entries = $rawValue -split '[\s,]+'
                    foreach ($entry in $entries) {
                        $entry = $entry.Trim()
                        if ($entry -eq '') { continue }
                        # Strip flag suffixes like ,0x1 ,0x9 etc — entry may be "server,0x1" or just "server"
                        if ($entry -match '^([^,]+),0x') {
                            $serverHost = $matches[1].Trim()
                        }
                        else {
                            $serverHost = $entry
                        }
                        if ($serverHost -ne '' -and $ntpServers -notcontains $serverHost) {
                            $ntpServers += $serverHost
                        }
                    }
                }
            }

            if ($ntpServers.Count -eq 0) {
                # No NTP servers configured - PDC may be using NT5DS or local clock.
                # Absence of NTP config is evaluated by TIME-001/TIME-004; skip here.
                Write-Verbose "[TIME-003] No NTP servers configured on PDC $pdcName - skipping reachability test"
                $results += [PSCustomObject]@{
                    Domain       = $domain.Name
                    PDCEmulator  = $pdcName
                    NTPServer    = 'None configured'
                    IsReachable  = $true
                    HasIssue     = $false
                    Status       = 'Pass'
                    Severity     = 'Info'
                    IsHealthy    = $true
                    Message      = "No external NTP servers configured on PDC $pdcName - reachability test not applicable"
                }
                continue
            }

            Write-Verbose "[TIME-003] Found $($ntpServers.Count) NTP server(s) on PDC $pdcName"

            foreach ($server in $ntpServers) {
                Write-Verbose "[TIME-003] Testing UDP 123 reachability for: $server"

                $reachable = $false
                try {
                    $udp = New-Object System.Net.Sockets.UdpClient
                    $udp.Client.ReceiveTimeout = 3000
                    try {
                        $udp.Connect($server, 123)
                        $reachable = $true
                    }
                    catch {
                        $reachable = $false
                    }
                    $udp.Close()
                }
                catch {
                    $reachable = $false
                }

                if ($reachable) {
                    $hasIssue = $false
                    $status = 'Pass'
                    $severity = 'Info'
                    $message = "NTP server $server is reachable on UDP port 123"
                }
                else {
                    $hasIssue = $true
                    $status = 'Fail'
                    $severity = 'High'
                    $message = "NTP server $server is NOT reachable on UDP port 123"
                }

                $results += [PSCustomObject]@{
                    Domain       = $domain.Name
                    PDCEmulator  = $pdcName
                    NTPServer    = $server
                    IsReachable  = $reachable
                    HasIssue     = $hasIssue
                    Status       = $status
                    Severity     = $severity
                    IsHealthy    = -not $hasIssue
                    Message      = $message
                }
            }
        }
        catch {
            Write-Warning "[TIME-003] Failed to query NTP configuration on PDC ${pdcName}: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain       = $domain.Name
                PDCEmulator  = $pdcName
                NTPServer    = 'Unknown'
                IsReachable  = $false
                HasIssue     = $true
                Status       = 'Error'
                Severity     = 'Error'
                IsHealthy    = $false
                Message      = "Failed to query NTP configuration: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[TIME-003] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[TIME-003] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain       = 'Unknown'
        PDCEmulator  = 'Unknown'
        NTPServer    = 'Unknown'
        IsReachable  = $false
        HasIssue     = $true
        Status       = 'Error'
        Severity     = 'Error'
        IsHealthy    = $false
        Message      = "Check execution failed: $($_.Exception.Message)"
    })
}
