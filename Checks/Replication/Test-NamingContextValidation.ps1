<#
.SYNOPSIS
    Naming Context Validation (REP-015)
.DESCRIPTION
    Validates that all domain controllers host the expected naming contexts
    (Domain NC, Configuration NC, Schema NC) and none are missing.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: REP-015
    Category: Replication
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

Write-Verbose "[REP-015] Starting naming context validation..."

# Single-DC guard
$dcCount = @($Inventory.DomainControllers).Count
if ($dcCount -eq 1) {
    return [PSCustomObject]@{
        IsHealthy   = $true
        HasIssue    = $false
        Status      = 'Pass'
        Severity    = 'Info'
        Message     = 'Single-DC environment - check not applicable'
    }
}

try {
    $forestName = $Inventory.ForestInfo.Name
    $forestDN   = 'DC=' + ($forestName -replace '\.', ',DC=')

    # Build expected naming contexts
    $expectedNCs = @()

    # Schema NC
    $expectedNCs += "CN=Schema,CN=Configuration,$forestDN"
    # Configuration NC
    $expectedNCs += "CN=Configuration,$forestDN"
    # Forest root domain NC
    $expectedNCs += $forestDN

    # Add any additional domain NCs
    foreach ($domain in $Inventory.Domains) {
        $domainDN = 'DC=' + ($domain.Name -replace '\.', ',DC=')
        if ($domainDN -ne $forestDN -and $expectedNCs -notcontains $domainDN) {
            $expectedNCs += $domainDN
        }
    }

    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }

    if (-not $domainControllers) {
        Write-Warning "[REP-015] No reachable DCs found"
        return @()
    }

    foreach ($dc in $domainControllers) {
        Write-Verbose "[REP-015] Checking naming contexts on: $($dc.Name)"

        try {
            $rootDSE    = [ADSI]"LDAP://$($dc.Name)/RootDSE"
            $actualNCs  = @($rootDSE.namingContexts)

            # Determine which NCs this DC is expected to host
            # All DCs must have their domain NC, Config NC, and Schema NC
            $domainDN   = 'DC=' + ($dc.Domain -replace '\.', ',DC=')
            $thisDCExpected = @(
                $domainDN,
                "CN=Configuration,$forestDN",
                "CN=Schema,CN=Configuration,$forestDN"
            )

            $missingNCs = @($thisDCExpected | Where-Object {
                $nc = $_
                -not ($actualNCs | Where-Object { $_ -eq $nc })
            })

            $missingCount = @($missingNCs).Count
            $hasIssue     = $missingCount -gt 0

            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                ExpectedNCs      = ($thisDCExpected -join '; ')
                ActualNCs        = ($actualNCs -join '; ')
                MissingNCs       = ($missingNCs -join '; ')
                MissingNCCount   = $missingCount
                IsHealthy        = -not $hasIssue
                HasIssue         = $hasIssue
                Status           = if ($hasIssue) { 'Fail' } else { 'Healthy' }
                Severity         = if ($hasIssue) { 'High' } else { 'Info' }
                Message          = if ($hasIssue) {
                    "$($dc.Name) is missing $missingCount naming context(s): $($missingNCs -join ', ')"
                } else {
                    "$($dc.Name) has all expected naming contexts ($(@($actualNCs).Count) NCs present)"
                }
            }
        }
        catch {
            Write-Warning "[REP-015] Failed to query RootDSE on $($dc.Name): $_"
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                ExpectedNCs      = ''
                ActualNCs        = ''
                MissingNCs       = ''
                MissingNCCount   = 0
                IsHealthy        = $false
                HasIssue         = $true
                Status           = 'Error'
                Severity         = 'Error'
                Message          = "Failed to query RootDSE on $($dc.Name): $_"
            }
        }
    }

    Write-Verbose "[REP-015] Check complete. DCs checked: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[REP-015] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController = 'Unknown'
        ExpectedNCs      = ''
        ActualNCs        = ''
        MissingNCs       = ''
        MissingNCCount   = 0
        IsHealthy        = $false
        HasIssue         = $true
        Status           = 'Error'
        Severity         = 'Error'
        Message          = "Check execution failed: $($_.Exception.Message)"
    })
}
