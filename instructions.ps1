<#
.SYNOPSIS
    AD Health Check - Setup and Usage Instructions

.DESCRIPTION
    Run this script to verify prerequisites and get step-by-step guidance
    for deploying AD Health Check in any environment.

.NOTES
    Version: 2.0.0
    Run from a domain-joined Windows Server with PowerShell 5.1+
#>

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         AD HEALTH CHECK v2.0.0 - SETUP INSTRUCTIONS           " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 1 - COPY FILES
# ---------------------------------------------------------------------------

Write-Host "STEP 1 - Copy the tool to the target machine" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Copy the entire ADHealthCheck folder to a Domain Controller" -ForegroundColor White
Write-Host "  or any domain-joined Windows Server. Recommended path:" -ForegroundColor White
Write-Host ""
Write-Host "      C:\ADHealthCheck" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Required folder structure:" -ForegroundColor White
Write-Host "      Invoke-ADHealthCheck.ps1    entry point" -ForegroundColor Gray
Write-Host "      Core\                       engine modules" -ForegroundColor Gray
Write-Host "      Checks\                     50 check scripts" -ForegroundColor Gray
Write-Host "      Definitions\                JSON evaluation rules" -ForegroundColor Gray
Write-Host "      Config\                     settings" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 2 - PREREQUISITES CHECK
# ---------------------------------------------------------------------------

Write-Host "STEP 2 - Verify prerequisites" -ForegroundColor Yellow
Write-Host ""

$allOk = $true

# PowerShell version
$psVer = $PSVersionTable.PSVersion
$psOk = $psVer.Major -ge 5
$psStatus = if ($psOk) { "OK  " } else { "FAIL" }
$psColor  = if ($psOk) { "Green" } else { "Red" }
Write-Host "  [$psStatus] PowerShell $($psVer.Major).$($psVer.Minor) (requires 5.1+)" -ForegroundColor $psColor
if (-not $psOk) { $allOk = $false }

# Domain membership
try {
    $domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
    Write-Host "  [OK  ] Domain-joined: $($domain.Name)" -ForegroundColor Green
} catch {
    Write-Host "  [FAIL] Not domain-joined - this tool requires an AD environment" -ForegroundColor Red
    $allOk = $false
}

# Admin rights
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    Write-Host "  [OK  ] Running as Administrator" -ForegroundColor Green
} else {
    Write-Host "  [WARN] Not running as Administrator - some checks may fail" -ForegroundColor Yellow
    Write-Host "         Right-click PowerShell and select 'Run as Administrator'" -ForegroundColor Gray
}

# ActiveDirectory module
$adModule = Get-Module -ListAvailable -Name ActiveDirectory -ErrorAction SilentlyContinue
if ($adModule) {
    Write-Host "  [OK  ] ActiveDirectory module available" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] ActiveDirectory module missing (see Step 3)" -ForegroundColor Red
    $allOk = $false
}

# GroupPolicy module
$gpModule = Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue
if ($gpModule) {
    Write-Host "  [OK  ] GroupPolicy module available" -ForegroundColor Green
} else {
    Write-Host "  [WARN] GroupPolicy module missing - GPO checks will be limited (see Step 3)" -ForegroundColor Yellow
}

# DnsServer module
$dnsModule = Get-Module -ListAvailable -Name DnsServer -ErrorAction SilentlyContinue
if ($dnsModule) {
    Write-Host "  [OK  ] DnsServer module available" -ForegroundColor Green
} else {
    Write-Host "  [WARN] DnsServer module missing - DNS checks will be limited (see Step 3)" -ForegroundColor Yellow
}

Write-Host ""

# ---------------------------------------------------------------------------
# STEP 3 - INSTALL MISSING MODULES (if needed)
# ---------------------------------------------------------------------------

