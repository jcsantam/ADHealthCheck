<#
.SYNOPSIS
    Poll Interval Check (TIME-007)

.DESCRIPTION
    Checks the NTP poll interval configuration on the PDC Emulator for each domain.
    A very long poll interval means time corrections are infrequent, which can allow
    significant clock drift to accumulate.

    SpecialPollInterval is in seconds. MinPollInterval and MaxPollInterval are stored
    as log2 values (i.e., the actual interval = 2^value seconds).

    Checks:
    - SpecialPollInterval > 3600s (1 hour) → Warning
    - SpecialPollInterval > 86400s (1 day) → Fail

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-PollInterval.ps1 -Inventory $inventory

.OUTPUTS
    Array of poll interval results per domain PDC

.NOTES
    Check ID: TIME-007
    Category: Time
    Severity: Medium
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[TIME-007] Starting poll interval check..."

try {
    $domains = $Inventory.Domains

    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[TIME-007] No domains found in inventory"
        return @()
    }

    foreach ($domain in $domains) {
        $pdcName = $domain.PDCEmulator

        Write-Verbose "[TIME-007] Checking poll interval on PDC: $pdcName for domain $($domain.Name)"

        $pdcDC = $Inventory.DomainControllers | Where-Object { $_.Name -eq $pdcName } | Select-Object -First 1

        if (-not $pdcDC -or -not $pdcDC.IsReachable) {
            Write-Warning "[TIME-007] PDC $pdcName is not reachable, skipping domain $($domain.Name)"
            $results += [PSCustomObject]@{
                Domain              = $domain.Name
                PDCEmulator         = $pdcName
                SpecialPollInterval = $null
                MinPollInterval     = $null
                MaxPollInterval     = $null
                HasIssue            = $true
                Status              = 'Error'
                Severity            = 'Error'
                IsHealthy           = $false
                Message             = "PDC $pdcName is not reachable; cannot check poll interval"
            }
            continue
        }

        try {
            $w32tmConfig = w32tm /query /computer:$pdcName /configuration 2>&1

            # Parse SpecialPollInterval (in seconds)
            $specialPollInterval = $null
            $specialLine = $w32tmConfig | Where-Object { $_ -match 'SpecialPollInterval:' }
            if ($specialLine -match 'SpecialPollInterval:\s*(\d+)') {
                $specialPollInterval = [int]$matches[1]
            }

            # Parse MinPollInterval (log2 seconds)
            $minPollLog2 = $null
            $minPollSeconds = $null
            $minLine = $w32tmConfig | Where-Object { $_ -match 'MinPollInterval:' }
            if ($minLine -match 'MinPollInterval:\s*(\d+)') {
                $minPollLog2 = [int]$matches[1]
                $minPollSeconds = [math]::Pow(2, $minPollLog2)
            }

            # Parse MaxPollInterval (log2 seconds)
            $maxPollLog2 = $null
            $maxPollSeconds = $null
            $maxLine = $w32tmConfig | Where-Object { $_ -match 'MaxPollInterval:' }
            if ($maxLine -match 'MaxPollInterval:\s*(\d+)') {
                $maxPollLog2 = [int]$matches[1]
                $maxPollSeconds = [math]::Pow(2, $maxPollLog2)
            }

            $hasIssue = $false
            $status = 'Pass'
            $severity = 'Info'
            $message = ''

            if ($specialPollInterval -eq $null) {
                $hasIssue = $false
                $status = 'Pass'
                $severity = 'Info'
                $message = "SpecialPollInterval not set on PDC $pdcName (using MinPollInterval/MaxPollInterval range)"
            }
            elseif ($specialPollInterval -gt 86400) {
                $hasIssue = $true
                $status = 'Fail'
                $severity = 'High'
                $message = "PDC $pdcName SpecialPollInterval is $specialPollInterval seconds (> 86400s / 1 day) - time corrections are very infrequent"
            }
            elseif ($specialPollInterval -gt 3600) {
                $hasIssue = $true
                $status = 'Warning'
                $severity = 'Medium'
                $message = "PDC $pdcName SpecialPollInterval is $specialPollInterval seconds (> 3600s / 1 hour) - consider reducing for more frequent sync"
            }
            else {
                $message = "PDC $pdcName SpecialPollInterval is $specialPollInterval seconds - within acceptable range"
            }

            $results += [PSCustomObject]@{
                Domain              = $domain.Name
                PDCEmulator         = $pdcName
                SpecialPollInterval = $specialPollInterval
                MinPollIntervalLog2 = $minPollLog2
                MinPollIntervalSecs = $minPollSeconds
                MaxPollIntervalLog2 = $maxPollLog2
                MaxPollIntervalSecs = $maxPollSeconds
                HasIssue            = $hasIssue
                Status              = $status
                Severity            = $severity
                IsHealthy           = -not $hasIssue
                Message             = $message
            }
        }
        catch {
            Write-Warning "[TIME-007] Failed to query poll interval on PDC ${pdcName}: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                Domain              = $domain.Name
                PDCEmulator         = $pdcName
                SpecialPollInterval = $null
                MinPollIntervalLog2 = $null
                MinPollIntervalSecs = $null
                MaxPollIntervalLog2 = $null
                MaxPollIntervalSecs = $null
                HasIssue            = $true
                Status              = 'Error'
                Severity            = 'Error'
                IsHealthy           = $false
                Message             = "Failed to query poll interval configuration: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[TIME-007] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[TIME-007] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        Domain              = 'Unknown'
        PDCEmulator         = 'Unknown'
        SpecialPollInterval = $null
        MinPollIntervalLog2 = $null
        MinPollIntervalSecs = $null
        MaxPollIntervalLog2 = $null
        MaxPollIntervalSecs = $null
        HasIssue            = $true
        Status              = 'Error'
        Severity            = 'Error'
        IsHealthy           = $false
        Message             = "Check execution failed: $($_.Exception.Message)"
    })
}
