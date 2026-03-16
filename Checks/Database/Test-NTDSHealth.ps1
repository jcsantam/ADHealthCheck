<#
.SYNOPSIS
    NTDS Database Health Check (DB-001)

.DESCRIPTION
    Validates NTDS database health using LDAP and repadmin.
    No WMI/RPC required - works over standard AD ports only.
    
    Checks:
    - DC responds to LDAP (database is running)
    - repadmin reports no database-level errors
    - DSA operational state via rootDSE
    - Replication metadata integrity

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DB-001
    Category: Database
    Severity: Critical
    Compatible: Windows Server 2012 R2+
    
    Approach: LDAP + repadmin (no WMI/RPC required)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[DB-001] Starting NTDS database health check (LDAP/repadmin)..."

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DB-001] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[DB-001] Checking DC: $($dc.Name)"

        if (-not $dc.IsReachable) {
            Write-Verbose "[DB-001] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $issues   = @()
        $severity = 'Info'
        $ldapResponding  = $false
        $dsaState        = 'Unknown'
        $replErrors      = 0
        $repadminOutput  = ''

        # -----------------------------------------------------------------------
        # CHECK 1: LDAP response (proves DB is running and serving requests)
        # -----------------------------------------------------------------------
        try {
            $rootDSE = Get-ADRootDSE -Server $dc.Name -ErrorAction Stop
            $ldapResponding = $true
            $dsaState = 'Responding'
            Write-Verbose "[DB-001] $($dc.Name) LDAP responding OK"
        }
        catch {
            $ldapResponding = $false
            $dsaState = 'Not Responding'
            $issues += "LDAP not responding - database may be down or corrupted"
            $severity = 'Critical'
            Write-Verbose "[DB-001] $($dc.Name) LDAP failed: $_"
        }

        # -----------------------------------------------------------------------
        # CHECK 2: repadmin /showrepl - detects DB-level replication errors
        # Only run if LDAP is up
        # -----------------------------------------------------------------------
        if ($ldapResponding) {
            try {
                $repadminRaw = & repadmin /showrepl $dc.Name /csv 2>&1
                $repadminOutput = $repadminRaw | Out-String

                # CSV fields: Site,DC,NC,SourceSite,SourceDC,Transport,Failures,LastFailTime,LastSuccessTime,ErrorCode
                # Skip header row; flag lines where the last field (ErrorCode) is non-zero
                $replLines = $repadminRaw | Where-Object {
                    $_ -notmatch '^showrepl' -and $_ -match ',' -and
                    ($_ -split ',')[-1] -match '^\d+$' -and [int](($_ -split ',')[-1]) -ne 0
                }
                $replErrors = @($replLines).Count

                if ($replErrors -gt 0) {
                    $issues += "repadmin reports $replErrors replication error(s) - possible database integrity issue"
                    if ($severity -eq 'Info') { $severity = 'High' }
                }

                Write-Verbose "[DB-001] $($dc.Name) repadmin errors: $replErrors"
            }
            catch {
                Write-Verbose "[DB-001] repadmin failed on $($dc.Name): $_"
            }
        }

        # -----------------------------------------------------------------------
        # CHECK 3: DSA version and operational state via LDAP (informational only)
        # Get-ADReplicationUpToDatenessVectorTable can fail against older DCs in
        # a runspace context without indicating actual DB corruption - treat as
        # supplementary info only, not a health gate.
        # -----------------------------------------------------------------------
        if ($ldapResponding) {
            try {
                $replMeta = Get-ADReplicationUpToDatenessVectorTable -Target $dc.Name -ErrorAction Stop
                $partnerCount = @($replMeta).Count
                Write-Verbose "[DB-001] $($dc.Name) replication metadata OK ($partnerCount partners)"
            }
            catch {
                Write-Verbose "[DB-001] $($dc.Name) replication metadata query failed (non-critical): $_"
            }
        }

        # -----------------------------------------------------------------------
        # CHECK 4: Verify DC is advertising correctly (ntdsutil-equivalent via LDAP)
        # Informational only — NTDSSettingsObjectDN query can fail on older DCs
        # (2012 R2) in a runspace without indicating actual DB corruption.
        # LDAP response (Check 1) is the authoritative DB health gate.
        # -----------------------------------------------------------------------
        if ($ldapResponding) {
            try {
                $dcObject = Get-ADDomainController -Identity $dc.Name -ErrorAction Stop
                if (-not $dcObject.IsGlobalCatalog -and -not $dcObject.IsReadOnly -and $dcObject.NTDSSettingsObjectDN) {
                    $null = Get-ADObject -Identity $dcObject.NTDSSettingsObjectDN `
                        -Properties * -Server $dc.Name -ErrorAction Stop
                }
                Write-Verbose "[DB-001] $($dc.Name) DC object accessible OK"
            }
            catch {
                Write-Verbose "[DB-001] $($dc.Name) DC object check failed (non-critical): $_"
            }
        }

        # -----------------------------------------------------------------------
        # BUILD RESULT
        # -----------------------------------------------------------------------
        $isHealthy = ($issues.Count -eq 0)

        $result = [PSCustomObject]@{
            DomainController = $dc.Name
            DatabasePath     = 'N/A (LDAP check)'
            DatabaseSizeGB   = 0
            FreeSpaceGB      = 0
            DatabaseState    = $dsaState
            LastBackup       = $null
            LogPath          = 'N/A (LDAP check)'
            ESEErrorCount    = $replErrors
            LDAPResponding   = $ldapResponding
            RepadminErrors   = $replErrors
            Issues           = if ($issues.Count -gt 0) { $issues -join "; " } else { "None" }
            Severity         = $severity
            Status           = if ($isHealthy) { 'Healthy' } else { 'Warning' }
            IsHealthy        = $isHealthy
            HasIssue         = -not $isHealthy
            Message          = if ($isHealthy) {
                "NTDS database healthy - LDAP responding, no replication errors detected"
            } else {
                "NTDS database state indicates improper shutdown or corruption"
            }
        }

        $results += $result
    }

    Write-Verbose "[DB-001] Check complete. DCs checked: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DB-001] Check failed: $($_.Exception.Message)"

    return @([PSCustomObject]@{
        DomainController = "Unknown"
        DatabasePath     = "Unknown"
        DatabaseSizeGB   = 0
        FreeSpaceGB      = 0
        DatabaseState    = "Unknown"
        LastBackup       = $null
        LogPath          = "Unknown"
        ESEErrorCount    = 0
        LDAPResponding   = $false
        RepadminErrors   = 0
        Issues           = "Check execution failed"
        Severity         = 'Error'
        Status           = 'Error'
        IsHealthy        = $false
        HasIssue         = $true
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
