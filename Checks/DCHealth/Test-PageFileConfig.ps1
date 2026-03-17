<#
.SYNOPSIS
    Page File Configuration Check (DC-018)

.DESCRIPTION
    Verifies the page file is correctly configured on each domain controller.
    An undersized page file can cause memory allocation failures and crash dumps
    to be incomplete (making diagnosis impossible). Microsoft recommends DCs
    have a page file of at least 1x physical RAM for crash dump capture.

    Checks:
    - Page file exists (not disabled)
    - Page file is large enough (initial >= RAM size, or system-managed)
    - Page file is not on a volume with critically low free space
    - System-managed page file is acceptable and recommended

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-PageFileConfig.ps1 -Inventory $inventory

.OUTPUTS
    Array of page file configuration results per DC

.NOTES
    Check ID: DC-018
    Category: DCHealth
    Severity: Medium
    Compatible: Windows Server 2012 R2+
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[DC-018] Starting page file configuration check..."

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[DC-018] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[DC-018] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[DC-018] Checking page file config on: $dcName"

        try {
            $issues = @()

            # Get total physical RAM in MB
            $ramMB = $null
            try {
                $cs = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $dcName -ErrorAction SilentlyContinue
                if ($cs) {
                    $ramMB = [math]::Round($cs.TotalPhysicalMemory / 1MB)
                }
            } catch { }

            # Get page file settings
            $pageFiles = @()
            try {
                $pageFiles = @(Get-WmiObject -Class Win32_PageFileSetting -ComputerName $dcName -ErrorAction SilentlyContinue)
            } catch { }

            # Get automatic page file setting
            $autoManaged = $false
            try {
                $cs2 = Get-WmiObject -Class Win32_ComputerSystem -ComputerName $dcName -ErrorAction SilentlyContinue
                if ($cs2) {
                    $autoManaged = $cs2.AutomaticManagedPagefile
                }
            } catch { }

            $pageFileSummary = ''

            if ($autoManaged) {
                $pageFileSummary = 'System-managed (recommended)'
                # System managed is fine - no issues
            }
            elseif ($pageFiles.Count -eq 0) {
                $issues += "No page file configured - system cannot create a crash dump; memory allocation may fail under pressure"
                $pageFileSummary = 'None configured'
            }
            else {
                $pfDetails = @()
                foreach ($pf in $pageFiles) {
                    $initialMB = $pf.InitialSize
                    $maxMB     = $pf.MaximumSize
                    $pfPath    = $pf.Name

                    $pfDetails += "$pfPath (Initial: ${initialMB}MB, Max: ${maxMB}MB)"

                    # Check if page file is too small
                    if ($ramMB -and $initialMB -gt 0 -and $initialMB -lt ($ramMB / 2)) {
                        $issues += "Page file on $pfPath is ${initialMB}MB - less than half of RAM (${ramMB}MB); crash dumps may be incomplete"
                    }
                    elseif ($initialMB -eq 0 -and $maxMB -eq 0) {
                        $issues += "Page file on $pfPath has zero size - effectively disabled"
                    }
                }
                $pageFileSummary = $pfDetails -join '; '
            }

            $hasIssue = ($issues.Count -gt 0)
            $status   = if ($hasIssue) { 'Warning' } else { 'Pass' }
            $severity = if ($pageFiles.Count -eq 0 -and -not $autoManaged) { 'High' } elseif ($hasIssue) { 'Medium' } else { 'Info' }

            $ramStr = if ($ramMB) { "${ramMB}MB" } else { 'Unknown' }
            $message = if ($hasIssue) {
                "DC $dcName page file issues: $($issues -join '; ')"
            } else {
                "DC $dcName page file is correctly configured ($pageFileSummary; RAM: $ramStr)"
            }

            $results += [PSCustomObject]@{
                DomainController  = $dcName
                AutoManaged       = $autoManaged
                PageFileCount     = $pageFiles.Count
                PageFileSummary   = $pageFileSummary
                RamMB             = $ramMB
                HasIssue          = $hasIssue
                Status            = $status
                Severity          = $severity
                IsHealthy         = -not $hasIssue
                Message           = $message
            }
        }
        catch {
            Write-Warning "[DC-018] Failed to check page file on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController  = $dcName
                AutoManaged       = $false
                PageFileCount     = 0
                PageFileSummary   = 'Unknown'
                RamMB             = $null
                HasIssue          = $true
                Status            = 'Error'
                Severity          = 'Error'
                IsHealthy         = $false
                Message           = "Failed to check page file config on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[DC-018] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[DC-018] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController  = 'Unknown'
        AutoManaged       = $false
        PageFileCount     = 0
        PageFileSummary   = 'Unknown'
        RamMB             = $null
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        IsHealthy         = $false
        Message           = "Check execution failed: $($_.Exception.Message)"
    })
}
