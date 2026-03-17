<#
.SYNOPSIS
    LDAP Signing Requirements Check (OPS-013)

.DESCRIPTION
    Checks whether domain controllers require LDAP signing. Without required
    signing, attackers can intercept and modify LDAP traffic via man-in-the-middle
    attacks. Uses remote registry via WMI StdRegProv.

    Registry values:
        0 = None (no signing)
        1 = Negotiate signing (default, but not enforced)
        2 = Require signing (recommended)

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-013
    Category: Operational
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

Write-Verbose "[OPS-013] Starting LDAP signing requirements check..."

$reachableDCs = @($Inventory.DomainControllers | Where-Object { $_.IsReachable -eq $true })

if ($reachableDCs.Count -eq 0) {
    return @([PSCustomObject]@{
        DomainController  = 'N/A'
        LDAPSigningValue  = $null
        LDAPSigningName   = 'Unknown'
        RequiresSigning   = $false
        IsHealthy         = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        Message           = 'No reachable domain controllers found'
    })
}

$signingNames = @{
    0 = 'None'
    1 = 'Negotiate signing'
    2 = 'Require signing'
}

foreach ($dc in $reachableDCs) {
    $dcName = $dc.Name
    Write-Verbose "[OPS-013] Checking LDAP signing on: $dcName"

    try {
        $regPath = 'SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
        $HKLM = 2147483650
        $wmiReg = [WMIClass]"\\$dcName\root\default:StdRegProv"

        $regResult = $wmiReg.GetDWORDValue($HKLM, $regPath, 'LDAPServerIntegrity')

        # If the value is not found (ReturnValue non-zero or null), treat as default (1)
        $ldapSigningValue = 1
        if ($regResult.ReturnValue -eq 0 -and $null -ne $regResult.uValue) {
            $ldapSigningValue = [int]$regResult.uValue
        }

        $signingName = $signingNames[$ldapSigningValue]
        if ([string]::IsNullOrEmpty($signingName)) {
            $signingName = "Unknown ($ldapSigningValue)"
        }

        $requiresSigning = $false
        if ($ldapSigningValue -eq 2) {
            $requiresSigning = $true
        }

        if ($ldapSigningValue -eq 0) {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                LDAPSigningValue = $ldapSigningValue
                LDAPSigningName  = $signingName
                RequiresSigning  = $false
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Fail'
                Severity         = 'High'
                Message          = "LDAP signing is DISABLED on $dcName (value=0). LDAP relay attacks are possible."
            }
        } elseif ($ldapSigningValue -eq 1) {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                LDAPSigningValue = $ldapSigningValue
                LDAPSigningName  = $signingName
                RequiresSigning  = $false
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Warning'
                Severity         = 'Medium'
                Message          = "LDAP signing is negotiated but not required on $dcName (value=1). Set LDAPServerIntegrity=2 to require signing."
            }
        } else {
            $results += [PSCustomObject]@{
                DomainController = $dcName
                LDAPSigningValue = $ldapSigningValue
                LDAPSigningName  = $signingName
                RequiresSigning  = $true
                IsHealthy        = $true
                HasIssue         = $false
                Status           = 'Pass'
                Severity         = 'Info'
                Message          = "LDAP signing is required on $dcName (value=2). LDAP relay attacks are mitigated."
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            DomainController = $dcName
            LDAPSigningValue = $null
            LDAPSigningName  = 'Unknown'
            RequiresSigning  = $false
            IsHealthy        = $false
            HasIssue         = $true
            Status           = 'Error'
            Severity         = 'Error'
            Message          = "Failed to check LDAP signing on $dcName - $_"
        }
    }
}

Write-Verbose "[OPS-013] Check complete. DCs checked: $($results.Count)"
return $results
