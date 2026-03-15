<#
.SYNOPSIS
    ADHealthCheck - Pre-Requisite Validation Script

.DESCRIPTION
    Validates all prerequisites before running ADHealthCheck.
    This script is designed to run on PowerShell 4.0+ so it can detect
    environments that do not yet meet the PS 5.1 requirement.

    Checks performed:
        [1]  PowerShell version
        [2]  Operating System version
        [3]  Administrator privileges
        [4]  Execution policy
        [5]  ActiveDirectory module (RSAT-AD-PowerShell)
        [6]  DnsServer module (RSAT-DNS-Server)
        [7]  GroupPolicy module (GPMC)
        [8]  Domain connectivity
        [9]  SYSVOL / NETLOGON share availability
        [10] Disk space for output reports
        [11] WinRM / Remote Management availability
        [12] .NET Framework version

    Each failed check includes:
        - Severity  : CRITICAL / WARNING / INFO
        - Impact    : What breaks in ADHealthCheck without this
        - Fix       : Step-by-step remediation
        - Docs      : Official Microsoft documentation URL

.PARAMETER OutputPath
    Path where the prerequisite report (HTML) will be saved.
    Default: .\Output\PreReqCheck_<timestamp>.html

.PARAMETER SkipHtmlReport
    Skips HTML report generation. Results shown in console only.

.EXAMPLE
    .\Test-ADHealthCheckPrereqs.ps1
    Runs all prerequisite checks and generates HTML report.

.EXAMPLE
    .\Test-ADHealthCheckPrereqs.ps1 -SkipHtmlReport
    Runs all checks, console output only.

.NOTES
    Author  : ADHealthCheck Team
    Version : 1.0.0
    Compatibility: PowerShell 4.0+ (Windows Server 2012 R2 and later)
    This script intentionally uses no PS 5.1-only syntax.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\Output",

    [Parameter(Mandatory = $false)]
    [switch]$SkipHtmlReport
)

# ==============================================================================
# INITIALIZATION
# ==============================================================================

$ErrorActionPreference = 'Continue'
$scriptVersion         = "1.0.0"
$scriptStart           = Get-Date
$results               = @()
$criticalCount         = 0
$warningCount          = 0
$passCount             = 0

# Color map for console
$colorMap = @{
    PASS     = 'Green'
    WARNING  = 'Yellow'
    CRITICAL = 'Red'
    INFO     = 'Cyan'
    SECTION  = 'Cyan'
}

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

function Write-CheckResult {
    param(
        [string]$CheckId,
        [string]$CheckName,
        [string]$Status,       # PASS / WARNING / CRITICAL
        [string]$Detail,
        [string]$Impact,
        [string]$Fix,
        [string]$DocsUrl,
        [string]$DocsTitle
    )

    $color = $colorMap[$Status]
    if (-not $color) { $color = 'White' }

    $icon = switch ($Status) {
        'PASS'     { '[OK]' }
        'WARNING'  { '[WARN]' }
        'CRITICAL' { '[FAIL]' }
        default    { '[INFO]' }
    }

    Write-Host ("  {0,-6} {1,-4} {2}" -f $icon, $CheckId, $CheckName) -ForegroundColor $color
    if ($Status -ne 'PASS') {
        Write-Host ("         Detail : {0}" -f $Detail)  -ForegroundColor Gray
        Write-Host ("         Impact : {0}" -f $Impact)  -ForegroundColor DarkYellow
        Write-Host ("         Fix    : {0}" -f $Fix)     -ForegroundColor White
        if ($DocsUrl) {
            Write-Host ("         Docs   : {0}" -f $DocsUrl) -ForegroundColor DarkCyan
        }
    }
    else {
        Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray
    }
    Write-Host ""

    $script:results += [PSCustomObject]@{
        CheckId    = $CheckId
        CheckName  = $CheckName
        Status     = $Status
        Detail     = $Detail
        Impact     = $Impact
        Fix        = $Fix
        DocsUrl    = $DocsUrl
        DocsTitle  = $DocsTitle
    }

    if ($Status -eq 'CRITICAL') { $script:criticalCount++ }
    if ($Status -eq 'WARNING')  { $script:warningCount++ }
    if ($Status -eq 'PASS')     { $script:passCount++ }
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host ("  --- {0} ---" -f $Title.ToUpper()) -ForegroundColor Cyan
    Write-Host ""
}

