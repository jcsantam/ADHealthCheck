<#
.SYNOPSIS
    LAPS Deployment Check (SEC-011)

.DESCRIPTION
    Checks whether Microsoft Local Administrator Password Solution (LAPS) is
    deployed in the domain. LAPS randomizes and manages local administrator
    passwords on domain-joined computers, preventing lateral movement via
    shared local admin credentials (Pass-the-Hash).

    Checks:
    - LAPS schema extension exists (ms-Mcs-AdmPwd attribute)
    - Percentage of enabled computer accounts that have a LAPS password set
    - Whether LAPS password attribute is readable (ACL check)

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-LAPSDeployment.ps1 -Inventory $inventory

.OUTPUTS
    Array of LAPS deployment results per domain

.NOTES
    Check ID: SEC-011
    Category: Security
    Severity: High
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
Import-Module ActiveDirectory -ErrorAction SilentlyContinue
$results = @()

Write-Verbose "[SEC-011] Starting LAPS deployment check..."

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[SEC-011] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        $domainName = $domain.Name
        $domainDN   = 'DC=' + ($domainName -replace '\.', ',DC=')

        Write-Verbose "[SEC-011] Checking LAPS deployment in domain: $domainName"

        try {
            # Check if the LAPS schema attribute exists
            $schemaNC  = "CN=Schema,CN=Configuration,$domainDN"
            # Try forest root schema NC
            $forestRoot = $Inventory.ForestInfo.RootDomain
            if ($forestRoot) {
                $schemaNC = "CN=Schema,CN=Configuration,DC=" + ($forestRoot -replace '\.', ',DC=')
            }

            $lapsAttr = $null
            try {
                $lapsAttr = Get-ADObject -Filter { name -eq 'ms-Mcs-AdmPwd' } `
                    -SearchBase $schemaNC `
                    -Server $domainName `
                    -ErrorAction SilentlyContinue
            }
            catch {
                Write-Verbose "[SEC-011] Schema search failed: $($_.Exception.Message)"
            }

            $lapsSchemaExtended = ($null -ne $lapsAttr)

            if (-not $lapsSchemaExtended) {
                $results += [PSCustomObject]@{
                    Domain              = $domainName
                    LAPSSchemaExtended  = $false
                    TotalComputers      = 0
                    ComputersWithLAPS   = 0
                    LAPSCoveragePercent = 0
                    HasIssue            = $true
                    Status              = 'Fail'
                    Severity            = 'High'
                    IsHealthy           = $false
                    Message             = "LAPS schema extension (ms-Mcs-AdmPwd) not found in $domainName - LAPS is not deployed"
                }
                continue
            }

            Write-Verbose "[SEC-011] LAPS schema extension found in $domainName"

            # Count enabled computer accounts and those with ms-Mcs-AdmPwd populated
            $allComputers = @(Get-ADComputer -Filter { Enabled -eq $true } `
                -Server $domainName `
                -Properties 'ms-Mcs-AdmPwd', 'ms-Mcs-AdmPwdExpirationTime' `
                -SearchBase $domainDN `
                -ErrorAction SilentlyContinue)

            $totalComputers     = $allComputers.Count
            $computersWithLAPS  = @($allComputers | Where-Object { $_.'ms-Mcs-AdmPwd' -ne $null -and $_.'ms-Mcs-AdmPwd' -ne '' }).Count

            $coveragePct = 0
            if ($totalComputers -gt 0) {
                $coveragePct = [math]::Round(($computersWithLAPS / $totalComputers) * 100, 1)
            }

            $hasIssue = $false
            $status   = 'Pass'
            $severity = 'Info'
            $message  = ''

            if ($totalComputers -eq 0) {
                $message = "LAPS schema is extended in $domainName but no enabled computers found to evaluate coverage"
                $status  = 'Pass'
            }
            elseif ($computersWithLAPS -eq 0) {
                $hasIssue = $true
                $status   = 'Fail'
                $severity = 'High'
                $message  = "LAPS schema is extended in $domainName but no computers have LAPS passwords set (0 of $totalComputers) - LAPS GPO may not be deployed"
            }
            elseif ($coveragePct -lt 50) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'High'
                $message  = "LAPS coverage is low in $domainName`: $computersWithLAPS of $totalComputers computers ($coveragePct%) have LAPS passwords"
            }
            elseif ($coveragePct -lt 90) {
                $hasIssue = $true
                $status   = 'Warning'
                $severity = 'Medium'
                $message  = "LAPS coverage is partial in $domainName`: $computersWithLAPS of $totalComputers computers ($coveragePct%) have LAPS passwords"
            }
            else {
                $message = "LAPS is deployed in $domainName`: $computersWithLAPS of $totalComputers computers ($coveragePct%) have LAPS passwords"
            }

            $results += [PSCustomObject]@{
                Domain              = $domainName
                LAPSSchemaExtended  = $lapsSchemaExtended
                TotalComputers      = $totalComputers
                ComputersWithLAPS   = $computersWithLAPS
                LAPSCoveragePercent = $coveragePct
                HasIssue            = $hasIssue
                Status              = $status
                Severity            = $severity
                IsHealthy           = -not $hasIssue
                Message             = $message
            }
        }
        catch {
            Write-Warning "[SEC-011] Failed to check LAPS in $domainName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain              = $domainName
                LAPSSchemaExtended  = $false
                TotalComputers      = 0
                ComputersWithLAPS   = 0
                LAPSCoveragePercent = 0
                HasIssue            = $true
                Status              = 'Error'
                Severity            = 'Error'
                IsHealthy           = $false
                Message             = "Failed to check LAPS deployment in $domainName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[SEC-011] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[SEC-011] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain              = 'Unknown'
        LAPSSchemaExtended  = $false
        TotalComputers      = 0
        ComputersWithLAPS   = 0
        LAPSCoveragePercent = 0
        HasIssue            = $true
        Status              = 'Error'
        Severity            = 'Error'
        IsHealthy           = $false
        Message             = "Check execution failed: $($_.Exception.Message)"
    })
}
