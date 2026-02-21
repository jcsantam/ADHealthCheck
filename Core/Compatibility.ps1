<#
.SYNOPSIS
    Compatibility Detection and Abstraction Layer

.DESCRIPTION
    Detects forest/domain functional levels and DC OS versions,
    then provides abstraction functions that automatically use
    the appropriate method (modern or legacy) based on environment.

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Supports: Windows Server 2012 R2 through 2025
#>

# =============================================================================
# MODULE VARIABLES
# =============================================================================

$script:CompatibilityInfo = $null

# =============================================================================
# FUNCTION: Initialize-CompatibilityLayer
# Purpose: Detect environment and set compatibility flags
# =============================================================================
function Initialize-CompatibilityLayer {
    <#
    .SYNOPSIS
        Detects AD environment and sets compatibility mode
    
    .PARAMETER Inventory
        AD inventory object from Discovery
    
    .EXAMPLE
        Initialize-CompatibilityLayer -Inventory $inventory
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Inventory
    )
    
    Write-Verbose "[Compat] Detecting environment compatibility..."
    
    try {
        # Get forest and domain functional levels
        $forest = Get-ADForest -Server $Inventory.ForestInfo.Name -ErrorAction Stop
        $domain = Get-ADDomain -Server $Inventory.Domains[0].Name -ErrorAction Stop
        
        # Map functional levels to numeric values for comparison
        $forestLevelMap = @{
            'Windows2003Forest' = 2
            'Windows2003InterimForest' = 1
            'Windows2008Forest' = 3
            'Windows2008R2Forest' = 4
            'Windows2012Forest' = 5
            'Windows2012R2Forest' = 6
            'Windows2016Forest' = 7
            'Windows2019Forest' = 8
            'Windows2022Forest' = 9
        }
        
        $forestLevelNum = $forestLevelMap[$forest.ForestMode.ToString()]
        $domainLevelNum = $forestLevelMap[$domain.DomainMode.ToString()]
        
        # Detect oldest DC OS version
        $minDCVersion = "10.0"  # Default to 2016
        $dcVersions = @()
        
        foreach ($dc in $Inventory.DomainControllers) {
            if ($dc.IsReachable) {
                try {
                    $os = Get-WmiObject -Class Win32_OperatingSystem -ComputerName $dc.HostName -ErrorAction Stop
                    $dcVersions += $os.Version
                    
                    if ([version]$os.Version -lt [version]$minDCVersion) {
                        $minDCVersion = $os.Version
                    }
                }
                catch {
                    Write-Verbose "[Compat] Could not detect OS version for $($dc.Name)"
                }
            }
        }
        
        # Determine capabilities
        $hasServer2016Plus = ([version]$minDCVersion -ge [version]"10.0")  # 2016+
        $hasServer2012R2Plus = ([version]$minDCVersion -ge [version]"6.3")  # 2012 R2+
        $hasServer2012Plus = ([version]$minDCVersion -ge [version]"6.2")  # 2012+
        
        # Determine which methods to use
        $useCimInstance = $hasServer2016Plus
        $useModernADCmdlets = $hasServer2012R2Plus
        $supportsDFSR = $hasServer2012R2Plus
        
        # Store compatibility info
        $script:CompatibilityInfo = [PSCustomObject]@{
            ForestMode = $forest.ForestMode.ToString()
            DomainMode = $domain.DomainMode.ToString()
            ForestLevel = $forestLevelNum
            DomainLevel = $domainLevelNum
            MinDCVersion = $minDCVersion
            HasServer2016Plus = $hasServer2016Plus
            HasServer2012R2Plus = $hasServer2012R2Plus
            HasServer2012Plus = $hasServer2012Plus
            UseCimInstance = $useCimInstance
            UseModernADCmdlets = $useModernADCmdlets
            SupportsDFSR = $supportsDFSR
            DCVersions = $dcVersions
        }
        
        Write-Verbose "[Compat] Forest Level: $($forest.ForestMode)"
        Write-Verbose "[Compat] Domain Level: $($domain.DomainMode)"
        Write-Verbose "[Compat] Min DC Version: $minDCVersion"
        Write-Verbose "[Compat] Use CIM: $useCimInstance"
        Write-Verbose "[Compat] Use Modern AD Cmdlets: $useModernADCmdlets"
        
        return $script:CompatibilityInfo
    }
    catch {
        Write-Warning "[Compat] Failed to detect compatibility: $($_.Exception.Message)"
        
        # Default to most compatible mode
        $script:CompatibilityInfo = [PSCustomObject]@{
            ForestMode = "Unknown"
            DomainMode = "Unknown"
            ForestLevel = 5
            DomainLevel = 5
            MinDCVersion = "6.2"
            HasServer2016Plus = $false
            HasServer2012R2Plus = $true
            HasServer2012Plus = $true
            UseCimInstance = $false
            UseModernADCmdlets = $true
            SupportsDFSR = $true
            DCVersions = @()
        }
        
        return $script:CompatibilityInfo
    }
}

# =============================================================================
# FUNCTION: Get-CompatibleSystemInfo
# Purpose: Get system info using appropriate method
# =============================================================================
function Get-CompatibleSystemInfo {
    <#
    .SYNOPSIS
        Gets system information using compatible method
    
    .PARAMETER ComputerName
        Computer to query
    
    .EXAMPLE
        Get-CompatibleSystemInfo -ComputerName "DC01"
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )
    
    if ($script:CompatibilityInfo.UseCimInstance) {
        # Modern approach (2016+)
        Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $ComputerName
    }
    else {
        # Legacy approach (2012 R2)
        Get-WmiObject -Class Win32_OperatingSystem -ComputerName $ComputerName
    }
}