# ==============================================================================
# BANNER
# ==============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         ADHealthCheck - Pre-Requisite Validator               " -ForegroundColor Cyan
Write-Host "                     Version $scriptVersion                    " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Server : $($env:COMPUTERNAME)" -ForegroundColor White
Write-Host "  User   : $($env:USERDOMAIN)\$($env:USERNAME)" -ForegroundColor White
Write-Host "  Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host ""

# ==============================================================================
# CHECK 01 - POWERSHELL VERSION
# ==============================================================================

Write-Section "Core Requirements"

$psVersion = $PSVersionTable.PSVersion
$psMajor   = $psVersion.Major
$psMinor   = $psVersion.Minor
$psDisplay = "$psMajor.$psMinor"

if ($psMajor -gt 5 -or ($psMajor -eq 5 -and $psMinor -ge 1)) {
    Write-CheckResult `
        -CheckId    "PRE-001" `
        -CheckName  "PowerShell Version" `
        -Status     "PASS" `
        -Detail     "PowerShell $psDisplay detected. Requirement met." `
        -Impact     "" `
        -Fix        "" `
        -DocsUrl    "" `
        -DocsTitle  ""
}
elseif ($psMajor -eq 5 -and $psMinor -eq 0) {
    Write-CheckResult `
        -CheckId    "PRE-001" `
        -CheckName  "PowerShell Version" `
        -Status     "WARNING" `
        -Detail     "PowerShell 5.0 detected. Version 5.1 is recommended." `
        -Impact     "Some AD cmdlet behaviors differ in PS 5.0. Minor instability possible." `
        -Fix        "Install WMF 5.1. Download from the link below. Requires server reboot." `
        -DocsUrl    "https://learn.microsoft.com/en-us/powershell/scripting/windows-powershell/wmf/setup/install-configure" `
        -DocsTitle  "Install and Configure WMF 5.1 - Microsoft Learn"
}
else {
    Write-CheckResult `
        -CheckId    "PRE-001" `
        -CheckName  "PowerShell Version" `
        -Status     "CRITICAL" `
        -Detail     "PowerShell $psDisplay detected. Minimum required: 5.1" `
        -Impact     "ADHealthCheck will not start. Pre-flight check enforces PS 5.1+." `
        -Fix        @"
Step 1: Download WMF 5.1 from Microsoft:
          https://aka.ms/wmf51download
Step 2: Select the correct package for your OS:
          - Server 2012 R2 : Win8.1AndW2K12R2-KB3191564-x64.msu
          - Server 2012    : W2K12-KB3191565-x64.msu
Step 3: Copy the .msu file to the server
Step 4: Run in elevated cmd: wusa.exe <filename>.msu /quiet /norestart
Step 5: Schedule a maintenance window and reboot the server
Step 6: Verify: $PSVersionTable.PSVersion (should show 5.1.xxxxx)
"@ `
        -DocsUrl    "https://learn.microsoft.com/en-us/powershell/scripting/windows-powershell/wmf/whats-new/new-scenarios-features51" `
        -DocsTitle  "What's New in WMF 5.1 - Microsoft Learn"
}

# ==============================================================================
# CHECK 02 - OPERATING SYSTEM VERSION
# ==============================================================================

$osVersion = [System.Environment]::OSVersion.Version
$osMajor   = $osVersion.Major
$osMinor   = $osVersion.Minor
$osBuild   = $osVersion.Build

# Map build numbers to OS names
$osName = "Unknown"
if ($osMajor -eq 10 -and $osBuild -ge 20348) { $osName = "Windows Server 2022" }
elseif ($osMajor -eq 10 -and $osBuild -ge 17763) { $osName = "Windows Server 2019" }
elseif ($osMajor -eq 10 -and $osBuild -ge 14393) { $osName = "Windows Server 2016" }
elseif ($osMajor -eq 6 -and $osMinor -eq 3)       { $osName = "Windows Server 2012 R2" }
elseif ($osMajor -eq 6 -and $osMinor -eq 2)       { $osName = "Windows Server 2012" }
elseif ($osMajor -eq 6 -and $osMinor -eq 1)       { $osName = "Windows Server 2008 R2" }

$osSupported = ($osMajor -eq 10) -or ($osMajor -eq 6 -and $osMinor -ge 2)
$osEndOfLife = ($osMajor -eq 6)

if ($osSupported -and -not $osEndOfLife) {
    Write-CheckResult `
        -CheckId   "PRE-002" `
        -CheckName "Operating System" `
        -Status    "PASS" `
        -Detail    "$osName (Build $osBuild). Fully supported." `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
elseif ($osSupported -and $osEndOfLife) {
    Write-CheckResult `
        -CheckId   "PRE-002" `
        -CheckName "Operating System" `
        -Status    "WARNING" `
        -Detail    "$osName detected. This OS is past Microsoft end-of-life." `
        -Impact    "Some newer AD features and cmdlets are unavailable. WMF 5.1 must be manually installed." `
        -Fix       "Plan OS upgrade to Server 2019 or 2022. Interim: ensure WMF 5.1 and all critical patches are applied." `
        -DocsUrl   "https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2012-r2" `
        -DocsTitle "Windows Server 2012 R2 End of Life - Microsoft Lifecycle"
}
else {
    Write-CheckResult `
        -CheckId   "PRE-002" `
        -CheckName "Operating System" `
        -Status    "CRITICAL" `
        -Detail    "OS version $osMajor.$osMinor.$osBuild is not supported." `
        -Impact    "ADHealthCheck requires Windows Server 2012 R2 or later." `
        -Fix       "Upgrade operating system to Windows Server 2012 R2 minimum." `
        -DocsUrl   "https://learn.microsoft.com/en-us/windows-server/get-started/hardware-requirements" `
        -DocsTitle "Windows Server System Requirements - Microsoft Learn"
}

# ==============================================================================
# CHECK 03 - ADMINISTRATOR PRIVILEGES
# ==============================================================================

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    Write-CheckResult `
        -CheckId   "PRE-003" `
        -CheckName "Administrator Privileges" `
        -Status    "PASS" `
        -Detail    "Running as: $($identity.Name). Local Administrator confirmed." `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
else {
    Write-CheckResult `
        -CheckId   "PRE-003" `
        -CheckName "Administrator Privileges" `
        -Status    "CRITICAL" `
        -Detail    "Running as: $($identity.Name). NOT a local Administrator." `
        -Impact    "Checks requiring WMI, service enumeration, and event log access will fail." `
        -Fix       "Right-click PowerShell and select 'Run as Administrator', then re-run this script." `
        -DocsUrl   "https://learn.microsoft.com/en-us/powershell/scripting/learn/ps101/01-getting-started" `
        -DocsTitle "Running PowerShell as Administrator - Microsoft Learn"
}

# ==============================================================================
# CHECK 04 - EXECUTION POLICY
# ==============================================================================

$execPolicy = Get-ExecutionPolicy -Scope Process
$machinePolicy = Get-ExecutionPolicy -Scope LocalMachine

$policyBlocking = ($execPolicy -eq 'Restricted' -or $execPolicy -eq 'AllSigned')

if (-not $policyBlocking) {
    Write-CheckResult `
        -CheckId   "PRE-004" `
        -CheckName "Execution Policy" `
        -Status    "PASS" `
        -Detail    "Process scope policy: $execPolicy. Scripts can execute." `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
else {
    Write-CheckResult `
        -CheckId   "PRE-004" `
        -CheckName "Execution Policy" `
        -Status    "CRITICAL" `
        -Detail    "Policy is '$execPolicy'. Unsigned scripts are blocked." `
        -Impact    "ADHealthCheck and all check scripts will be blocked from executing." `
        -Fix       @"
Option A - Session bypass (temporary, recommended for ad-hoc runs):
  Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

Option B - User-level bypass (persistent for current user only):
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

Option C - Group Policy (organization-wide, requires GPO access):
  GPO Path: Computer Config > Windows Settings > Security Settings >
            Software Restriction Policies > Additional Rules
  Or use: Computer Config > Admin Templates > Windows Components >
          Windows PowerShell > Turn on Script Execution
"@ `
        -DocsUrl   "https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-executionpolicy" `
        -DocsTitle "Set-ExecutionPolicy Documentation - Microsoft Learn"
}

# ==============================================================================
# CHECK 05 - ACTIVE DIRECTORY MODULE
# ==============================================================================

Write-Section "PowerShell Modules (RSAT)"

$adModule = Get-Module -ListAvailable -Name ActiveDirectory
if ($adModule) {
    Write-CheckResult `
        -CheckId   "PRE-005" `
        -CheckName "ActiveDirectory Module" `
        -Status    "PASS" `
        -Detail    "Module found. Version: $($adModule.Version)" `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
else {
    Write-CheckResult `
        -CheckId   "PRE-005" `
        -CheckName "ActiveDirectory Module" `
        -Status    "CRITICAL" `
        -Detail    "ActiveDirectory module not found (RSAT-AD-PowerShell not installed)." `
        -Impact    "ALL 50 checks depend on AD cmdlets. Tool cannot run without this module." `
        -Fix       @"
On a Domain Controller (AD DS role already provides this):
  The module is included with the AD DS role. No action needed.

On a Member Server (install RSAT):
  Windows Server 2012 R2 / 2016 / 2019 / 2022:
    Add-WindowsFeature RSAT-AD-PowerShell

  Windows 10 / 11 (Admin Workstation):
    Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
"@ `
        -DocsUrl   "https://learn.microsoft.com/en-us/powershell/module/activedirectory" `
        -DocsTitle "ActiveDirectory Module Reference - Microsoft Learn"
}

# ==============================================================================
# CHECK 06 - DNS SERVER MODULE
# ==============================================================================

$dnsModule = Get-Module -ListAvailable -Name DnsServer
if ($dnsModule) {
    Write-CheckResult `
        -CheckId   "PRE-006" `
        -CheckName "DnsServer Module" `
        -Status    "PASS" `
        -Detail    "Module found. Version: $($dnsModule.Version)" `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
else {
    Write-CheckResult `
        -CheckId   "PRE-006" `
        -CheckName "DnsServer Module" `
        -Status    "WARNING" `
        -Detail    "DnsServer module not found (RSAT-DNS-Server not installed)." `
        -Impact    "All 6 DNS checks (DNS-001 through DNS-006) will fail or be skipped." `
        -Fix       @"
On a DNS Server (role includes the module automatically):
  No action needed.

On a Member Server or DC without DNS role:
  Windows Server:
    Add-WindowsFeature RSAT-DNS-Server

  Windows 10 / 11:
    Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0
"@ `
        -DocsUrl   "https://learn.microsoft.com/en-us/powershell/module/dnsserver" `
        -DocsTitle "DnsServer Module Reference - Microsoft Learn"
}

# ==============================================================================
# CHECK 07 - GROUP POLICY MODULE
# ==============================================================================

$gpModule = Get-Module -ListAvailable -Name GroupPolicy
if ($gpModule) {
    Write-CheckResult `
        -CheckId   "PRE-007" `
        -CheckName "GroupPolicy Module" `
        -Status    "PASS" `
        -Detail    "Module found. Version: $($gpModule.Version)" `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
else {
    Write-CheckResult `
        -CheckId   "PRE-007" `
        -CheckName "GroupPolicy Module" `
        -Status    "WARNING" `
        -Detail    "GroupPolicy module not found (GPMC not installed)." `
        -Impact    "All 4 GPO checks (GPO-001 through GPO-004) will fail or be skipped." `
        -Fix       @"
Windows Server:
  Add-WindowsFeature GPMC

Windows 10 / 11:
  Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
"@ `
        -DocsUrl   "https://learn.microsoft.com/en-us/powershell/module/grouppolicy" `
        -DocsTitle "GroupPolicy Module Reference - Microsoft Learn"
}

# ==============================================================================
# CHECK 08 - DOMAIN CONNECTIVITY
# ==============================================================================

Write-Section "Active Directory Connectivity"

try {
    $domainObj = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    $domainName = $domainObj.Name
    $pdcName    = $domainObj.PdcRoleOwner.Name

    Write-CheckResult `
        -CheckId   "PRE-008" `
        -CheckName "Domain Connectivity" `
        -Status    "PASS" `
        -Detail    "Domain: $domainName | PDC Emulator: $pdcName" `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
catch {
    Write-CheckResult `
        -CheckId   "PRE-008" `
        -CheckName "Domain Connectivity" `
        -Status    "CRITICAL" `
        -Detail    "Cannot connect to AD domain. Error: $($_.Exception.Message)" `
        -Impact    "Tool cannot discover DC topology. All checks will fail." `
        -Fix       "Verify: (1) Server is domain-joined, (2) DNS resolves the domain, (3) PDC Emulator is reachable on TCP 389." `
        -DocsUrl   "https://learn.microsoft.com/en-us/troubleshoot/windows-server/active-directory/troubleshoot-ad-dc-connection-issues" `
        -DocsTitle "Troubleshoot AD DC Connection Issues - Microsoft Learn"
}

# ==============================================================================
# CHECK 09 - SYSVOL / NETLOGON SHARES
# ==============================================================================

$sysvolOk  = $false
$netlogonOk = $false

try {
    $shares = Get-WmiObject -Class Win32_Share -ErrorAction Stop
    $sysvolOk   = ($shares | Where-Object { $_.Name -eq 'SYSVOL' })   -ne $null
    $netlogonOk = ($shares | Where-Object { $_.Name -eq 'NETLOGON' }) -ne $null
}
catch {
    # WMI not available
}

if ($sysvolOk -and $netlogonOk) {
    Write-CheckResult `
        -CheckId   "PRE-009" `
        -CheckName "SYSVOL / NETLOGON Shares" `
        -Status    "PASS" `
        -Detail    "SYSVOL and NETLOGON shares are present and accessible." `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
elseif (-not $sysvolOk -or -not $netlogonOk) {
    $missing = @()
    if (-not $sysvolOk)   { $missing += "SYSVOL" }
    if (-not $netlogonOk) { $missing += "NETLOGON" }

    Write-CheckResult `
        -CheckId   "PRE-009" `
        -CheckName "SYSVOL / NETLOGON Shares" `
        -Status    "WARNING" `
        -Detail    "Missing shares: $($missing -join ', ')" `
        -Impact    "GPO replication and SYSVOL consistency checks may produce incorrect results." `
        -Fix       @"
1. Open Services (services.msc) and verify 'DFS Replication' or 'File Replication Service' is Running.
2. Run: netlogon /reregister (from elevated cmd)
3. If SYSVOL is empty, use authoritative SYSVOL restore:
   https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/sysvol-dfsr-not-replicated
"@ `
        -DocsUrl   "https://learn.microsoft.com/en-us/troubleshoot/windows-server/group-policy/rebuild-sysvol-tree-and-content" `
        -DocsTitle "Rebuild SYSVOL Tree and Contents - Microsoft Learn"
}

# ==============================================================================
# CHECK 10 - DISK SPACE FOR REPORTS
# ==============================================================================

Write-Section "Resources"

try {
    $scriptDrive  = Split-Path -Qualifier $PSScriptRoot
    if (-not $scriptDrive) { $scriptDrive = "C:" }

    $disk = Get-WmiObject -Class Win32_LogicalDisk -Filter "DeviceID='$scriptDrive'" -ErrorAction Stop
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)

    if ($freeGB -ge 1) {
        Write-CheckResult `
            -CheckId   "PRE-010" `
            -CheckName "Disk Space ($scriptDrive)" `
            -Status    "PASS" `
            -Detail    "$freeGB GB free on $scriptDrive. Minimum 1 GB required." `
            -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
    }
    elseif ($freeGB -ge 0.5) {
        Write-CheckResult `
            -CheckId   "PRE-010" `
            -CheckName "Disk Space ($scriptDrive)" `
            -Status    "WARNING" `
            -Detail    "Only $freeGB GB free on $scriptDrive. Reports may not generate correctly." `
            -Impact    "HTML reports and log files require approximately 50-100 MB per run." `
            -Fix       "Free up at least 500 MB on $scriptDrive, or use -OutputPath to redirect output to a different drive." `
            -DocsUrl   "" -DocsTitle ""
    }
    else {
        Write-CheckResult `
            -CheckId   "PRE-010" `
            -CheckName "Disk Space ($scriptDrive)" `
            -Status    "CRITICAL" `
            -Detail    "Only $freeGB GB free on $scriptDrive. Tool output will fail." `
            -Impact    "Report generation will fail. Logs cannot be written. Tool execution aborted." `
            -Fix       "Free up disk space or use -OutputPath to point to a drive with sufficient space." `
            -DocsUrl   "" -DocsTitle ""
    }
}
catch {
    Write-CheckResult `
        -CheckId   "PRE-010" `
        -CheckName "Disk Space" `
        -Status    "WARNING" `
        -Detail    "Could not check disk space: $($_.Exception.Message)" `
        -Impact    "Unable to verify output path has sufficient space." `
        -Fix       "Manually verify at least 500 MB free on the drive where ADHealthCheck is installed." `
        -DocsUrl   "" -DocsTitle ""
}

# ==============================================================================
# CHECK 11 - WINRM / REMOTE MANAGEMENT
# ==============================================================================

$winrmOk = $false
try {
    $winrmService = Get-Service -Name WinRM -ErrorAction Stop
    $winrmOk = ($winrmService.Status -eq 'Running')
}
catch {
    $winrmOk = $false
}

if ($winrmOk) {
    Write-CheckResult `
        -CheckId   "PRE-011" `
        -CheckName "WinRM Service" `
        -Status    "PASS" `
        -Detail    "WinRM is running. Remote DC queries are available." `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
else {
    Write-CheckResult `
        -CheckId   "PRE-011" `
        -CheckName "WinRM Service" `
        -Status    "WARNING" `
        -Detail    "WinRM service is not running on this server." `
        -Impact    "Remote checks against other DCs may fall back to DCOM/RPC. Some multi-DC checks may be limited." `
        -Fix       @"
Enable WinRM (run in elevated PowerShell):
  Enable-PSRemoting -Force

Or start only the service:
  Set-Service WinRM -StartupType Automatic
  Start-Service WinRM
"@ `
        -DocsUrl   "https://learn.microsoft.com/en-us/windows/win32/winrm/installation-and-configuration-for-windows-remote-management" `
        -DocsTitle "WinRM Installation and Configuration - Microsoft Learn"
}

# ==============================================================================
# CHECK 12 - .NET FRAMEWORK VERSION
# ==============================================================================

$dotNetVersion = $null
try {
    $dotNetKey = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction Stop
    $dotNetRelease = $dotNetKey.Release

    # Map release number to version name
    if ($dotNetRelease -ge 533320) { $dotNetVersion = "4.8.1" }
    elseif ($dotNetRelease -ge 528040) { $dotNetVersion = "4.8" }
    elseif ($dotNetRelease -ge 461808) { $dotNetVersion = "4.7.2" }
    elseif ($dotNetRelease -ge 461308) { $dotNetVersion = "4.7.1" }
    elseif ($dotNetRelease -ge 460798) { $dotNetVersion = "4.7" }
    elseif ($dotNetRelease -ge 394802) { $dotNetVersion = "4.6.2" }
    elseif ($dotNetRelease -ge 394254) { $dotNetVersion = "4.6.1" }
    elseif ($dotNetRelease -ge 393295) { $dotNetVersion = "4.6" }
    elseif ($dotNetRelease -ge 379893) { $dotNetVersion = "4.5.2" }
    elseif ($dotNetRelease -ge 378675) { $dotNetVersion = "4.5.1" }
    elseif ($dotNetRelease -ge 378389) { $dotNetVersion = "4.5" }
    else { $dotNetVersion = "4.x (Release key: $dotNetRelease)" }
}
catch {
    $dotNetVersion = $null
}

if ($dotNetVersion) {
    Write-CheckResult `
        -CheckId   "PRE-012" `
        -CheckName ".NET Framework" `
        -Status    "PASS" `
        -Detail    ".NET Framework $dotNetVersion detected. Meets minimum requirement (4.5+)." `
        -Impact    "" -Fix "" -DocsUrl "" -DocsTitle ""
}
else {
    Write-CheckResult `
        -CheckId   "PRE-012" `
        -CheckName ".NET Framework" `
        -Status    "WARNING" `
        -Detail    "Could not determine .NET Framework version from registry." `
        -Impact    "PowerShell and AD cmdlets may behave unexpectedly on older .NET versions." `
        -Fix       @"
Download and install .NET Framework 4.8 from:
  https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48
Requires server reboot after installation.
"@ `
        -DocsUrl   "https://learn.microsoft.com/en-us/dotnet/framework/migration-guide/how-to-determine-which-versions-are-installed" `
        -DocsTitle "Determine .NET Framework Versions - Microsoft Learn"
}

# ==============================================================================
# SUMMARY
# ==============================================================================

$totalChecks = @($results).Count
$duration    = [math]::Round(((Get-Date) - $scriptStart).TotalSeconds, 2)

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                     SUMMARY                                   " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  Total Checks : {0}" -f $totalChecks) -ForegroundColor White
Write-Host ("  Passed       : {0}" -f $passCount)   -ForegroundColor Green
Write-Host ("  Warnings     : {0}" -f $warningCount) -ForegroundColor Yellow
Write-Host ("  Critical     : {0}" -f $criticalCount) -ForegroundColor Red
Write-Host ("  Duration     : {0}s" -f $duration)   -ForegroundColor Gray
Write-Host ""

if ($criticalCount -gt 0) {
    Write-Host "  STATUS: NOT READY - $criticalCount critical issue(s) must be resolved" -ForegroundColor Red
    Write-Host "          before ADHealthCheck can run." -ForegroundColor Red
}
elseif ($warningCount -gt 0) {
    Write-Host "  STATUS: READY WITH WARNINGS - ADHealthCheck can run but some" -ForegroundColor Yellow
    Write-Host "          checks may be incomplete. Review warnings above." -ForegroundColor Yellow
}
else {
    Write-Host "  STATUS: READY - All prerequisites met. Run ADHealthCheck:" -ForegroundColor Green
    Write-Host "          .\Invoke-ADHealthCheck.ps1" -ForegroundColor Cyan
}

Write-Host ""

# ==============================================================================
# HTML REPORT GENERATION
# ==============================================================================

if (-not $SkipHtmlReport) {

    if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $reportFile = Join-Path $OutputPath "PreReqCheck_$timestamp.html"

    $statusColor = @{
        PASS     = '#28a745'
        WARNING  = '#ffc107'
        CRITICAL = '#dc3545'
    }

    $statusBg = @{
        PASS     = '#f0fff4'
        WARNING  = '#fffdf0'
        CRITICAL = '#fff0f0'
    }

    $rowsHtml = ""
    foreach ($r in $results) {
        $sc  = $statusColor[$r.Status]
        if (-not $sc) { $sc = '#6c757d' }
        $sbg = $statusBg[$r.Status]
        if (-not $sbg) { $sbg = '#ffffff' }

        $docsLink = ""
        if ($r.DocsUrl) {
            $docsLink = "<a href='$($r.DocsUrl)' target='_blank' style='color:#0078d4;font-size:12px;'>$($r.DocsTitle)</a>"
        }

        $fixHtml = ""
        if ($r.Fix) {
            $fixEscaped = [System.Web.HttpUtility]::HtmlEncode($r.Fix) -replace "`n","<br>"
            $fixHtml = "<div style='margin-top:6px;font-family:Consolas,monospace;font-size:12px;background:#f8f9fa;padding:8px;border-radius:4px;white-space:pre-wrap;'>$fixEscaped</div>"
        }

        $rowsHtml += @"
<tr style='background:$sbg;'>
  <td style='padding:12px 8px;font-weight:bold;color:#333;'>$($r.CheckId)</td>
  <td style='padding:12px 8px;'>$($r.CheckName)</td>
  <td style='padding:12px 8px;text-align:center;'>
    <span style='background:$sc;color:white;padding:3px 10px;border-radius:12px;font-size:12px;font-weight:bold;'>$($r.Status)</span>
  </td>
  <td style='padding:12px 8px;color:#555;font-size:13px;'>$($r.Detail)</td>
  <td style='padding:12px 8px;font-size:13px;'>
    $($r.Impact)
    $fixHtml
    $docsLink
  </td>
</tr>
"@
    }

    $overallStatus = "READY"
    $overallColor  = "#28a745"
    $overallMsg    = "All prerequisites met. ADHealthCheck is ready to run."

    if ($criticalCount -gt 0) {
        $overallStatus = "NOT READY"
        $overallColor  = "#dc3545"
        $overallMsg    = "$criticalCount critical prerequisite(s) must be resolved before running ADHealthCheck."
    }
    elseif ($warningCount -gt 0) {
        $overallStatus = "READY WITH WARNINGS"
        $overallColor  = "#ffc107"
        $overallMsg    = "ADHealthCheck can run but $warningCount check(s) may be incomplete."
    }

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ADHealthCheck - Pre-Requisite Report</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Segoe UI', Arial, sans-serif; background: #f4f6f9; color: #333; }
  .header { background: linear-gradient(135deg, #1a3a5c 0%, #0078d4 100%); color: white; padding: 30px 40px; }
  .header h1 { font-size: 24px; font-weight: 600; margin-bottom: 6px; }
  .header p  { font-size: 13px; opacity: 0.85; }
  .container { max-width: 1100px; margin: 30px auto; padding: 0 20px; }
  .status-banner { border-radius: 8px; padding: 20px 28px; margin-bottom: 24px; color: white; }
  .status-banner h2 { font-size: 20px; margin-bottom: 4px; }
  .status-banner p  { font-size: 13px; opacity: 0.9; }
  .stats { display: flex; gap: 16px; margin-bottom: 24px; flex-wrap: wrap; }
  .stat-card { background: white; border-radius: 8px; padding: 16px 24px; flex: 1; min-width: 120px;
               box-shadow: 0 1px 4px rgba(0,0,0,0.08); text-align: center; }
  .stat-card .num { font-size: 32px; font-weight: 700; }
  .stat-card .lbl { font-size: 12px; color: #666; margin-top: 4px; text-transform: uppercase; letter-spacing: 0.5px; }
  .card { background: white; border-radius: 8px; box-shadow: 0 1px 4px rgba(0,0,0,0.08); overflow: hidden; margin-bottom: 24px; }
  .card-title { padding: 16px 20px; font-size: 14px; font-weight: 600; background: #f8f9fa;
                border-bottom: 1px solid #e9ecef; color: #444; }
  table { width: 100%; border-collapse: collapse; }
  th { background: #f1f3f5; padding: 10px 12px; text-align: left; font-size: 12px;
       text-transform: uppercase; letter-spacing: 0.5px; color: #555; border-bottom: 2px solid #dee2e6; }
  td { border-bottom: 1px solid #eee; vertical-align: top; }
  tr:last-child td { border-bottom: none; }
  .footer { text-align: center; font-size: 12px; color: #888; padding: 20px; }
  a { text-decoration: none; }
  a:hover { text-decoration: underline; }
</style>
</head>
<body>

<div class="header">
  <h1>ADHealthCheck - Pre-Requisite Validation Report</h1>
  <p>Server: $($env:COMPUTERNAME) &nbsp;|&nbsp;
     User: $($env:USERDOMAIN)\$($env:USERNAME) &nbsp;|&nbsp;
     Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') &nbsp;|&nbsp;
     Tool Version: $scriptVersion</p>
</div>

<div class="container">

  <div class="status-banner" style="background:$overallColor;">
    <h2>Status: $overallStatus</h2>
    <p>$overallMsg</p>
  </div>

  <div class="stats">
    <div class="stat-card">
      <div class="num">$totalChecks</div>
      <div class="lbl">Total Checks</div>
    </div>
    <div class="stat-card">
      <div class="num" style="color:#28a745;">$passCount</div>
      <div class="lbl">Passed</div>
    </div>
    <div class="stat-card">
      <div class="num" style="color:#ffc107;">$warningCount</div>
      <div class="lbl">Warnings</div>
    </div>
    <div class="stat-card">
      <div class="num" style="color:#dc3545;">$criticalCount</div>
      <div class="lbl">Critical</div>
    </div>
  </div>

  <div class="card">
    <div class="card-title">Prerequisite Check Results</div>
    <table>
      <thead>
        <tr>
          <th style="width:80px;">ID</th>
          <th style="width:180px;">Check</th>
          <th style="width:100px;">Status</th>
          <th style="width:260px;">Detail</th>
          <th>Impact / Remediation</th>
        </tr>
      </thead>
      <tbody>
        $rowsHtml
      </tbody>
    </table>
  </div>

  <div class="card" style="padding:20px 24px;">
    <div class="card-title">Quick Reference - Official Documentation</div>
    <table>
      <thead><tr><th>Resource</th><th>URL</th></tr></thead>
      <tbody>
        <tr><td style="padding:8px;">Install WMF 5.1</td>
            <td style="padding:8px;"><a href="https://aka.ms/wmf51download" target="_blank">https://aka.ms/wmf51download</a></td></tr>
        <tr><td style="padding:8px;">ActiveDirectory Module (RSAT)</td>
            <td style="padding:8px;"><a href="https://learn.microsoft.com/en-us/powershell/module/activedirectory" target="_blank">Microsoft Learn - AD Module</a></td></tr>
        <tr><td style="padding:8px;">PowerShell Execution Policy</td>
            <td style="padding:8px;"><a href="https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/set-executionpolicy" target="_blank">Microsoft Learn - Set-ExecutionPolicy</a></td></tr>
        <tr><td style="padding:8px;">Server 2012 R2 Lifecycle</td>
            <td style="padding:8px;"><a href="https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2012-r2" target="_blank">Microsoft Lifecycle Policy</a></td></tr>
        <tr><td style="padding:8px;">.NET Framework 4.8</td>
            <td style="padding:8px;"><a href="https://dotnet.microsoft.com/en-us/download/dotnet-framework/net48" target="_blank">Download .NET Framework 4.8</a></td></tr>
        <tr><td style="padding:8px;">Enable WinRM</td>
            <td style="padding:8px;"><a href="https://learn.microsoft.com/en-us/windows/win32/winrm/installation-and-configuration-for-windows-remote-management" target="_blank">Microsoft Learn - WinRM</a></td></tr>
      </tbody>
    </table>
  </div>

</div>

<div class="footer">
  ADHealthCheck Pre-Requisite Validator v$scriptVersion &nbsp;|&nbsp;
  Generated in ${duration}s &nbsp;|&nbsp;
  <a href="https://github.com/jcsantam/ADHealthCheck" target="_blank">github.com/jcsantam/ADHealthCheck</a>
</div>

</body>
</html>
"@

    try {
        $html | Out-File -FilePath $reportFile -Encoding UTF8 -Force
        Write-Host "  HTML Report: $reportFile" -ForegroundColor Cyan

        # Try to open in browser
        try {
            $ie = New-Object -ComObject InternetExplorer.Application
            $ie.Navigate($reportFile)
            $ie.Visible = $true
        }
        catch {
            # Browser open not available, just show path
        }
    }
    catch {
        Write-Host "  WARNING: Could not write HTML report: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

Write-Host ""

# Exit code: 0=ready, 1=warnings, 2=critical
if ($criticalCount -gt 0) { exit 2 }
if ($warningCount  -gt 0) { exit 1 }
exit 0
