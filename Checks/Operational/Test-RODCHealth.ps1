<#
.SYNOPSIS
    RODC Health Check (OPS-015)

.DESCRIPTION
    Checks the health of Read-Only Domain Controllers (RODCs) if any exist in
    the environment. Verifies reachability and whether a Password Replication
    Policy (PRP) is configured. An unconfigured PRP means no passwords are
    cached locally, which may deny authentication if the RODC loses connectivity.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: OPS-015
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

Write-Verbose "[OPS-015] Starting RODC health check..."

$domains = @($Inventory.Domains)

if ($domains.Count -eq 0) {
    return @([PSCustomObject]@{
        Domain           = 'Unknown'
        DomainController = 'N/A'
        IsReachable      = $false
        HasPasswordPolicy = $false
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = 'No domains found in inventory'
    })
}

foreach ($domain in $domains) {
    $domainName = $domain.Name
    Write-Verbose "[OPS-015] Checking RODCs in domain: $domainName"

    try {
        $rodcs = @(Get-ADDomainController -Filter { IsReadOnly -eq $true } -Server $domainName -ErrorAction Stop)

        if ($rodcs.Count -eq 0) {
            Write-Verbose "[OPS-015] No RODCs found in $domainName"
            $results += [PSCustomObject]@{
                Domain            = $domainName
                DomainController  = 'N/A'
                IsReachable       = $true
                HasPasswordPolicy = $true
                IsHealthy         = $true
                HasIssue          = $false
                Status            = 'Pass'
                Severity          = 'Info'
                Message           = "No RODCs found in domain $domainName."
            }
            continue
        }

        foreach ($rodc in $rodcs) {
            $rodcFQDN = $rodc.HostName
            Write-Verbose "[OPS-015] Checking RODC: $rodcFQDN"

            # Check reachability from inventory
            $inventoryDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $rodcFQDN }
            $isReachable = $false
            if ($inventoryDC) {
                $isReachable = $inventoryDC.IsReachable
            }

            # Check Password Replication Policy attributes
            $hasPRP = $false
            try {
                $rodcObj = Get-ADDomainController -Identity $rodcFQDN -Server $domainName -ErrorAction Stop
                $rodcComputerObj = Get-ADComputer -Identity $rodc.ComputerObjectDN `
                    -Properties 'msDS-RevealedDSAs', 'msDS-NeverRevealGroup' `
                    -Server $domainName -ErrorAction Stop

                $revealedDSAs   = $rodcComputerObj.'msDS-RevealedDSAs'
                $neverRevealGrp = $rodcComputerObj.'msDS-NeverRevealGroup'

                if ($null -ne $neverRevealGrp -and @($neverRevealGrp).Count -gt 0) {
                    $hasPRP = $true
                }
                if ($null -ne $revealedDSAs -and @($revealedDSAs).Count -gt 0) {
                    $hasPRP = $true
                }
            }
            catch {
                Write-Verbose "[OPS-015] Could not read PRP attributes for $rodcFQDN - $_"
                $hasPRP = $false
            }

            if (-not $isReachable) {
                $results += [PSCustomObject]@{
                    Domain            = $domainName
                    DomainController  = $rodcFQDN
                    IsReachable       = $false
                    HasPasswordPolicy = $hasPRP
                    IsHealthy         = $false
                    HasIssue          = $true
                    Status            = 'Fail'
                    Severity          = 'High'
                    Message           = "RODC $rodcFQDN is unreachable. Local authentication for branch users may be denied."
                }
            } elseif (-not $hasPRP) {
                $results += [PSCustomObject]@{
                    Domain            = $domainName
                    DomainController  = $rodcFQDN
                    IsReachable       = $true
                    HasPasswordPolicy = $false
                    IsHealthy         = $false
                    HasIssue          = $true
                    Status            = 'Warning'
                    Severity          = 'Medium'
                    Message           = "RODC $rodcFQDN is reachable but no Password Replication Policy appears to be configured. No passwords will be cached locally."
                }
            } else {
                $results += [PSCustomObject]@{
                    Domain            = $domainName
                    DomainController  = $rodcFQDN
                    IsReachable       = $true
                    HasPasswordPolicy = $true
                    IsHealthy         = $true
                    HasIssue          = $false
                    Status            = 'Pass'
                    Severity          = 'Info'
                    Message           = "RODC $rodcFQDN is reachable and has a Password Replication Policy configured."
                }
            }
        }
    }
    catch {
        $results += [PSCustomObject]@{
            Domain            = $domainName
            DomainController  = 'Unknown'
            IsReachable       = $false
            HasPasswordPolicy = $false
            IsHealthy         = $false
            HasIssue          = $true
            Status            = 'Error'
            Severity          = 'Error'
            Message           = "Failed to check RODCs in domain $domainName - $_"
        }
    }
}

Write-Verbose "[OPS-015] Check complete. Results: $($results.Count)"
return $results
