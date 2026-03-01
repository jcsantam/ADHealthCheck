<#
.SYNOPSIS
    AD Health Check - Main Entry Point

.DESCRIPTION
    Executes Active Directory health check with comprehensive analysis
    of infrastructure, services, replication, and security.

.PARAMETER OutputPath
    Path where results and reports will be saved
    Default: .\Output

.PARAMETER Categories
    Specific categories to run (empty = all)
    Valid values: Replication, DCHealth, DNS, GPO, Time, Backup, Security, Database, Operational

.PARAMETER LogLevel
    Logging verbosity level
    Valid values: Verbose, Information, Warning, Error
    Default: Information

.PARAMETER MaxParallelJobs
    Maximum number of checks to run in parallel
    Default: 10

.EXAMPLE
    .\Invoke-ADHealthCheck.ps1
    Runs complete health check with default settings

.EXAMPLE
    .\Invoke-ADHealthCheck.ps1 -Categories Replication,DCHealth -LogLevel Verbose
    Runs only Replication and DC Health checks with verbose logging

.EXAMPLE
    .\Invoke-ADHealthCheck.ps1 -OutputPath "C:\Reports" -MaxParallelJobs 20
    Runs with custom output path and higher parallelism

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Requires: Domain Admin credentials (or equivalent)
    PowerShell Version: 5.1 or later
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "$PSScriptRoot\Output",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('Replication', 'DCHealth', 'DNS', 'GPO', 'Time', 'Backup', 'Security', 'Database', 'Operational')]
    [array]$Categories = @(),
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
    [string]$LogLevel = 'Information',
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 50)]
    [int]$MaxParallelJobs = 10
)

# Set strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =============================================================================
# SCRIPT VARIABLES
# =============================================================================

$scriptVersion = "1.0.0"
$scriptStart = Get-Date

# =============================================================================
# BANNER
# =============================================================================

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "                                                                " -ForegroundColor Cyan
Write-Host "             AD HEALTH CHECK - ENTERPRISE EDITION               " -ForegroundColor Cyan
Write-Host "                      Version $scriptVersion                    " -ForegroundColor Cyan
Write-Host "                                                                " -ForegroundColor Cyan
Write-Host "  Comprehensive Active Directory Infrastructure Analysis       " -ForegroundColor Cyan
Write-Host "                                                                " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

Write-Host "[Pre-Flight] Performing environment checks..." -ForegroundColor Yellow

# Check PowerShell version
$psVersion = $PSVersionTable.PSVersion
Write-Host "  PowerShell Version: $($psVersion.Major).$($psVersion.Minor)" -ForegroundColor Gray

if ($psVersion.Major -lt 5) {
    Write-Host "  ERROR: PowerShell 5.1 or later required" -ForegroundColor Red
    exit 1
}

# Check if running in AD environment
try {
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    Write-Host "  Domain: $($domain.Name)" -ForegroundColor Gray
    Write-Host "  Domain Controller: $($domain.PdcRoleOwner.Name)" -ForegroundColor Gray
}
catch {
    Write-Host "  ERROR: Not running in Active Directory environment" -ForegroundColor Red
    Write-Host "  This tool must be run from a domain-joined computer" -ForegroundColor Red
    exit 1
}

# Check if running with sufficient privileges
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "  WARNING: Not running as Administrator" -ForegroundColor Yellow
    Write-Host "  Some checks may fail without administrative privileges" -ForegroundColor Yellow
}

Write-Host "  Pre-flight checks complete" -ForegroundColor Green
Write-Host ""

# =============================================================================
# LOAD CORE ENGINE
# =============================================================================

Write-Host "[Initialization] Loading core engine..." -ForegroundColor Yellow

$enginePath = Join-Path $PSScriptRoot "Core\Engine.ps1"

if (-not (Test-Path $enginePath)) {
    Write-Host "  ERROR: Core engine not found: $enginePath" -ForegroundColor Red
    exit 1
}

try {
    . $enginePath
    Write-Host "  Core engine loaded successfully" -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Host "  ERROR: Failed to load core engine: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# =============================================================================
# EXECUTE HEALTH CHECK
# =============================================================================

try {
    # Invoke main engine
    $result = Invoke-HealthCheckEngine `
        -OutputPath $OutputPath `
        -Categories $Categories `
        -MaxParallelJobs $MaxParallelJobs `
        -LogLevel $LogLevel
    
    # Display summary
    $duration = ((Get-Date) - $scriptStart).TotalSeconds
    
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "                    EXECUTION SUMMARY                           " -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "  Run ID:           $($result.RunId)" -ForegroundColor White
    Write-Host "  Forest:           $($result.ForestName)" -ForegroundColor White
    Write-Host "  Overall Score:    $($result.OverallScore)/100" -ForegroundColor $(
        if ($result.OverallScore -ge 85) { 'Green' }
        elseif ($result.OverallScore -ge 70) { 'Yellow' }
        else { 'Red' }
    )
    Write-Host "  Duration:         $([math]::Round($duration, 2))s" -ForegroundColor White
    Write-Host ""
    
    Write-Host "  Checks Summary:" -ForegroundColor White
    Write-Host "    Total:          $($result.TotalChecks)" -ForegroundColor Gray
    Write-Host "    Passed:         $($result.PassedChecks)" -ForegroundColor Green
    Write-Host "    Warning:        $($result.WarningChecks)" -ForegroundColor Yellow
    Write-Host "    Failed:         $($result.FailedChecks)" -ForegroundColor Red
    Write-Host ""
    
    Write-Host "  Issues Detected:" -ForegroundColor White
    Write-Host "    Critical:       $($result.CriticalIssues)" -ForegroundColor Red
    Write-Host "    High:           $($result.HighIssues)" -ForegroundColor DarkRed
    Write-Host "    Medium:         $($result.MediumIssues)" -ForegroundColor Yellow
    Write-Host "    Low:            $($result.LowIssues)" -ForegroundColor Gray
    Write-Host ""
    
    Write-Host "  Report saved to:" -ForegroundColor White
    Write-Host "    $($result.ReportPath)" -ForegroundColor Cyan
    Write-Host ""
    
    # Exit code based on critical issues
    if ($result.CriticalIssues -gt 0) {
        Write-Host "  Status: CRITICAL ISSUES FOUND" -ForegroundColor Red
        exit 1
    }
    elseif ($result.HighIssues -gt 0) {
        Write-Host "  Status: HIGH PRIORITY ISSUES FOUND" -ForegroundColor Yellow
        exit 2
    }
    else {
        Write-Host "  Status: HEALTHY" -ForegroundColor Green
        exit 0
    }
}
catch {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "                    EXECUTION FAILED                            " -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ""
    
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Stack Trace:" -ForegroundColor Gray
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    Write-Host ""
    
    exit 99
}