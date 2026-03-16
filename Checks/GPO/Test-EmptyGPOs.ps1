<#
.SYNOPSIS
    Empty GPO Detection (GPO-007)
.DESCRIPTION
    Identifies GPOs that have no settings (both Computer and User DSVersion = 0).
    Empty GPOs are cleanup candidates and may indicate misconfiguration or
    leftover policy objects from decommissioned workloads.
    Requires the GroupPolicy module - if not available, returns Pass with skip message.
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: GPO-007
    Category: GPO
    Severity: Low
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[GPO-007] Starting empty GPO detection..."

# Check for GroupPolicy module availability
$gpoModule = Get-Module -ListAvailable -Name GroupPolicy -ErrorAction SilentlyContinue
if (-not $gpoModule) {
    return @([PSCustomObject]@{
        Domain           = 'N/A'
        GPOName          = 'N/A'
        GPOID            = 'N/A'
        ComputerDSVersion = $null
        UserDSVersion    = $null
        GpoStatus        = 'N/A'
        IsEmpty          = $false
        IsHealthy        = $true
        HasIssue         = $false
        Status           = 'Pass'
        Severity         = 'Info'
        Message          = 'GroupPolicy module not available - skipping empty GPO check'
    })
}

try {
    Import-Module GroupPolicy -ErrorAction SilentlyContinue

    $domains = $Inventory.Domains
    if (-not $domains) {
        Write-Warning "[GPO-007] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        Write-Verbose "[GPO-007] Checking GPOs in domain: $($domain.Name)"

        try {
            $allGPOs = @(Get-GPO -All -Domain $domain.Name -ErrorAction Stop)
            Write-Verbose "[GPO-007] Found $($allGPOs.Count) GPO(s) in $($domain.Name)"
        }
        catch {
            Write-Warning "[GPO-007] Failed to enumerate GPOs in $($domain.Name): $_"
            $results += [PSCustomObject]@{
                Domain            = $domain.Name
                GPOName           = 'N/A'
                GPOID             = 'N/A'
                ComputerDSVersion = $null
                UserDSVersion     = $null
                GpoStatus         = 'N/A'
                IsEmpty           = $false
                IsHealthy         = $false
                HasIssue          = $true
                Status            = 'Error'
                Severity          = 'Error'
                Message           = "Failed to enumerate GPOs in $($domain.Name): $($_.Exception.Message)"
            }
            continue
        }

        $foundIssue = $false

        foreach ($gpo in $allGPOs) {
            $computerDSVersion = $gpo.Computer.DSVersion
            $userDSVersion     = $gpo.User.DSVersion
            $gpoStatus         = $gpo.GpoStatus.ToString()
            $isEmpty           = ($computerDSVersion -eq 0 -and $userDSVersion -eq 0)

            if ($isEmpty) {
                $foundIssue = $true

                $statusMsg = if ($gpoStatus -eq 'AllSettingsDisabled') {
                    "GPO '$($gpo.DisplayName)' in $($domain.Name) has no settings (both DSVersion=0) and is fully disabled"
                } else {
                    "GPO '$($gpo.DisplayName)' in $($domain.Name) has no settings (both Computer and User DSVersion=0) - cleanup candidate"
                }

                $results += [PSCustomObject]@{
                    Domain            = $domain.Name
                    GPOName           = $gpo.DisplayName
                    GPOID             = $gpo.Id.ToString()
                    ComputerDSVersion = $computerDSVersion
                    UserDSVersion     = $userDSVersion
                    GpoStatus         = $gpoStatus
                    IsEmpty           = $true
                    IsHealthy         = $false
                    HasIssue          = $true
                    Status            = 'Warning'
                    Severity          = 'Low'
                    Message           = $statusMsg
                }
            }
        }

        if (-not $foundIssue) {
            $results += [PSCustomObject]@{
                Domain            = $domain.Name
                GPOName           = 'N/A'
                GPOID             = 'N/A'
                ComputerDSVersion = $null
                UserDSVersion     = $null
                GpoStatus         = 'N/A'
                IsEmpty           = $false
                IsHealthy         = $true
                HasIssue          = $false
                Status            = 'Pass'
                Severity          = 'Info'
                Message           = "$($domain.Name): All $($allGPOs.Count) GPO(s) have at least one configured setting"
            }
        }
    }

    Write-Verbose "[GPO-007] Check complete. Results: $(@($results).Count)"
    return $results
}
catch {
    Write-Error "[GPO-007] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain            = 'Unknown'
        GPOName           = 'N/A'
        GPOID             = 'N/A'
        ComputerDSVersion = $null
        UserDSVersion     = $null
        GpoStatus         = 'N/A'
        IsEmpty           = $false
        IsHealthy         = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        Message           = "Check execution failed: $($_.Exception.Message)"
    })
}