Write-Host "STEP 3 - Install missing RSAT modules (only if needed)" -ForegroundColor Yellow
Write-Host ""
Write-Host "  On Windows Server - run in an elevated PowerShell:" -ForegroundColor White
Write-Host ""
Write-Host "      Install-WindowsFeature RSAT-AD-PowerShell    # Active Directory" -ForegroundColor Cyan
Write-Host "      Install-WindowsFeature RSAT-DNS-Server       # DNS Server" -ForegroundColor Cyan
Write-Host "      Install-WindowsFeature GPMC                  # Group Policy" -ForegroundColor Cyan
Write-Host ""
Write-Host "  On Windows 10/11 - run in an elevated PowerShell:" -ForegroundColor White
Write-Host ""
Write-Host "      Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" -ForegroundColor Cyan
Write-Host "      Add-WindowsCapability -Online -Name Rsat.Dns.Tools~~~~0.0.1.0" -ForegroundColor Cyan
Write-Host "      Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 4 - SET EXECUTION POLICY
# ---------------------------------------------------------------------------

Write-Host "STEP 4 - Allow script execution (one-time per machine)" -ForegroundColor Yellow
Write-Host ""

$policy = Get-ExecutionPolicy
$policyOk = $policy -in @('RemoteSigned', 'Unrestricted', 'Bypass')
$policyColor = if ($policyOk) { "Green" } else { "Yellow" }
Write-Host "  Current ExecutionPolicy: $policy" -ForegroundColor $policyColor
Write-Host ""

if (-not $policyOk) {
    Write-Host "  Run this once in an elevated PowerShell:" -ForegroundColor White
    Write-Host ""
    Write-Host "      Set-ExecutionPolicy RemoteSigned -Scope LocalMachine" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Host "  ExecutionPolicy is already compatible - no change needed." -ForegroundColor Green
    Write-Host ""
}

# ---------------------------------------------------------------------------
# STEP 5 - RUN THE TOOL
# ---------------------------------------------------------------------------

Write-Host "STEP 5 - Run the health check" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Navigate to the ADHealthCheck folder and run:" -ForegroundColor White
Write-Host ""
Write-Host "      cd C:\ADHealthCheck" -ForegroundColor Cyan
Write-Host "      .\Invoke-ADHealthCheck.ps1" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Common options:" -ForegroundColor White
Write-Host ""
Write-Host "      # Custom output folder" -ForegroundColor Gray
Write-Host "      .\Invoke-ADHealthCheck.ps1 -OutputPath 'C:\Reports'" -ForegroundColor Cyan
Write-Host ""
Write-Host "      # Run only specific categories" -ForegroundColor Gray
Write-Host "      .\Invoke-ADHealthCheck.ps1 -Categories Replication,Security,DNS" -ForegroundColor Cyan
Write-Host ""
Write-Host "      # Verbose logging" -ForegroundColor Gray
Write-Host "      .\Invoke-ADHealthCheck.ps1 -LogLevel Verbose" -ForegroundColor Cyan
Write-Host ""
Write-Host "      # Increase parallelism (faster on large environments)" -ForegroundColor Gray
Write-Host "      .\Invoke-ADHealthCheck.ps1 -MaxParallelJobs 20" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Valid categories:" -ForegroundColor White
Write-Host "      Replication, DCHealth, DNS, GPO, Time, Backup, Security, Database, Operational" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# STEP 6 - REVIEW RESULTS
# ---------------------------------------------------------------------------

Write-Host "STEP 6 - Review results" -ForegroundColor Yellow
Write-Host ""
Write-Host "  The HTML report opens automatically in the default browser." -ForegroundColor White
Write-Host "  Output is saved to the Output\ folder:" -ForegroundColor White
Write-Host ""
Write-Host "      Output\ADHealthCheck-<forest>-<date>-<runid>.html    interactive report" -ForegroundColor Gray
Write-Host "      Output\logs\ADHealthCheck-<runid>.log                detailed log" -ForegroundColor Gray
Write-Host ""
Write-Host "  Exit codes returned by the tool:" -ForegroundColor White
Write-Host "       0  Healthy - no critical or high issues" -ForegroundColor Green
Write-Host "       1  Critical issues found" -ForegroundColor Red
Write-Host "       2  High priority issues found" -ForegroundColor Yellow
Write-Host "      99  Tool execution error" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------

Write-Host "================================================================" -ForegroundColor Cyan
if ($allOk) {
    Write-Host "  All prerequisites met. Ready to run." -ForegroundColor Green
} else {
    Write-Host "  Prerequisites missing. Resolve FAIL items above before running." -ForegroundColor Red
}
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
