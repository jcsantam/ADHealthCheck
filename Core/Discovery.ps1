<#
.SYNOPSIS
    Active Directory topology discovery module

.DESCRIPTION
    Discovers and inventories Active Directory infrastructure including:
    - Forest and domain information
    - Domain Controllers (all DCs in forest)
    - Sites and subnets
    - FSMO role holders
    - Global Catalog servers
    - Trust relationships
    - Basic performance counters

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Requires: Active Directory PowerShell module or .NET DirectoryServices
#>

# Import logger if available
if (Test-Path "$PSScriptRoot\Logger.ps1") {
    . "$PSScriptRoot\Logger.ps1"
}

# =============================================================================
# FUNCTION: Invoke-ADDiscovery
# Purpose: Main discovery function - discovers entire AD topology
# =============================================================================
function Invoke-ADDiscovery {
    <#
    .SYNOPSIS
        Discovers Active Directory topology
    
    .PARAMETER IncludePerformanceCounters
        Include performance counter collection for DCs
    
    .PARAMETER ConnectionTimeout
        Timeout in seconds for connectivity tests
    
    .EXAMPLE
        $inventory = Invoke-ADDiscovery
    
    .EXAMPLE
        $inventory = Invoke-ADDiscovery -IncludePerformanceCounters $true
    
    .OUTPUTS
        PSCustomObject with discovered inventory
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [bool]$IncludePerformanceCounters = $false,
        
        [Parameter(Mandatory = $false)]
        [int]$ConnectionTimeout = 30
    )
    
    Write-LogInfo "Starting AD topology discovery..." -Category "Discovery"
    
    $discoveryStart = Get-Date
    
    try {
        # Initialize inventory object
        $inventory = [PSCustomObject]@{
            DiscoveryTime = Get-Date
            ForestInfo = $null
            Domains = @()
            DomainControllers = @()
            Sites = @()
            Subnets = @()
            FSMORoles = @()
            Trusts = @()
            GlobalCatalogs = @()
            Statistics = @{
                TotalDCs = 0
                TotalSites = 0
                TotalSubnets = 0
                TotalDomains = 0
                DiscoveryDurationSeconds = 0
            }
        }
        
        # Step 1: Discover Forest
        Write-LogInfo "Discovering forest information..." -Category "Discovery"
        $inventory.ForestInfo = Get-ForestInfo
        
        # Step 2: Discover Domains
        Write-LogInfo "Discovering domains in forest..." -Category "Discovery"
        $inventory.Domains = Get-DomainInfo -Forest $inventory.ForestInfo
        
        # Step 3: Discover Domain Controllers
        Write-LogInfo "Discovering domain controllers..." -Category "Discovery"
        $inventory.DomainControllers = Get-DomainControllerInfo `
            -Domains $inventory.Domains `
            -IncludePerformanceCounters $IncludePerformanceCounters `
            -ConnectionTimeout $ConnectionTimeout
        
        # Step 4: Discover Sites
        Write-LogInfo "Discovering sites..." -Category "Discovery"
        $inventory.Sites = Get-SiteInfo -Forest $inventory.ForestInfo
        
        # Step 5: Discover Subnets
        Write-LogInfo "Discovering subnets..." -Category "Discovery"
        $inventory.Subnets = Get-SubnetInfo -Forest $inventory.ForestInfo
        
        # Step 6: Discover FSMO Roles
        Write-LogInfo "Discovering FSMO role holders..." -Category "Discovery"
        $inventory.FSMORoles = Get-FSMORoleInfo -Forest $inventory.ForestInfo -Domains $inventory.Domains
        
        # Step 7: Discover Trusts
        Write-LogInfo "Discovering trust relationships..." -Category "Discovery"
        $inventory.Trusts = Get-TrustInfo -Domains $inventory.Domains
        
        # Step 8: Identify Global Catalogs
        Write-LogInfo "Identifying Global Catalog servers..." -Category "Discovery"
        $inventory.GlobalCatalogs = $inventory.DomainControllers | Where-Object { $_.IsGlobalCatalog -eq $true }
        
        # Calculate statistics
        $inventory.Statistics.TotalDCs = @($inventory.DomainControllers).Count
        $inventory.Statistics.TotalSites = @($inventory.Sites).Count
        $inventory.Statistics.TotalSubnets = @($inventory.Subnets).Count
        $inventory.Statistics.TotalDomains = @($inventory.Domains).Count
        $inventory.Statistics.DiscoveryDurationSeconds = ((Get-Date) - $discoveryStart).TotalSeconds
        
        Write-LogInfo "Discovery completed successfully" -Category "Discovery"
        Write-LogInfo "  Forest: $($inventory.ForestInfo.Name)" -Category "Discovery"
        Write-LogInfo "  Domains: $($inventory.Statistics.TotalDomains)" -Category "Discovery"
        Write-LogInfo "  DCs: $($inventory.Statistics.TotalDCs)" -Category "Discovery"
        Write-LogInfo "  Sites: $($inventory.Statistics.TotalSites)" -Category "Discovery"
        Write-LogInfo "  Subnets: $($inventory.Statistics.TotalSubnets)" -Category "Discovery"
        Write-LogInfo "  Duration: $([math]::Round($inventory.Statistics.DiscoveryDurationSeconds, 2))s" -Category "Discovery"
        
        return $inventory
    }
    catch {
        Write-LogError "Discovery failed: $($_.Exception.Message)" -Category "Discovery" -Exception $_.Exception
        throw
    }
}

# =============================================================================
# FUNCTION: Get-ForestInfo
# Purpose: Get forest-level information
# =============================================================================
function Get-ForestInfo {
    <#
    .SYNOPSIS
        Gets information about the current AD forest
    #>
    
    try {
        $forest = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        
        return [PSCustomObject]@{
            Name = $forest.Name
            RootDomain = $forest.RootDomain.Name
            ForestMode = $forest.ForestMode.ToString()
            ForestModeLevel = $forest.ForestModeLevel
            SchemaMaster = $forest.SchemaRoleOwner.Name
            NamingMaster = $forest.NamingRoleOwner.Name
            Sites = @($forest.Sites | ForEach-Object { $_.Name })
            GlobalCatalogs = @($forest.GlobalCatalogs | ForEach-Object { $_.Name })
            ApplicationPartitions = @($forest.ApplicationPartitions | ForEach-Object { $_.Name })
        }
    }
    catch {
        Write-LogError "Failed to get forest information: $($_.Exception.Message)" -Category "Discovery" -Exception $_.Exception
        throw
    }
}

# =============================================================================
# FUNCTION: Get-DomainInfo
# Purpose: Get information about all domains in forest
# =============================================================================
function Get-DomainInfo {
    <#
    .SYNOPSIS
        Gets information about all domains in the forest
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Forest
    )
    
    $domains = @()
    
    try {
        $forestObj = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        
        foreach ($domain in $forestObj.Domains) {
            try {
                $domainInfo = [PSCustomObject]@{
                    Name = $domain.Name
                    NetBIOSName = $domain.Name.Split('.')[0].ToUpper()
                    DomainMode = $domain.DomainMode.ToString()
                    DomainModeLevel = $domain.DomainModeLevel
                    PDCEmulator = $domain.PdcRoleOwner.Name
                    RIDMaster = $domain.RidRoleOwner.Name
                    InfrastructureMaster = $domain.InfrastructureRoleOwner.Name
                    Parent = if ($domain.Parent) { $domain.Parent.Name } else { $null }
                    Children = @($domain.Children | ForEach-Object { $_.Name })
                    DomainControllers = @($domain.DomainControllers | ForEach-Object { $_.Name })
                }
                
                $domains += $domainInfo
                Write-LogVerbose "Discovered domain: $($domainInfo.Name)" -Category "Discovery"
            }
            catch {
                Write-LogWarning "Failed to get details for domain $($domain.Name): $($_.Exception.Message)" -Category "Discovery"
            }
        }
    }
    catch {
        Write-LogError "Failed to enumerate domains: $($_.Exception.Message)" -Category "Discovery" -Exception $_.Exception
        throw
    }
    
    return $domains
}

# =============================================================================
# FUNCTION: Get-DomainControllerInfo
# Purpose: Get detailed information about all domain controllers
# =============================================================================
function Get-DomainControllerInfo {
    <#
    .SYNOPSIS
        Gets detailed information about all domain controllers
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Domains,
        
        [Parameter(Mandatory = $false)]
        [bool]$IncludePerformanceCounters = $false,
        
        [Parameter(Mandatory = $false)]
        [int]$ConnectionTimeout = 30
    )
    
    $allDCs = @()
    
    foreach ($domain in $Domains) {
        Write-LogVerbose "Enumerating DCs in domain: $($domain.Name)" -Category "Discovery"
        
        try {
            $domainObj = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain(
                (New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $domain.Name))
            )
            
            foreach ($dc in $domainObj.DomainControllers) {
                try {
                    $dcInfo = [PSCustomObject]@{
                        Name = $dc.Name
                        HostName = $dc.Name.Split('.')[0]
                        Domain = $domain.Name
                        IPAddress = $dc.IPAddress
                        SiteName = $dc.SiteName
                        OSVersion = $dc.OSVersion
                        IsGlobalCatalog = $dc.IsGlobalCatalog()
                        Roles = @($dc.Roles)
                        Forest = $dc.Forest.Name
                        # Connectivity
                        IsReachable = $null
                        ResponseTimeMs = $null
                        # Performance (populated if requested)
                        CPUPercent = $null
                        MemoryUsedMB = $null
                        MemoryAvailableMB = $null
                    }
                    
                    # Test connectivity
                    Write-LogVerbose "Testing connectivity to DC: $($dc.Name)" -Category "Discovery"
                    $pingResult = Test-DCConnectivity -ComputerName $dc.Name -Timeout $ConnectionTimeout
                    $dcInfo.IsReachable = $pingResult.Success
                    $dcInfo.ResponseTimeMs = $pingResult.ResponseTimeMs
                    
                    # Get performance counters if requested and DC is reachable
                    if ($IncludePerformanceCounters -and $dcInfo.IsReachable) {
                        Write-LogVerbose "Collecting performance counters from DC: $($dc.Name)" -Category "Discovery"
                        $perfCounters = Get-DCPerformanceCounters -ComputerName $dc.Name
                        if ($perfCounters) {
                            $dcInfo.CPUPercent = $perfCounters.CPUPercent
                            $dcInfo.MemoryUsedMB = $perfCounters.MemoryUsedMB
                            $dcInfo.MemoryAvailableMB = $perfCounters.MemoryAvailableMB
                        }
                    }
                    
                    $allDCs += $dcInfo
                    
                    $reachableStatus = if ($dcInfo.IsReachable) { "reachable" } else { "UNREACHABLE" }
                    Write-LogVerbose "  DC: $($dcInfo.Name) - $reachableStatus - Site: $($dcInfo.SiteName)" -Category "Discovery"
                }
                catch {
                    Write-LogWarning "Failed to get details for DC $($dc.Name): $($_.Exception.Message)" -Category "Discovery"
                }
            }
        }
        catch {
            Write-LogWarning "Failed to enumerate DCs in domain $($domain.Name): $($_.Exception.Message)" -Category "Discovery"
        }
    }
    
    return $allDCs
}

# =============================================================================
# FUNCTION: Test-DCConnectivity
# Purpose: Test connectivity to a domain controller
# =============================================================================
function Test-DCConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to a domain controller
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        
        [Parameter(Mandatory = $false)]
        [int]$Timeout = 30
    )
    
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $pingResult = $ping.Send($ComputerName, ($Timeout * 1000))
        
        return [PSCustomObject]@{
            Success = ($pingResult.Status -eq 'Success')
            ResponseTimeMs = if ($pingResult.Status -eq 'Success') { $pingResult.RoundtripTime } else { $null }
        }
    }
    catch {
        return [PSCustomObject]@{
            Success = $false
            ResponseTimeMs = $null
        }
    }
}

# =============================================================================
# FUNCTION: Get-DCPerformanceCounters
# Purpose: Get basic performance counters from a DC
# =============================================================================
function Get-DCPerformanceCounters {
    <#
    .SYNOPSIS
        Gets performance counters from a domain controller
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )
    
    try {
        # Get CPU usage
        $cpu = Get-WmiObject -Class Win32_Processor -ComputerName $ComputerName -ErrorAction Stop |
            Measure-Object -Property LoadPercentage -Average |
            Select-Object -ExpandProperty Average
        
        # Get memory info
        $os = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName -ErrorAction Stop
        $totalMemoryMB = [math]::Round($os.TotalVisibleMemorySize / 1KB, 0)
        $freeMemoryMB = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
        $usedMemoryMB = $totalMemoryMB - $freeMemoryMB
        
        return [PSCustomObject]@{
            CPUPercent = $cpu
            MemoryUsedMB = $usedMemoryMB
            MemoryAvailableMB = $freeMemoryMB
        }
    }
    catch {
        Write-LogVerbose "Could not get performance counters from $ComputerName : $($_.Exception.Message)" -Category "Discovery"
        return $null
    }
}

# =============================================================================
# FUNCTION: Get-SiteInfo
# Purpose: Get information about AD sites
# =============================================================================
function Get-SiteInfo {
    <#
    .SYNOPSIS
        Gets information about all AD sites
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Forest
    )
    
    $sites = @()
    
    try {
        $forestObj = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        
        foreach ($site in $forestObj.Sites) {
            $siteInfo = [PSCustomObject]@{
                Name = $site.Name
                Location = $site.Location
                Subnets = @($site.Subnets | ForEach-Object { $_.Name })
                Servers = @($site.Servers | ForEach-Object { $_.Name })
                AdjacentSites = @($site.AdjacentSites | ForEach-Object { $_.Name })
                SiteLinks = @($site.SiteLinks | ForEach-Object { $_.Name })
                InterSiteTopologyGenerator = if ($site.InterSiteTopologyGenerator) { $site.InterSiteTopologyGenerator.Name } else { $null }
                Options = $site.Options
            }
            
            $sites += $siteInfo
        }
    }
    catch {
        Write-LogError "Failed to get site information: $($_.Exception.Message)" -Category "Discovery" -Exception $_.Exception
    }
    
    return $sites
}

# =============================================================================
# FUNCTION: Get-SubnetInfo
# Purpose: Get information about AD subnets
# =============================================================================
function Get-SubnetInfo {
    <#
    .SYNOPSIS
        Gets information about all AD subnets
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Forest
    )
    
    $subnets = @()
    
    try {
        $forestObj = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
        
        foreach ($site in $forestObj.Sites) {
            foreach ($subnet in $site.Subnets) {
                $subnetInfo = [PSCustomObject]@{
                    Name = $subnet.Name
                    Site = $site.Name
                    Location = $subnet.Location
                }
                
                $subnets += $subnetInfo
            }
        }
    }
    catch {
        Write-LogError "Failed to get subnet information: $($_.Exception.Message)" -Category "Discovery" -Exception $_.Exception
    }
    
    return $subnets
}

# =============================================================================
# FUNCTION: Get-FSMORoleInfo
# Purpose: Get FSMO role holder information
# =============================================================================
function Get-FSMORoleInfo {
    <#
    .SYNOPSIS
        Gets FSMO role holder information
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Forest,
        
        [Parameter(Mandatory = $true)]
        $Domains
    )
    
    $fsmoRoles = @()
    
    # Forest-level roles
    $fsmoRoles += [PSCustomObject]@{
        Role = "Schema Master"
        Scope = "Forest"
        Holder = $Forest.SchemaMaster
        Domain = $Forest.RootDomain
    }
    
    $fsmoRoles += [PSCustomObject]@{
        Role = "Domain Naming Master"
        Scope = "Forest"
        Holder = $Forest.NamingMaster
        Domain = $Forest.RootDomain
    }
    
    # Domain-level roles
    foreach ($domain in $Domains) {
        $fsmoRoles += [PSCustomObject]@{
            Role = "PDC Emulator"
            Scope = "Domain"
            Holder = $domain.PDCEmulator
            Domain = $domain.Name
        }
        
        $fsmoRoles += [PSCustomObject]@{
            Role = "RID Master"
            Scope = "Domain"
            Holder = $domain.RIDMaster
            Domain = $domain.Name
        }
        
        $fsmoRoles += [PSCustomObject]@{
            Role = "Infrastructure Master"
            Scope = "Domain"
            Holder = $domain.InfrastructureMaster
            Domain = $domain.Name
        }
    }
    
    return $fsmoRoles
}

# =============================================================================
# FUNCTION: Get-TrustInfo
# Purpose: Get trust relationship information
# =============================================================================
function Get-TrustInfo {
    <#
    .SYNOPSIS
        Gets trust relationship information
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Domains
    )
    
    $trusts = @()
    
    foreach ($domain in $Domains) {
        try {
            $domainObj = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain(
                (New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $domain.Name))
            )
            
            foreach ($trust in $domainObj.GetAllTrustRelationships()) {
                $trustInfo = [PSCustomObject]@{
                    SourceDomain = $domain.Name
                    TargetDomain = $trust.TargetName
                    TrustType = $trust.TrustType.ToString()
                    TrustDirection = $trust.TrustDirection.ToString()
                }
                
                $trusts += $trustInfo
            }
        }
        catch {
            Write-LogVerbose "Could not get trusts for domain $($domain.Name): $($_.Exception.Message)" -Category "Discovery"
        }
    }
    
    return $trusts
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================



