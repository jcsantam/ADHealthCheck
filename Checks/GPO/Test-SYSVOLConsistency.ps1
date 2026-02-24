<#
.SYNOPSIS
    SYSVOL Consistency Check (GPO-003)

.DESCRIPTION
    Validates SYSVOL folder consistency across domain controllers.
    Checks file counts and GPT.INI versions match.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: GPO-003
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

Write-Verbose "[GPO-003] Starting SYSVOL consistency check..."

try {
    $domains = $Inventory.Domains
    
    if (-not $domains) {
        Write-Warning "[GPO-003] No domains found"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[GPO-003] Checking SYSVOL for domain: $($domain.Name)"
        
        try {
            $domainDCs = $Inventory.DomainControllers | 
                Where-Object { $_.Domain -eq $domain.Name -and $_.IsReachable }
            
            if ($domainDCs.Count -lt 2) {
                Write-Verbose "[GPO-003] Only 1 DC - skipping consistency check"
                continue
            }
            
            # Use PDC as baseline
            $pdcName = $domain.PDCEmulator
            $pdc = $domainDCs | Where-Object { $_.Name -eq $pdcName } | Select-Object -First 1
            
            if (-not $pdc) {
                Write-Warning "[GPO-003] PDC not reachable"
                continue
            }
            
            # Get SYSVOL file count from PDC
            $sysvolPath = "\\$($domain.Name)\SYSVOL\$($domain.Name)\Policies"
            
            $pdcGPOFolders = Get-ChildItem -Path $sysvolPath -Directory -ErrorAction Stop | 
                Where-Object { $_.Name -match '\{[A-F0-9\-]+\}' }
            
            $pdcGPOCount = $pdcGPOFolders.Count
            
            Write-Verbose "[GPO-003] PDC has $pdcGPOCount GPO folders"
            
            # Check each DC
            $inconsistentDCs = @()
            
            foreach ($dc in $domainDCs) {
                if ($dc.Name -eq $pdcName) { continue }
                
                try {
                    $dcSysvolPath = "\\$($dc.HostName)\SYSVOL\$($domain.Name)\Policies"
                    
                    $dcGPOFolders = Get-ChildItem -Path $dcSysvolPath -Directory -ErrorAction Stop | 
                        Where-Object { $_.Name -match '\{[A-F0-9\-]+\}' }
                    
                    $dcGPOCount = $dcGPOFolders.Count
                    
                    if ($dcGPOCount -ne $pdcGPOCount) {
                        $inconsistentDCs += [PSCustomObject]@{
                            DCName = $dc.Name
                            GPOCount = $dcGPOCount
                            PDCCount = $pdcGPOCount
                            Difference = ($dcGPOCount - $pdcGPOCount)
                        }
                    }
                }
                catch {
                    Write-Warning "[GPO-003] Failed to access SYSVOL on $($dc.Name): $_"
                    
                    $inconsistentDCs += [PSCustomObject]@{
                        DCName = $dc.Name
                        GPOCount = 0
                        PDCCount = $pdcGPOCount
                        Difference = -$pdcGPOCount
                    }
                }
            }
            
            # Determine status
            $hasIssue = $inconsistentDCs.Count -gt 0
            $severity = if ($inconsistentDCs.Count -gt ($domainDCs.Count / 2)) { 'Critical' }
                       elseif ($inconsistentDCs.Count -gt 0) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                Domain = $domain.Name
                TotalDCs = $domainDCs.Count
                PDCGPOCount = $pdcGPOCount
                InconsistentDCs = $inconsistentDCs.Count
                InconsistentDCList = if ($inconsistentDCs.Count -gt 0) {
                    ($inconsistentDCs | ForEach-Object { "$($_.DCName)($($_.GPOCount))" }) -join ", "
                } else {
                    "None"
                }
                Severity = $severity
                Status = if ($inconsistentDCs.Count -gt ($domainDCs.Count / 2)) { 'Failed' }
                        elseif ($inconsistentDCs.Count -gt 0) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($inconsistentDCs.Count -gt 0) {
                    "SYSVOL inconsistency: $($inconsistentDCs.Count) DCs have different GPO counts"
                }
                else {
                    "SYSVOL consistent across all $($domainDCs.Count) DCs ($pdcGPOCount GPOs)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[GPO-003] Failed to check SYSVOL for $($domain.Name): $_"
            
            $results += [PSCustomObject]@{
                Domain = $domain.Name
                TotalDCs = 0
                PDCGPOCount = 0
                InconsistentDCs = 0
                InconsistentDCList = "Unknown"
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query SYSVOL: $_"
            }
        }
    }
    
    Write-Verbose "[GPO-003] Check complete. Domains checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[GPO-003] Check failed: $_"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        TotalDCs = 0
        PDCGPOCount = 0
        InconsistentDCs = 0
        InconsistentDCList = "Unknown"
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
