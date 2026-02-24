<#
.SYNOPSIS
    GPO Replication Status Check (GPO-002)

.DESCRIPTION
    Validates GPO replication consistency between Active Directory and SYSVOL.
    Detects version mismatches and replication lag.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: GPO-002
    Category: GPO
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

Write-Verbose "[GPO-002] Starting GPO replication status check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[GPO-002] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[GPO-002] Checking GPO replication for domain: $($domain.Name)"
        
        try {
            # Get all GPOs
            $gpos = Get-GPO -All -Domain $domain.Name -ErrorAction Stop
            
            Write-Verbose "[GPO-002] Found $($gpos.Count) GPOs in $($domain.Name)"
            
            $mismatchCount = 0
            $healthyCount = 0
            
            foreach ($gpo in $gpos) {
                # Get versions
                $adUserVersion = $gpo.User.DSVersion
                $adComputerVersion = $gpo.Computer.DSVersion
                $sysvolUserVersion = $gpo.User.SysvolVersion
                $sysvolComputerVersion = $gpo.Computer.SysvolVersion
                
                # Check for version mismatches
                $userMismatch = ($adUserVersion -ne $sysvolUserVersion)
                $computerMismatch = ($adComputerVersion -ne $sysvolComputerVersion)
                
                if ($userMismatch -or $computerMismatch) {
                    $mismatchCount++
                    
                    $result = [PSCustomObject]@{
                        Domain = $domain.Name
                        GPOName = $gpo.DisplayName
                        GPOID = $gpo.Id
                        ADUserVersion = $adUserVersion
                        SYSVOLUserVersion = $sysvolUserVersion
                        ADComputerVersion = $adComputerVersion
                        SYSVOLComputerVersion = $sysvolComputerVersion
                        UserMismatch = $userMismatch
                        ComputerMismatch = $computerMismatch
                        Severity = 'High'
                        Status = 'Warning'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = if ($userMismatch -and $computerMismatch) {
                            "Version mismatch: User (AD:$adUserVersion/SYSVOL:$sysvolUserVersion), Computer (AD:$adComputerVersion/SYSVOL:$sysvolComputerVersion)"
                        }
                        elseif ($userMismatch) {
                            "User policy version mismatch: AD:$adUserVersion vs SYSVOL:$sysvolUserVersion"
                        }
                        else {
                            "Computer policy version mismatch: AD:$adComputerVersion vs SYSVOL:$sysvolComputerVersion"
                        }
                    }
                    
                    $results += $result
                }
                else {
                    $healthyCount++
                }
            }
            
            # Summary result
            $summaryResult = [PSCustomObject]@{
                Domain = $domain.Name
                GPOName = "SUMMARY"
                GPOID = "N/A"
                ADUserVersion = 0
                SYSVOLUserVersion = 0
                ADComputerVersion = 0
                SYSVOLComputerVersion = 0
                UserMismatch = $false
                ComputerMismatch = $false
                Severity = if ($mismatchCount -gt 10) { 'Critical' }
                          elseif ($mismatchCount -gt 0) { 'High' }
                          else { 'Info' }
                Status = if ($mismatchCount -gt 0) { 'Warning' } else { 'Healthy' }
                IsHealthy = ($mismatchCount -eq 0)
                HasIssue = ($mismatchCount -gt 0)
                Message = "Total GPOs: $($gpos.Count), Mismatches: $mismatchCount, Healthy: $healthyCount"
            }
            
            $results += $summaryResult
        }
        catch {
            Write-Warning "[GPO-002] Failed to check GPOs for $($domain.Name): $_"
            
            $results += [PSCustomObject]@{
                Domain = $domain.Name
                GPOName = "ERROR"
                GPOID = "N/A"
                ADUserVersion = 0
                SYSVOLUserVersion = 0
                ADComputerVersion = 0
                SYSVOLComputerVersion = 0
                UserMismatch = $false
                ComputerMismatch = $false
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query GPOs: $_"
            }
        }
    }
    
    Write-Verbose "[GPO-002] Check complete. Results: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[GPO-002] Check failed: $_"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        GPOName = "ERROR"
        GPOID = "N/A"
        ADUserVersion = 0
        SYSVOLUserVersion = 0
        ADComputerVersion = 0
        SYSVOLComputerVersion = 0
        UserMismatch = $false
        ComputerMismatch = $false
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
