<#
.SYNOPSIS
    Inbound Replication Disabled Check (REP-023)

.DESCRIPTION
    Detects domain controllers that have inbound replication disabled.
    Inbound replication can be disabled via 'repadmin /options <DC> +DISABLE_INBOUND_REPL'
    or via the registry (Repl Perform Initial Synchronizations = 0 is separate).

    A DC with inbound replication disabled will not receive AD changes from
    its replication partners. This is a critical configuration issue — DCs
    may diverge from the rest of the environment, serving stale data.

    Detection method:
    - Parses 'repadmin /options <DC>' for 'DISABLE_INBOUND_REPL' flag
    - Checks registry key: SYSTEM\CurrentControlSet\Services\NTDS\Parameters
      'Repl Perform Initial Synchronizations' = 0

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-InboundReplDisabled.ps1 -Inventory $inventory

.OUTPUTS
    Array of inbound replication disabled results per DC

.NOTES
    Check ID: REP-023
    Category: Replication
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

Write-Verbose "[REP-023] Starting inbound replication disabled check..."

$HKLM        = [uint32]'0x80000002'
$NTDS_KEY    = 'SYSTEM\CurrentControlSet\Services\NTDS\Parameters'

try {
    $domainControllers = $Inventory.DomainControllers

    if (-not $domainControllers -or $domainControllers.Count -eq 0) {
        Write-Warning "[REP-023] No domain controllers found in inventory"
        return @()
    }

    foreach ($dc in $domainControllers) {
        if (-not $dc.IsReachable) {
            Write-Verbose "[REP-023] DC $($dc.Name) is not reachable, skipping"
            continue
        }

        $dcName = $dc.Name
        Write-Verbose "[REP-023] Checking inbound replication status on: $dcName"

        try {
            $inboundDisabled   = $false
            $outboundDisabled  = $false
            $issues            = @()

            # Check via repadmin /options
            try {
                $replOptions = & repadmin /options $dcName 2>$null
                if ($replOptions) {
                    $optStr = $replOptions -join ' '
                    if ($optStr -match 'DISABLE_INBOUND_REPL') {
                        $inboundDisabled = $true
                        $issues += "Inbound replication is DISABLED via repadmin options - DC is not receiving AD changes"
                    }
                    if ($optStr -match 'DISABLE_OUTBOUND_REPL') {
                        $outboundDisabled = $true
                        $issues += "Outbound replication is DISABLED via repadmin options - DC is not sending AD changes to partners"
                    }
                }
            }
            catch {
                Write-Verbose "[REP-023] repadmin /options failed on $dcName`: $($_.Exception.Message)"
            }

            # Check registry for 'Repl Perform Initial Synchronizations'
            try {
                $reg = [WMIClass]"\\$dcName\root\default:StdRegProv"
                $r   = $reg.GetDWORDValue($HKLM, $NTDS_KEY, 'Repl Perform Initial Synchronizations')
                if ($r.ReturnValue -eq 0 -and $r.uValue -eq 0) {
                    $issues += "Registry 'Repl Perform Initial Synchronizations' = 0 - initial replication sync on startup is disabled"
                }
            }
            catch {
                Write-Verbose "[REP-023] Registry check failed on $dcName"
            }

            $hasIssue = ($issues.Count -gt 0)
            $status   = if ($inboundDisabled) { 'Fail' } elseif ($hasIssue) { 'Warning' } else { 'Pass' }
            $severity = if ($inboundDisabled) { 'Critical' } elseif ($outboundDisabled) { 'High' } `
                        elseif ($hasIssue) { 'Medium' } else { 'Info' }

            $message = if ($hasIssue) {
                "DC $dcName replication disabled issues: $($issues -join '; ')"
            } else {
                "DC $dcName inbound and outbound replication are enabled"
            }

            $results += [PSCustomObject]@{
                DomainController  = $dcName
                InboundDisabled   = $inboundDisabled
                OutboundDisabled  = $outboundDisabled
                HasIssue          = $hasIssue
                Status            = $status
                Severity          = $severity
                IsHealthy         = -not $hasIssue
                Message           = $message
            }
        }
        catch {
            Write-Warning "[REP-023] Failed to check replication status on $dcName`: $($_.Exception.Message)"
            $results += [PSCustomObject]@{
                DomainController  = $dcName
                InboundDisabled   = $false
                OutboundDisabled  = $false
                HasIssue          = $true
                Status            = 'Error'
                Severity          = 'Error'
                IsHealthy         = $false
                Message           = "Failed to check inbound replication status on $dcName`: $($_.Exception.Message)"
            }
        }
    }

    Write-Verbose "[REP-023] Check complete. Results: $($results.Count)"
    return $results
}
catch {
    Write-Error "[REP-023] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        DomainController  = 'Unknown'
        InboundDisabled   = $false
        OutboundDisabled  = $false
        HasIssue          = $true
        Status            = 'Error'
        Severity          = 'Error'
        IsHealthy         = $false
        Message           = "Check execution failed: $($_.Exception.Message)"
    })
}
