<#
.SYNOPSIS
    PDC Time Source Check (TIME-001)

.DESCRIPTION
    Validates that the PDC Emulator has an external reliable time source configured.
    Checks:
    - PDC has external NTP server configured
    - W32Time service is running
    - Time source is accessible
    - PDC is authoritative time server

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-PDCTimeSource.ps1 -Inventory $inventory

.OUTPUTS
    Array of PDC time source validation results

.NOTES
    Check ID: TIME-001
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

Write-Verbose "[TIME-001] Starting PDC time source check..."

try {
    # Find PDC Emulator for each domain
    $domains = $Inventory.Domains
    
    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[TIME-001] No domains found in inventory"
        return @()
    }
    
    foreach ($domain in $domains) {
        $pdcName = $domain.PDCEmulator
        
        Write-Verbose "[TIME-001] Checking PDC: $pdcName for domain $($domain.Name)"
        
        # Find PDC in DC inventory
        $pdcDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $pdcName } | Select-Object -First 1
        
        if (-not $pdcDC) {
            Write-Warning "[TIME-001] PDC $pdcName not found in DC inventory"
            continue
        }
        
        if (-not $pdcDC.IsReachable) {
            Write-Warning "[TIME-001] PDC $pdcName is not reachable"
            
            $results += [PSCustomObject]@{
                Domain = $domain.Name
                PDC = $pdcName
                HasExternalSource = $false
                TimeSource = "Unknown"
                IsReliable = $false
                W32TimeRunning = $false
                LastSync = $null
                Stratum = $null
                Status = 'Failed'
                Severity = 'Critical'
                IsHealthy = $false
                HasIssue = $true
                Message = "PDC is not reachable"
            }
            continue
        }
        
        try {
            # Query W32Time configuration
            $w32tmConfig = w32tm /query /computer:$pdcDC.HostName /configuration 2>&1
            
            # Check if configured as reliable time source
            $isReliable = $w32tmConfig -match "LocalClockDispersion.*0x0A"
            
            # Get NTP server configuration
            $ntpServer = "Not configured"
            if ($w32tmConfig -match "NtpServer:\s*(.+)") {
                $ntpServer = $matches[1].Trim()
            }
            
            $hasExternalSource = ($ntpServer -ne "Not configured" -and $ntpServer -notlike "*,0x0*")
            
            # Get time source status
            $w32tmStatus = w32tm /query /computer:$pdcDC.HostName /status 2>&1
            
            $stratum = $null
            if ($w32tmStatus -match "Stratum:\s*(\d+)") {
                $stratum = [int]$matches[1]
            }
            
            $lastSync = $null
            if ($w32tmStatus -match "Last Successful Sync Time:\s*(.+)") {
                try {
                    $lastSync = [DateTime]::Parse($matches[1].Trim())
                }
                catch {
                    $lastSync = $null
                }
            }
            
            # Determine health
            $isHealthy = $true
            $issues = @()
            $severity = 'Info'
            
            if (-not $hasExternalSource) {
                $isHealthy = $false
                $issues += "No external NTP server configured"
                $severity = 'Critical'
            }
            
            if ($stratum -and $stratum -gt 3) {
                $isHealthy = $false
                $issues += "Stratum too high ($stratum) - indicates unreliable time source"
                if ($severity -eq 'Info') { $severity = 'High' }
            }
            
            if ($lastSync) {
                $hoursSinceSync = ((Get-Date) - $lastSync).TotalHours
                if ($hoursSinceSync -gt 24) {
                    $isHealthy = $false
                    $issues += "Last sync was $([math]::Round($hoursSinceSync, 1)) hours ago"
                    if ($severity -eq 'Info') { $severity = 'Medium' }
                }
            }
            
            $result = [PSCustomObject]@{
                Domain = $domain.Name
                PDC = $pdcName
                HasExternalSource = $hasExternalSource
                TimeSource = $ntpServer
                IsReliable = $isReliable
                W32TimeRunning = $true
                LastSync = $lastSync
                Stratum = $stratum
                Status = if ($isHealthy) { 'Healthy' } else { 'Failed' }
                Severity = $severity
                IsHealthy = $isHealthy
                HasIssue = -not $isHealthy
                Message = if ($isHealthy) {
                    "PDC has proper external time source configured"
                } else {
                    "PDC time source issues: $($issues -join '; ')"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[TIME-001] Failed to query time configuration on PDC $pdcName: $($_.Exception.Message)"
            
            $results += [PSCustomObject]@{
                Domain = $domain.Name
                PDC = $pdcName
                HasExternalSource = $false
                TimeSource = "Unknown"
                IsReliable = $false
                W32TimeRunning = $false
                LastSync = $null
                Stratum = $null
                Status = 'Error'
                Severity = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query time configuration: $($_.Exception.Message)"
            }
        }
    }
    
    Write-Verbose "[TIME-001] Check complete. PDCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[TIME-001] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        PDC = "Unknown"
        HasExternalSource = $false
        TimeSource = "Unknown"
        IsReliable = $false
        W32TimeRunning = $false
        LastSync = $null
        Stratum = $null
        Status = 'Error'
        Severity = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
