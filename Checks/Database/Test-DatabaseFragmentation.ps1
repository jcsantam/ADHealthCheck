<#
.SYNOPSIS
    Database Fragmentation Check (DB-002)

.DESCRIPTION
    Checks NTDS database fragmentation and white space.
    High fragmentation impacts performance and wastes disk space.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DB-002
    Category: Database
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

# Thresholds
$warningThreshold = 20  # 20% white space
$criticalThreshold = 40 # 40% white space

Write-Verbose "[DB-002] Starting database fragmentation check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DB-002] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DB-002] Checking database on: $($dc.Name)"
        
        try {
            # Get NTDS database path
            $dbPath = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
                (Get-ItemProperty -Path $regPath -Name "DSA Database file")."DSA Database file"
            } -ErrorAction Stop
            
            # Run esentutl to get database stats (non-invasive)
            $dbStats = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                param($DbPath)
                
                $output = & esentutl /ms $DbPath 2>&1 | Out-String
                
                $stats = @{
                    DatabaseSize = 0
                    WhiteSpace = 0
                    StreamingFileSize = 0
                }
                
                # Parse output
                if ($output -match "Database Size:\s+(\d+)\s+pages") {
                    $stats.DatabaseSize = [int64]$matches[1]
                }
                
                if ($output -match "Streaming file size:\s+(\d+)\s+bytes") {
                    $stats.StreamingFileSize = [int64]$matches[1]
                }
                
                if ($output -match "Space Available:\s+(\d+)\s+pages") {
                    $stats.WhiteSpace = [int64]$matches[1]
                }
                
                return $stats
            } -ArgumentList $dbPath -ErrorAction Stop
            
            # Calculate fragmentation
            $totalPages = $dbStats.DatabaseSize
            $whiteSpacePages = $dbStats.WhiteSpace
            
            $whiteSpacePercent = if ($totalPages -gt 0) {
                [math]::Round(($whiteSpacePages / $totalPages) * 100, 1)
            } else {
                0
            }
            
            $databaseSizeGB = [math]::Round(($totalPages * 8192) / 1GB, 2)  # 8KB pages
            $whiteSpaceGB = [math]::Round(($whiteSpacePages * 8192) / 1GB, 2)
            
            # Determine status
            $hasIssue = $whiteSpacePercent -gt $warningThreshold
            $severity = if ($whiteSpacePercent -gt $criticalThreshold) { 'High' }
                       elseif ($whiteSpacePercent -gt $warningThreshold) { 'Medium' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                DatabasePath = $dbPath
                DatabaseSizeGB = $databaseSizeGB
                WhiteSpaceGB = $whiteSpaceGB
                WhiteSpacePercent = $whiteSpacePercent
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = $severity
                Status = if ($whiteSpacePercent -gt $criticalThreshold) { 'Warning' }
                        elseif ($whiteSpacePercent -gt $warningThreshold) { 'Info' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($whiteSpacePercent -gt $criticalThreshold) {
                    "High fragmentation: $whiteSpacePercent% white space ($whiteSpaceGB GB) - consider offline defrag"
                }
                elseif ($whiteSpacePercent -gt $warningThreshold) {
                    "Moderate fragmentation: $whiteSpacePercent% white space ($whiteSpaceGB GB)"
                }
                else {
                    "Low fragmentation: $whiteSpacePercent% white space ($whiteSpaceGB GB)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DB-002] Failed to check database on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                DatabasePath = "Unknown"
                DatabaseSizeGB = 0
                WhiteSpaceGB = 0
                WhiteSpacePercent = 0
                WarningThreshold = $warningThreshold
                CriticalThreshold = $criticalThreshold
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query database: $_"
            }
        }
    }
    
    Write-Verbose "[DB-002] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DB-002] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        DatabasePath = "Unknown"
        DatabaseSizeGB = 0
        WhiteSpaceGB = 0
        WhiteSpacePercent = 0
        WarningThreshold = $warningThreshold
        CriticalThreshold = $criticalThreshold
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
