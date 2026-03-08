<#
.SYNOPSIS
    FSMO Availability Testing Check (FSMO-002)

.DESCRIPTION
    Tests FSMO role holder availability and responsiveness.
    Goes beyond basic placement to verify actual functionality.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: FSMO-002
    Category: Operational
    Severity: Critical
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[FSMO-002] Starting FSMO availability testing check..."

try {
    $forestInfo = $Inventory.ForestInfo
    $domains = $Inventory.Domains
    
    # Test Schema Master
    if ($forestInfo) {
        $schemaMaster = $forestInfo.SchemaMaster
        
        Write-Verbose "[FSMO-002] Testing Schema Master: $schemaMaster"
        
        try {
            # Test LDAP connectivity
            $ldapTest = Test-NetConnection -ComputerName $schemaMaster -Port 389 -WarningAction SilentlyContinue
            
            # Test if we can query the schema
            $schemaTest = $false
            try {
                $schema = Get-ADObject -Identity "CN=Schema,CN=Configuration,$((Get-ADRootDSE -Server $schemaMaster).defaultNamingContext)" -Server $schemaMaster -ErrorAction Stop
                $schemaTest = ($schema -ne $null)
            }
            catch {
                $schemaTest = $false
            }
            
            $available = ($ldapTest.TcpTestSucceeded -and $schemaTest)
            
            $result = [PSCustomObject]@{
                Role = "Schema Master"
                Holder = $schemaMaster
                LDAPResponding = $ldapTest.TcpTestSucceeded
                RoleResponding = $schemaTest
                Available = $available
                Severity = if (-not $available) { 'Critical' } else { 'Info' }
                Status = if ($available) { 'Healthy' } else { 'Failed' }
                IsHealthy = $available
                HasIssue = -not $available
                Message = if ($available) {
                    "Schema Master available and responding"
                } else {
                    "CRITICAL: Schema Master not available!"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[FSMO-002] Failed to test Schema Master: $_"
        }
        
        # Test Domain Naming Master
        $domainNamingMaster = $forestInfo.DomainNamingMaster
        
        Write-Verbose "[FSMO-002] Testing Domain Naming Master: $domainNamingMaster"
        
        try {
            $ldapTest = Test-NetConnection -ComputerName $domainNamingMaster -Port 389 -WarningAction SilentlyContinue
            
            # Test if we can query partitions container
            $partitionsTest = $false
            try {
                $partitions = Get-ADObject -Identity "CN=Partitions,CN=Configuration,$((Get-ADRootDSE -Server $domainNamingMaster).defaultNamingContext)" -Server $domainNamingMaster -ErrorAction Stop
                $partitionsTest = ($partitions -ne $null)
            }
            catch {
                $partitionsTest = $false
            }
            
            $available = ($ldapTest.TcpTestSucceeded -and $partitionsTest)
            
            $result = [PSCustomObject]@{
                Role = "Domain Naming Master"
                Holder = $domainNamingMaster
                LDAPResponding = $ldapTest.TcpTestSucceeded
                RoleResponding = $partitionsTest
                Available = $available
                Severity = if (-not $available) { 'Critical' } else { 'Info' }
                Status = if ($available) { 'Healthy' } else { 'Failed' }
                IsHealthy = $available
                HasIssue = -not $available
                Message = if ($available) {
                    "Domain Naming Master available and responding"
                } else {
                    "CRITICAL: Domain Naming Master not available!"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[FSMO-002] Failed to test Domain Naming Master: $_"
        }
    }
    
    # Test domain-level FSMO roles
    foreach ($domain in $domains) {
        # Test PDC Emulator
        $pdcEmulator = $domain.PDCEmulator
        
        Write-Verbose "[FSMO-002] Testing PDC Emulator: $pdcEmulator"
        
        try {
            $ldapTest = Test-NetConnection -ComputerName $pdcEmulator -Port 389 -WarningAction SilentlyContinue
            
            # Test time service (PDC-specific)
            $timeTest = $false
            try {
                $w32tm = & w32tm /monitor /computers:$pdcEmulator /nowarn 2>&1 | Out-String
                $timeTest = ($w32tm -notmatch "error")
            }
            catch {
                $timeTest = $false
            }
            
            $available = $ldapTest.TcpTestSucceeded
            
            $result = [PSCustomObject]@{
                Role = "PDC Emulator ($($domain.Name))"
                Holder = $pdcEmulator
                LDAPResponding = $ldapTest.TcpTestSucceeded
                RoleResponding = $timeTest
                Available = $available
                Severity = if (-not $available) { 'Critical' } else { 'Info' }
                Status = if ($available) { 'Healthy' } else { 'Failed' }
                IsHealthy = $available
                HasIssue = -not $available
                Message = if ($available) {
                    "PDC Emulator available and responding"
                } else {
                    "CRITICAL: PDC Emulator not available!"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[FSMO-002] Failed to test PDC Emulator: $_"
        }
    }
    
    Write-Verbose "[FSMO-002] Check complete. Roles tested: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[FSMO-002] Check failed: $_"
    
    return @([PSCustomObject]@{
        Role = "Unknown"
        Holder = "Unknown"
        LDAPResponding = $false
        RoleResponding = $false
        Available = $false
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
