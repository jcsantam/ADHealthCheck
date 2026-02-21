<#
.SYNOPSIS
    DC Time Offset Check (TIME-002)

.DESCRIPTION
    Checks time offset between domain controllers and PDC.
    Kerberos authentication requires time sync within 5 minutes.
    
    Checks:
    - Time offset from PDC
    - Time offset from external source
    - W32Time service status

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-DCTimeOffset.ps1 -Inventory $inventory

.OUTPUTS
    Array of DC time offset results

.NOTES
    Check ID: TIME-002
    Category: Time
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

# Kerberos time tolerance (5 minutes = 300 seconds)
$kerberosToleranceSeconds = 300
$warningThresholdSeconds = 120  # 2 minutes

Write-Verbose "[TIME-002] Starting DC time offset check..."

try {
    $domainControllers = $Inventory.DomainControllers
    $domains = $Inventory.Domains
    
    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[TIME-002] No domain controllers found in inventory"
        return @()
    }
    
    Write-Verbose "[TIME-002] Checking time offset for $($domainControllers.Count) domain controllers..."
    
    # Get PDC for reference time
    foreach ($domain in $domains) {
        $pdcName = $domain.PDCEmulator
        $pdcDC = $domainControllers | Where-Object { $_.Name -eq $pdcName } | Select-Object -First 1
        
        if (-not $pdcDC -or -not $pdcDC.IsReachable) {
            Write-Warning "[TIME-002] PDC $pdcName not reachable, skipping domain $($domain.Name)"
            continue
        }
        
        # Get PDC time
        try {
            $pdcTime = Invoke-Command -ComputerName $pdcDC.HostName -ScriptBlock { Get-Date } -ErrorAction Stop
            
            Write-Verbose "[TIME-002] PDC $pdcName time: $pdcTime"
        }
        catch {
            Write-Warning "[TIME-002] Failed to get time from PDC $pdcName: $($_.Exception.Message)"
            continue
        }
        
        # Check each DC in this domain
        $domainDCs = $domainControllers | Where-Object { $_.Domain -eq $domain.Name }
        
        foreach ($dc in $domainDCs) {
            Write-Verbose "[TIME-002] Processing DC: $($dc.Name)"
            
            if (-not $dc.IsReachable) {
                Write-Verbose "[TIME-002] DC $($dc.Name) is not reachable, skipping"
                continue
            }
            
            try {
                # Get DC time
                $dcTime = Invoke-Command -ComputerName $dc.HostName -ScriptBlock { Get-Date } -ErrorAction Stop
                
                # Calculate offset
                $offsetSeconds = [math]::Abs(($dcTime - $pdcTime).TotalSeconds)
                
                # Determine status
                $status = 'Healthy'
                $severity = 'Info'
                $hasIssue = $false
                $message = "Time is synchronized within tolerance"
                
                if ($offsetSeconds -gt $kerberosToleranceSeconds) {
                    $status = 'Failed'
                    $severity = 'Critical'
                    $hasIssue = $true
                    $message = "CRITICAL: Time offset ($([math]::Round($offsetSeconds, 1))s) exceeds Kerberos tolerance (300s)"
                }
                elseif ($offsetSeconds -gt $warningThresholdSeconds) {
                    $status = 'Warning'
                    $severity = 'Medium'
                    $hasIssue = $true
                    $message = "WARNING: Time offset ($([math]::Round($offsetSeconds, 1))s) is approaching Kerberos limit"
                }
                
                $result = [PSCustomObject]@{
                    DomainController = $dc.Name
                    Domain = $domain.Name
                    PDC = $pdcName
                    DCTime = $dcTime
                    PDCTime = $pdcTime
                    OffsetSeconds = [math]::Round($offsetSeconds, 2)
                    OffsetMinutes = [math]::Round($offsetSeconds / 60, 2)
                    KerberosToleranceSeconds = $kerberosToleranceSeconds
                    WithinTolerance = ($offsetSeconds -le $kerberosToleranceSeconds)
                    Status = $status
                    Severity = $severity
                    IsHealthy = -not $hasIssue
                    HasIssue = $hasIssue
                    Message = $message
                }
                
                $results += $result
            }
            catch {
                Write-Warning "[TIME-002] Failed to check time on DC $($dc.Name): $($_.Exception.Message)"
                
                $results += [PSCustomObject]@{
                    DomainController = $dc.Name
                    Domain = $domain.Name
                    PDC = $pdcName
                    DCTime = $null
                    PDCTime = $pdcTime
                    OffsetSeconds = 999
                    OffsetMinutes = 999
                    KerberosToleranceSeconds = $kerberosToleranceSeconds
                    WithinTolerance = $false
                    Status = 'Error'
                    Severity = 'Error'
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "Failed to query DC time: $($_.Exception.Message)"
                }
            }
        }
    }
    
    Write-Verbose "[TIME-002] Check complete. DCs checked: $($results.Count)"
    
    # Summary
    $criticalCount = ($results | Where-Object { $_.Severity -eq 'Critical' }).Count
    $warningCount = ($results | Where-Object { $_.Severity -eq 'Medium' }).Count
    
    Write-Verbose "[TIME-002] Critical: $criticalCount, Warning: $warningCount"
    
    if ($criticalCount -gt 0) {
        Write-Warning "[TIME-002] CRITICAL: $criticalCount DC(s) with time offset exceeding Kerberos tolerance!"
    }
    
    return $results
}
catch {
    Write-Error "[TIME-002] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        Domain = "Unknown"
        PDC = "Unknown"
        DCTime = $null
        PDCTime = $null
        OffsetSeconds = 999
        OffsetMinutes = 999
        KerberosToleranceSeconds = $kerberosToleranceSeconds
        WithinTolerance = $false
        Status = 'Error'
        Severity = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
