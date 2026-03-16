<#
.SYNOPSIS
    AD Lab Chaos Generator - Creates realistic problems for testing AD Health Check tool

.DESCRIPTION
    This script creates 200 test users across department OUs and introduces various
    Active Directory issues to test the AD Health Check tool's detection capabilities.
    
    WARNING: ONLY RUN IN LAB ENVIRONMENTS - NEVER IN PRODUCTION!

.NOTES
    Domain: lab.com
    DCs: DC01, DC02
    Severity: SEVERE (25+ issues)
    Created: 2026-02-28
    Author: Juan Santamaria
#>

[CmdletBinding()]
param(
    [switch]$WhatIf
)

$ErrorActionPreference = 'Continue'

# Configuration
$Domain = "lab.com"
$DomainDN = "DC=lab,DC=com"
$DC1 = "DC01"
$DC2 = "DC02"
$TotalUsers = 200

# Colors for output
function Write-Status {
    param([string]$Message, [string]$Type = "Info")
    
    switch ($Type) {
        "Success" { Write-Host "[OK] $Message" -ForegroundColor Green }
        "Warning" { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        "Error"   { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        "Info"    { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
        "Chaos"   { Write-Host "[CHAOS] $Message" -ForegroundColor Magenta }
    }
}

# Banner
Clear-Host
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "          AD LAB CHAOS GENERATOR v1.0                          " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "WARNING: THIS WILL MODIFY YOUR ACTIVE DIRECTORY!" -ForegroundColor Red
Write-Host ""
Write-Host "Domain: $Domain" -ForegroundColor White
Write-Host "DCs: $DC1, $DC2" -ForegroundColor White
Write-Host "Users to create: $TotalUsers" -ForegroundColor White
Write-Host "Issues to create: 25+" -ForegroundColor White
Write-Host ""

if ($WhatIf) {
    Write-Status "WHATIF MODE - No changes will be made" "Warning"
} else {
    Write-Host "This is NOT a drill. Changes will be made." -ForegroundColor Red
    Write-Host ""
    $confirm = Read-Host "Type 'CHAOS' to continue"
    
    if ($confirm -ne "CHAOS") {
        Write-Status "Aborted by user" "Error"
        exit
    }
}

Write-Host ""
Write-Status "Starting chaos generation..." "Info"
Start-Sleep -Seconds 2

# ============================================
# PHASE 1: CREATE OU STRUCTURE
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 1: Creating OU Structure" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

$OUs = @(
    "OU=Departments,$DomainDN",
    "OU=IT,OU=Departments,$DomainDN",
    "OU=Sales,OU=Departments,$DomainDN",
    "OU=HR,OU=Departments,$DomainDN",
    "OU=Finance,OU=Departments,$DomainDN",
    "OU=Disabled,OU=Departments,$DomainDN",
    "OU=ServiceAccounts,OU=Departments,$DomainDN"
)

foreach ($OU in $OUs) {
    try {
        if (-not $WhatIf) {
            if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OU'" -ErrorAction SilentlyContinue)) {
                New-ADOrganizationalUnit -Name ($OU -split ',')[0].Replace('OU=','') -Path (($OU -split ',',2)[1]) -ErrorAction Stop
                Write-Status "Created OU: $OU" "Success"
            } else {
                Write-Status "OU already exists: $OU" "Info"
            }
        } else {
            Write-Status "[WHATIF] Would create OU: $OU" "Info"
        }
    } catch {
        Write-Status "Failed to create OU: $OU - $_" "Error"
    }
}

# ============================================
# PHASE 2: CREATE 200 USERS
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 2: Creating 200 Test Users" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

$FirstNames = @("Juan", "Maria", "Carlos", "Ana", "Pedro", "Sofia", "Luis", "Carmen", "Miguel", "Laura",
                "Jose", "Isabel", "Antonio", "Rosa", "Francisco", "Elena", "Manuel", "Patricia", "David", "Monica")

$LastNames = @("Garcia", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Perez", "Sanchez", 
               "Ramirez", "Torres", "Flores", "Rivera", "Gomez", "Diaz", "Cruz", "Morales", "Reyes", 
               "Jimenez", "Ruiz", "Alvarez")

$Departments = @{
    "IT" = @{
        OU = "OU=IT,OU=Departments,$DomainDN"
        Count = 50
        Title = @("Developer", "System Admin", "Network Engineer", "Security Analyst", "DBA")
    }
    "Sales" = @{
        OU = "OU=Sales,OU=Departments,$DomainDN"
        Count = 50
        Title = @("Sales Rep", "Account Manager", "Sales Director", "Regional Manager")
    }
    "HR" = @{
        OU = "OU=HR,OU=Departments,$DomainDN"
        Count = 50
        Title = @("HR Manager", "Recruiter", "HR Specialist", "Benefits Coordinator")
    }
    "Finance" = @{
        OU = "OU=Finance,OU=Departments,$DomainDN"
        Count = 50
        Title = @("Accountant", "Financial Analyst", "Controller", "CFO")
    }
}

$userCount = 0

foreach ($dept in $Departments.Keys) {
    Write-Status "Creating users for $dept department..." "Info"
    
    for ($i = 1; $i -le $Departments[$dept].Count; $i++) {
        $userCount++
        
        $firstName = $FirstNames | Get-Random
        $lastName = $LastNames | Get-Random
        $username = "$($firstName).$($lastName).$i".ToLower()
        $title = $Departments[$dept].Title | Get-Random
        
        # Generate weak password (intentionally bad)
        $password = "Password$i"
        
        # Introduce various issues
        $issueType = Get-Random -Minimum 1 -Maximum 10
        
        $userParams = @{
            Name = "$firstName $lastName"
            GivenName = $firstName
            Surname = $lastName
            SamAccountName = $username
            UserPrincipalName = "$username@$Domain"
            Path = $Departments[$dept].OU
            AccountPassword = (ConvertTo-SecureString $password -AsPlainText -Force)
            Enabled = $true
            ChangePasswordAtLogon = $false
            PasswordNeverExpires = $false
            Title = $title
            Department = $dept
            Company = "Lab Corp"
        }
        
        # Introduce issues based on user number
        if ($issueType -eq 1) {
            # User with no email - dont set EmailAddress
            $userParams.DisplayName = "$firstName $lastName"
        }
        if ($issueType -eq 2) {
            # User with wrong UPN
            $userParams.UserPrincipalName = "$username@wrong.local"
            $userParams.EmailAddress = "$username@$Domain"
            $userParams.DisplayName = "$firstName $lastName"
        }
        if ($issueType -eq 3) {
            # User with no DisplayName - dont set it
            $userParams.EmailAddress = "$username@$Domain"
        }
        if ($issueType -eq 4) {
            # Disabled user should be in Disabled OU
            $userParams.Enabled = $false
            $userParams.EmailAddress = "$username@$Domain"
            $userParams.DisplayName = "$firstName $lastName"
        }
        if ($issueType -eq 5) {
            # Password never expires bad practice
            $userParams.PasswordNeverExpires = $true
            $userParams.EmailAddress = "$username@$Domain"
            $userParams.DisplayName = "$firstName $lastName"
        }
        if ($issueType -ge 6) {
            # Normal user with email
            $userParams.EmailAddress = "$username@$Domain"
            $userParams.DisplayName = "$firstName $lastName"
        }
        
        try {
            if (-not $WhatIf) {
                $existingUser = Get-ADUser -Filter "SamAccountName -eq '$username'" -ErrorAction SilentlyContinue
                if (-not $existingUser) {
                    New-ADUser @userParams -ErrorAction Stop
                    
                    # Set password last set to old date for some users
                    if ($i % 10 -eq 0) {
                        Set-ADUser -Identity $username -Replace @{pwdLastSet=0} -ErrorAction SilentlyContinue
                    }
                    
                    if ($userCount % 20 -eq 0) {
                        Write-Status "Created $userCount users..." "Info"
                    }
                } else {
                    Write-Status "User already exists: $username" "Info"
                }
            }
        } catch {
            Write-Status "Failed to create user $username : $_" "Error"
        }
    }
}

Write-Status "Created $userCount users total" "Success"

# ============================================
# PHASE 3: CREATE SERVICE ACCOUNTS (with issues)
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 3: Creating Service Accounts with issues" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

$serviceAccounts = @(
    @{Name="svc_backup"; SPN="backup/server01.lab.com"},
    @{Name="svc_sql"; SPN="MSSQLSvc/sqlserver.lab.com:1433"},
    @{Name="svc_web"; SPN="HTTP/webserver.lab.com"},
    @{Name="svc_app"; SPN="HTTP/webserver.lab.com"}
)

foreach ($svc in $serviceAccounts) {
    try {
        if (-not $WhatIf) {
            $svcUser = Get-ADUser -Filter "SamAccountName -eq '$($svc.Name)'" -ErrorAction SilentlyContinue
            if (-not $svcUser) {
                New-ADUser -Name $svc.Name `
                          -SamAccountName $svc.Name `
                          -UserPrincipalName "$($svc.Name)@$Domain" `
                          -Path "OU=ServiceAccounts,OU=Departments,$DomainDN" `
                          -AccountPassword (ConvertTo-SecureString "ServicePass123!" -AsPlainText -Force) `
                          -Enabled $true `
                          -PasswordNeverExpires $true `
                          -ErrorAction Stop
                
                # Set SPN some will be duplicates - intentional issue
                setspn -A $svc.SPN "$Domain\$($svc.Name)" | Out-Null
                
                Write-Status "Created service account: $($svc.Name)" "Success"
            }
        }
    } catch {
        Write-Status "Failed to create service account: $($svc.Name)" "Error"
    }
}

# ============================================
# PHASE 4: SECURITY ISSUES
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 4: Creating Security Issues" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

# Issue 1: Weak Password Policy
Write-Status "Setting weak password policy..." "Chaos"
if (-not $WhatIf) {
    try {
        Set-ADDefaultDomainPasswordPolicy -Identity $Domain `
            -MinPasswordLength 6 `
            -MaxPasswordAge "90.00:00:00" `
            -MinPasswordAge "0.00:00:00" `
            -PasswordHistoryCount 3 `
            -ComplexityEnabled $true `
            -ErrorAction Stop
        Write-Status "Weak password policy set min 6 chars 90 days" "Chaos"
    } catch {
        Write-Status "Failed to set password policy: $_" "Error"
    }
}

# Issue 2: Disable Account Lockout
Write-Status "Disabling account lockout policy..." "Chaos"
if (-not $WhatIf) {
    try {
        Set-ADDefaultDomainPasswordPolicy -Identity $Domain `
            -LockoutThreshold 0 `
            -ErrorAction Stop
        Write-Status "Account lockout disabled" "Chaos"
    } catch {
        Write-Status "Failed to disable lockout: $_" "Error"
    }
}

# Issue 3: Enable Guest Account
Write-Status "Enabling Guest account..." "Chaos"
if (-not $WhatIf) {
    try {
        Enable-ADAccount -Identity "Guest" -ErrorAction Stop
        Write-Status "Guest account enabled" "Chaos"
    } catch {
        Write-Status "Failed to enable Guest: $_" "Error"
    }
}

# Issue 4: Add users to Pre-Windows 2000 Compatible Access
Write-Status "Adding users to Pre-Windows 2000 Compatible Access..." "Chaos"
if (-not $WhatIf) {
    try {
        Add-ADGroupMember -Identity "Pre-Windows 2000 Compatible Access" `
                         -Members "Domain Users" `
                         -ErrorAction Stop
        Write-Status "Pre-Windows 2000 Compatible Access populated" "Chaos"
    } catch {
        Write-Status "Failed to add to Pre-Win2000 group: $_" "Error"
    }
}

# ============================================
# PHASE 5: DNS ISSUES
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 5: Creating DNS Issues" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

# Issue 1: Create orphaned DNS zones no IP subnets
$orphanedZones = @("orphaned1.lab.com", "orphaned2.lab.com", "oldzone.lab.com")

foreach ($zone in $orphanedZones) {
    Write-Status "Creating orphaned DNS zone: $zone" "Chaos"
    if (-not $WhatIf) {
        try {
            $existingZone = Get-DnsServerZone -Name $zone -ErrorAction SilentlyContinue
            if (-not $existingZone) {
                Add-DnsServerPrimaryZone -Name $zone -ReplicationScope Domain -ErrorAction Stop
                Write-Status "Created orphaned zone: $zone" "Chaos"
            }
        } catch {
            Write-Status "Failed to create zone $zone : $_" "Error"
        }
    }
}

# Issue 2: Bad DNS Forwarders
Write-Status "Setting bad DNS forwarders..." "Chaos"
if (-not $WhatIf) {
    try {
        Set-DnsServerForwarder -IPAddress @("10.255.255.254", "192.0.2.1") -ErrorAction Stop
        Write-Status "DNS forwarders set to non-existent IPs" "Chaos"
    } catch {
        Write-Status "Failed to set forwarders: $_" "Error"
    }
}

# Issue 3: Disable DNS Scavenging
Write-Status "Disabling DNS scavenging..." "Chaos"
if (-not $WhatIf) {
    try {
        Set-DnsServerScavenging -ScavengingState $false -ErrorAction Stop
        Write-Status "DNS scavenging disabled stale records will accumulate" "Chaos"
    } catch {
        Write-Status "Failed to disable scavenging: $_" "Error"
    }
}

# Issue 4: Allow zone transfers to any server
Write-Status "Configuring insecure zone transfers..." "Chaos"
if (-not $WhatIf) {
    try {
        $zones = Get-DnsServerZone | Where-Object {$_.ZoneName -eq $Domain}
        foreach ($z in $zones) {
            Set-DnsServerPrimaryZone -Name $z.ZoneName -SecureSecondaries TransferAnyServer -ErrorAction SilentlyContinue
        }
        Write-Status "Zone transfers allow any server security risk" "Chaos"
    } catch {
        Write-Status "Failed to set zone transfers: $_" "Error"
    }
}

# ============================================
# PHASE 6: AD REPLICATION ISSUES
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 6: Creating Replication Issues" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

# Issue 1: Create phantom DC metadata
Write-Status "Creating phantom DC metadata DC03..." "Chaos"
if (-not $WhatIf) {
    try {
        $phantomDC = Get-ADComputer -Filter "Name -eq 'DC03'" -ErrorAction SilentlyContinue
        if (-not $phantomDC) {
            New-ADComputer -Name "DC03" `
                          -Path "OU=Domain Controllers,$DomainDN" `
                          -Enabled $false `
                          -ErrorAction Stop
            
            # Set primaryGroupID to 516 Domain Controllers
            Set-ADComputer -Identity "DC03" -Replace @{primaryGroupID=516} -ErrorAction Stop
            
            Write-Status "Created phantom DC: DC03 not a real DC" "Chaos"
        }
    } catch {
        Write-Status "Failed to create phantom DC: $_" "Error"
    }
}

# ============================================
# PHASE 7: GPO ISSUES
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 7: Creating GPO Issues" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

# Issue 1: Create orphaned GPOs not linked anywhere
$orphanedGPOs = @("Orphaned Policy 1", "Orphaned Policy 2", "Test Policy - Delete Me")

foreach ($gpoName in $orphanedGPOs) {
    Write-Status "Creating orphaned GPO: $gpoName" "Chaos"
    if (-not $WhatIf) {
        try {
            $existingGPO = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
            if (-not $existingGPO) {
                New-GPO -Name $gpoName -ErrorAction Stop | Out-Null
                Write-Status "Created orphaned GPO: $gpoName" "Chaos"
            }
        } catch {
            Write-Status "Failed to create GPO $gpoName : $_" "Error"
        }
    }
}

# ============================================
# PHASE 8: STALE OBJECTS
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 8: Creating Stale Computer Objects" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

# Create old computer accounts
for ($i = 1; $i -le 20; $i++) {
    $computerName = "OLDPC$($i.ToString('00'))"
    
    if (-not $WhatIf) {
        try {
            $existingComputer = Get-ADComputer -Filter "Name -eq '$computerName'" -ErrorAction SilentlyContinue
            if (-not $existingComputer) {
                New-ADComputer -Name $computerName `
                              -Path "CN=Computers,$DomainDN" `
                              -Enabled $true `
                              -ErrorAction Stop
                
                # Set last logon to over 90 days ago
                $oldDate = (Get-Date).AddDays(-120)
                Set-ADComputer -Identity $computerName `
                              -Replace @{lastLogonTimestamp=[DateTime]::Parse($oldDate).ToFileTime()} `
                              -ErrorAction SilentlyContinue
                
                if ($i % 5 -eq 0) {
                    Write-Status "Created $i stale computers..." "Info"
                }
            }
        } catch {
            Write-Status "Failed to create computer $computerName : $_" "Error"
        }
    }
}

Write-Status "Created 20 stale computers" "Success"

# ============================================
# PHASE 9: SITE AND SUBNET ISSUES
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 9: Creating Site and Subnet Issues" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

# Issue 1: Create subnets not assigned to any site
$orphanedSubnets = @("192.168.100.0/24", "192.168.200.0/24", "10.10.10.0/24")

foreach ($subnet in $orphanedSubnets) {
    Write-Status "Creating orphaned subnet: $subnet" "Chaos"
    if (-not $WhatIf) {
        try {
            $existingSubnet = Get-ADReplicationSubnet -Filter "Name -eq '$subnet'" -ErrorAction SilentlyContinue
            if (-not $existingSubnet) {
                New-ADReplicationSubnet -Name $subnet -ErrorAction Stop
                # Do not assign to any site - this is the issue
                Write-Status "Created orphaned subnet: $subnet no site assigned" "Chaos"
            }
        } catch {
            Write-Status "Failed to create subnet $subnet : $_" "Error"
        }
    }
}

# Issue 2: Create orphaned site no DCs
Write-Status "Creating orphaned site..." "Chaos"
if (-not $WhatIf) {
    try {
        $orphanSite = Get-ADReplicationSite -Filter "Name -eq 'OrphanedSite'" -ErrorAction SilentlyContinue
        if (-not $orphanSite) {
            New-ADReplicationSite -Name "OrphanedSite" -ErrorAction Stop
            Write-Status "Created orphaned site: OrphanedSite no DCs" "Chaos"
        }
    } catch {
        Write-Status "Failed to create orphaned site: $_" "Error"
    }
}

# ============================================
# PHASE 10: ADDITIONAL CHAOS
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "PHASE 10: Additional Chaos" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

# Create large files to trigger disk space warnings if there is room
Write-Status "Creating large test files disk space warning..." "Chaos"
if (-not $WhatIf) {
    try {
        $testFolder = "C:\TestFiles"
        if (-not (Test-Path $testFolder)) {
            New-Item -Path $testFolder -ItemType Directory -Force | Out-Null
        }
        
        # Create a 500MB file
        $fileName = "$testFolder\LargeTestFile.bin"
        if (-not (Test-Path $fileName)) {
            fsutil file createnew $fileName 524288000 | Out-Null
            Write-Status "Created 500MB test file at $fileName" "Chaos"
        }
    } catch {
        Write-Status "Failed to create large file: $_" "Error"
    }
}

# ============================================
# FINAL REPORT
# ============================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "CHAOS GENERATION COMPLETE!" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "CHAOS SUMMARY:" -ForegroundColor Magenta
Write-Host ""
Write-Host "[OK] Created OUs:" -ForegroundColor Green
Write-Host "   - Departments IT Sales HR Finance Disabled ServiceAccounts" -ForegroundColor White
Write-Host ""
Write-Host "[OK] Created $TotalUsers Users:" -ForegroundColor Green
Write-Host "   - IT: 50 users" -ForegroundColor White
Write-Host "   - Sales: 50 users" -ForegroundColor White
Write-Host "   - HR: 50 users" -ForegroundColor White
Write-Host "   - Finance: 50 users" -ForegroundColor White
Write-Host ""
Write-Host "[CHAOS] ISSUES CREATED:" -ForegroundColor Red
Write-Host ""
Write-Host "Security Issues:" -ForegroundColor Yellow
Write-Host "   [X] Weak password policy 6 chars 90 days" -ForegroundColor White
Write-Host "   [X] Account lockout disabled" -ForegroundColor White
Write-Host "   [X] Guest account enabled" -ForegroundColor White
Write-Host "   [X] Pre-Windows 2000 Compatible Access populated" -ForegroundColor White
Write-Host "   [X] Service accounts with duplicate SPNs" -ForegroundColor White
Write-Host "   [X] Users with wrong UPN suffixes" -ForegroundColor White
Write-Host "   [X] Users without email addresses" -ForegroundColor White
Write-Host "   [X] Users with passwords that never expire" -ForegroundColor White
Write-Host ""
Write-Host "DNS Issues:" -ForegroundColor Yellow
Write-Host "   [X] 3 orphaned DNS zones created" -ForegroundColor White
Write-Host "   [X] Bad DNS forwarders non-existent IPs" -ForegroundColor White
Write-Host "   [X] DNS scavenging disabled" -ForegroundColor White
Write-Host "   [X] Insecure zone transfers allow any server" -ForegroundColor White
Write-Host ""
Write-Host "AD Replication and Metadata Issues:" -ForegroundColor Yellow
Write-Host "   [X] Phantom DC created DC03 - not real" -ForegroundColor White
Write-Host ""
Write-Host "GPO Issues:" -ForegroundColor Yellow
Write-Host "   [X] 3 orphaned GPOs not linked" -ForegroundColor White
Write-Host ""
Write-Host "Stale Objects:" -ForegroundColor Yellow
Write-Host "   [X] 20 stale computer accounts over 90 days old" -ForegroundColor White
Write-Host "   [X] Disabled users not in Disabled OU" -ForegroundColor White
Write-Host ""
Write-Host "Site and Subnet Issues:" -ForegroundColor Yellow
Write-Host "   [X] 3 subnets without site assignment" -ForegroundColor White
Write-Host "   [X] 1 site without DCs OrphanedSite" -ForegroundColor White
Write-Host ""
Write-Host "Performance Issues:" -ForegroundColor Yellow
Write-Host "   [X] Large test file created 500MB" -ForegroundColor White
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "[OK] Your lab is now properly CHAOTIC!" -ForegroundColor Green
Write-Host ""
Write-Host "NEXT STEPS:" -ForegroundColor Cyan
Write-Host "   1. Wait 5 minutes for AD replication" -ForegroundColor White
Write-Host "   2. Run the AD Health Check tool" -ForegroundColor White
Write-Host "   3. Check the HTML report" -ForegroundColor White
Write-Host "   4. Count how many issues were detected!" -ForegroundColor White
Write-Host ""
Write-Host "Expected detections: 25+ issues" -ForegroundColor Yellow
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