# =============================================================================
# FUNCTION: Get-CompatibleProcessInfo
# Purpose: Get process info using appropriate method
# =============================================================================
function Get-CompatibleProcessInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        
        [Parameter(Mandatory = $false)]
        [string]$ProcessName
    )
    
    if ($script:CompatibilityInfo.UseCimInstance) {
        $filter = if ($ProcessName) { "Name='$ProcessName'" } else { $null }
        Get-CimInstance -ClassName Win32_Process -ComputerName $ComputerName -Filter $filter
    }
    else {
        $filter = if ($ProcessName) { "Name='$ProcessName'" } else { "*" }
        Get-WmiObject -Class Win32_Process -ComputerName $ComputerName -Filter $filter
    }
}

# =============================================================================
# FUNCTION: Get-CompatibleServiceInfo
# Purpose: Get service info using appropriate method
# =============================================================================
function Get-CompatibleServiceInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        
        [Parameter(Mandatory = $false)]
        [string]$ServiceName
    )
    
    if ($ServiceName) {
        Get-Service -Name $ServiceName -ComputerName $ComputerName
    }
    else {
        Get-Service -ComputerName $ComputerName
    }
}

# =============================================================================
# FUNCTION: Get-CompatibleEventLog
# Purpose: Get event logs using appropriate method
# =============================================================================
function Get-CompatibleEventLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,
        
        [Parameter(Mandatory = $true)]
        [string]$LogName,
        
        [Parameter(Mandatory = $false)]
        [int[]]$EventID,
        
        [Parameter(Mandatory = $false)]
        [datetime]$After,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxEvents = 100
    )
    
    # Build filter hashtable
    $filter = @{
        LogName = $LogName
    }
    
    if ($EventID) {
        $filter.ID = $EventID
    }
    
    if ($After) {
        $filter.StartTime = $After
    }
    
    try {
        # Try modern method first
        Get-WinEvent -ComputerName $ComputerName -FilterHashtable $filter -MaxEvents $MaxEvents -ErrorAction Stop
    }
    catch {
        # Fallback to legacy method
        $filterXML = "*[System["
        if ($EventID) {
            $filterXML += "(" + (($EventID | ForEach-Object { "EventID=$_" }) -join " or ") + ")"
        }
        $filterXML += "]]"
        
        Get-EventLog -ComputerName $ComputerName -LogName $LogName -Newest $MaxEvents
    }
}

# =============================================================================
# FUNCTION: Get-CompatibleReplicationInfo
# Purpose: Get replication info using appropriate method
# =============================================================================
function Get-CompatibleReplicationInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DomainController
    )
    
    if ($script:CompatibilityInfo.UseModernADCmdlets) {
        # Use AD cmdlets (2012 R2+)
        try {
            Get-ADReplicationPartnerMetadata -Target $DomainController -Scope Server
        }
        catch {
            # Fallback to .NET
            Get-ReplicationInfoLegacy -DomainController $DomainController
        }
    }
    else {
        # Use .NET DirectoryServices (all versions)
        Get-ReplicationInfoLegacy -DomainController $DomainController
    }
}

function Get-ReplicationInfoLegacy {
    param([string]$DomainController)
    
    $context = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext(
        'DirectoryServer', $DomainController
    )
    $dc = [System.DirectoryServices.ActiveDirectory.DomainController]::GetDomainController($context)
    $dc.GetAllReplicationNeighbors()
}

# =============================================================================
# FUNCTION: Test-SysvolReplicationMethod
# Purpose: Determine if using DFSR or FRS
# =============================================================================
function Test-SysvolReplicationMethod {
    <#
    .SYNOPSIS
        Determines if SYSVOL uses DFSR or FRS
    
    .PARAMETER DomainName
        Domain to check
    
    .OUTPUTS
        String: "DFSR" or "FRS"
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$DomainName
    )
    
    try {
        # Check for DFSR service
        $dfsrService = Get-Service -Name DFSR -ErrorAction SilentlyContinue
        
        if ($dfsrService -and $script:CompatibilityInfo.SupportsDFSR) {
            # Check if SYSVOL is migrated to DFSR
            $migrationState = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters" `
                -Name "SysvolReady" -ErrorAction SilentlyContinue
            
            if ($migrationState.SysvolReady -eq 1) {
                return "DFSR"
            }
        }
        
        return "FRS"
    }
    catch {
        # Default to FRS for older environments
        return "FRS"
    }
}

# =============================================================================
# FUNCTION: Get-CompatibilityReport
# Purpose: Generate compatibility report
# =============================================================================
function Get-CompatibilityReport {
    <#
    .SYNOPSIS
        Generates a compatibility report
    
    .EXAMPLE
        Get-CompatibilityReport
    #>
    
    if (-not $script:CompatibilityInfo) {
        Write-Warning "Compatibility layer not initialized. Run Initialize-CompatibilityLayer first."
        return $null
    }
    
    return $script:CompatibilityInfo
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================

Export-ModuleMember -Function @(
    'Initialize-CompatibilityLayer',
    'Get-CompatibleSystemInfo',
    'Get-CompatibleProcessInfo',
    'Get-CompatibleServiceInfo',
    'Get-CompatibleEventLog',
    'Get-CompatibleReplicationInfo',
    'Test-SysvolReplicationMethod',
    'Get-CompatibilityReport'
)
