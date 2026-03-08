<#
.SYNOPSIS
    Orphaned GPO Check (GPO-001)

.DESCRIPTION
    Detects orphaned Group Policy Objects:
    - GPOs that exist in AD but not in SYSVOL
    - GPOs that exist in SYSVOL but not in AD
    - Empty GPOs with no settings
    - Unlinked GPOs (not applied anywhere)
    - GPO version mismatches between AD and SYSVOL

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-OrphanedGPOs.ps1 -Inventory $inventory

.OUTPUTS
    Array of orphaned GPO results

.NOTES
    Check ID: GPO-001
    Category: GPO
    Severity: High
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[GPO-001] Starting orphaned GPO check..."

try {
    # Get domain info
    $domains = $Inventory.Domains
    
    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[GPO-001] No domains found in inventory"
        return @()
    }
    
    foreach ($domain in $domains) {
        Write-Verbose "[GPO-001] Processing domain: $($domain.Name)"
        
        try {
            # Get all GPOs from Active Directory
            $adGPOs = Get-GPO -All -Domain $domain.Name -ErrorAction Stop
            
            Write-Verbose "[GPO-001] Found $($adGPOs.Count) GPOs in AD for domain $($domain.Name)"
            
            # Get PDC for SYSVOL access
            $pdc = $domain.PDCEmulator
            $pdcDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $pdc } | Select-Object -First 1
            
            if (-not $pdcDC -or -not $pdcDC.IsReachable) {
                Write-Warning "[GPO-001] PDC $pdc not reachable for domain $($domain.Name)"
                continue
            }
            
            # Get GPOs from SYSVOL
            $sysvolPath = "\\$($domain.Name)\SYSVOL\$($domain.Name)\Policies"
            
            try {
                $sysvolGPOs = Get-ChildItem -Path $sysvolPath -Directory -ErrorAction Stop | 
                    Where-Object { $_.Name -match '\{[A-F0-9\-]+\}' }
                
                Write-Verbose "[GPO-001] Found $($sysvolGPOs.Count) GPO folders in SYSVOL"
            }
            catch {
                Write-Warning "[GPO-001] Failed to access SYSVOL on $($domain.Name): $($_.Exception.Message)"
                continue
            }
            
            # Check each AD GPO
            foreach ($gpo in $adGPOs) {
                $gpoId = $gpo.Id.ToString()
                $gpoGuid = "{$gpoId}"
                
                # Check if GPO exists in SYSVOL
                $sysvolFolder = $sysvolGPOs | Where-Object { $_.Name -eq $gpoGuid }
                
                if (-not $sysvolFolder) {
                    # Orphaned: In AD but not in SYSVOL
                    $result = [PSCustomObject]@{
                        Domain = $domain.Name
                        GPOName = $gpo.DisplayName
                        GPOID = $gpoId
                        OrphanType = "Missing from SYSVOL"
                        CreationTime = $gpo.CreationTime
                        ModificationTime = $gpo.ModificationTime
                        IsLinked = $null
                        IsEmpty = $null
                        VersionAD = $gpo.User.DSVersion
                        VersionSYSVOL = 0
                        Severity = 'High'
                        Status = 'Failed'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = "GPO exists in AD but missing from SYSVOL - may cause replication issues"
                    }
                    
                    $results += $result
                    continue
                }
                
                # Check for version mismatch
                $adUserVersion = $gpo.User.DSVersion
                $adComputerVersion = $gpo.Computer.DSVersion
                
                # Read SYSVOL version from GPT.INI
                $gptIniPath = Join-Path $sysvolFolder.FullName "GPT.INI"
                
                try {
                    $gptContent = Get-Content -Path $gptIniPath -ErrorAction Stop
                    $versionLine = $gptContent | Where-Object { $_ -match "Version=(\d+)" }
                    
                    $sysvolVersion = if ($versionLine -match "Version=(\d+)") {
                        [int]$matches[1]
                    } else {
                        0
                    }
                    
                    # Check for version mismatch
                    if ($adUserVersion -ne ($sysvolVersion -band 0xFFFF)) {
                        $result = [PSCustomObject]@{
                            Domain = $domain.Name
                            GPOName = $gpo.DisplayName
                            GPOID = $gpoId
                            OrphanType = "Version Mismatch"
                            CreationTime = $gpo.CreationTime
                            ModificationTime = $gpo.ModificationTime
                            IsLinked = $null
                            IsEmpty = $null
                            VersionAD = $adUserVersion
                            VersionSYSVOL = $sysvolVersion
                            Severity = 'Medium'
                            Status = 'Warning'
                            IsHealthy = $false
                            HasIssue = $true
                            Message = "GPO version mismatch between AD ($adUserVersion) and SYSVOL ($sysvolVersion)"
                        }
                        
                        $results += $result
                    }
                }
                catch {
                    Write-Verbose "[GPO-001] Could not read GPT.INI for GPO $($gpo.DisplayName): $($_.Exception.Message)"
                }
                
                # Check if GPO is empty (no settings)
                $isEmpty = ($gpo.User.Enabled -eq $false -and $gpo.Computer.Enabled -eq $false)
                
                # Check if GPO is linked anywhere
                try {
                    $gpoReport = [xml](Get-GPOReport -Guid $gpoId -Domain $domain.Name -ReportType Xml -ErrorAction Stop)
                    $linksTo = $gpoReport.GPO.LinksTo
                    $isLinked = ($linksTo -ne $null)
                }
                catch {
                    $isLinked = $null
                }
                
                # Report unlinked empty GPOs
                if ($isEmpty -and -not $isLinked) {
                    $result = [PSCustomObject]@{
                        Domain = $domain.Name
                        GPOName = $gpo.DisplayName
                        GPOID = $gpoId
                        OrphanType = "Empty and Unlinked"
                        CreationTime = $gpo.CreationTime
                        ModificationTime = $gpo.ModificationTime
                        IsLinked = $false
                        IsEmpty = $true
                        VersionAD = $adUserVersion
                        VersionSYSVOL = $sysvolVersion
                        Severity = 'Low'
                        Status = 'Warning'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = "GPO is empty and not linked - candidate for deletion"
                    }
                    
                    $results += $result
                }
            }
            
            # Check for SYSVOL folders without corresponding AD GPOs
            foreach ($sysvolGPO in $sysvolGPOs) {
                $gpoGuid = $sysvolGPO.Name -replace '[{}]', ''
                
                $adGPO = $adGPOs | Where-Object { $_.Id.ToString() -eq $gpoGuid }
                
                if (-not $adGPO) {
                    # Orphaned: In SYSVOL but not in AD
                    $result = [PSCustomObject]@{
                        Domain = $domain.Name
                        GPOName = $sysvolGPO.Name
                        GPOID = $gpoGuid
                        OrphanType = "Missing from AD"
                        CreationTime = $sysvolGPO.CreationTime
                        ModificationTime = $sysvolGPO.LastWriteTime
                        IsLinked = $false
                        IsEmpty = $null
                        VersionAD = 0
                        VersionSYSVOL = $null
                        Severity = 'High'
                        Status = 'Failed'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = "GPO folder exists in SYSVOL but missing from AD - orphaned SYSVOL data"
                    }
                    
                    $results += $result
                }
            }
        }
        catch {
            Write-Error "[GPO-001] Failed to check GPOs for domain $($domain.Name): $($_.Exception.Message)"
        }
    }
    
    # Summary
    if ($results.Count -eq 0) {
        Write-Verbose "[GPO-001] No orphaned or problematic GPOs found"
        
        $results = @([PSCustomObject]@{
            Domain = "All domains"
            GPOName = "N/A"
            GPOID = "N/A"
            OrphanType = "None"
            CreationTime = $null
            ModificationTime = $null
            IsLinked = $null
            IsEmpty = $null
            VersionAD = 0
            VersionSYSVOL = 0
            Severity = 'Info'
            Status = 'Healthy'
            IsHealthy = $true
            HasIssue = $false
            Message = "No orphaned or problematic GPOs detected"
        })
    }
    else {
        Write-Verbose "[GPO-001] Found $($results.Count) GPO issues"
    }
    
    return $results
}
catch {
    Write-Error "[GPO-001] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        GPOName = "Unknown"
        GPOID = "Unknown"
        OrphanType = "Error"
        CreationTime = $null
        ModificationTime = $null
        IsLinked = $null
        IsEmpty = $null
        VersionAD = 0
        VersionSYSVOL = 0
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
