<#
.SYNOPSIS
    Certificate Expiration Check (DC-010)

.DESCRIPTION
    Checks domain controller certificates for expiration.
    Validates LDAPS, Kerberos, and computer certificates.

.PARAMETER Inventory
    Discovered AD inventory object

.NOTES
    Check ID: DC-010
    Category: DCHealth
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

# Thresholds (in days)
$warningThreshold = 30
$criticalThreshold = 7

Write-Verbose "[DC-010] Starting certificate expiration check..."

try {
    $domainControllers = $Inventory.DomainControllers | Where-Object { $_.IsReachable }
    
    if (-not $domainControllers) {
        Write-Warning "[DC-010] No reachable DCs"
        return @()
    }
    
    foreach ($dc in $domainControllers) {
        Write-Verbose "[DC-010] Checking certificates on: $($dc.Name)"
        
        try {
            # Get certificates from remote DC
            $certs = Invoke-Command -ComputerName $dc.HostName -ScriptBlock {
                Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
                    Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) }
            } -ErrorAction Stop
            
            if (-not $certs -or $certs.Count -eq 0) {
                $result = [PSCustomObject]@{
                    DomainController = $dc.Name
                    TotalCertificates = 0
                    ExpiringCertificates = 0
                    CriticalCertificates = 0
                    NearestExpiration = $null
                    DaysUntilExpiration = 999
                    Severity = 'Medium'
                    Status = 'Warning'
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "No certificates found on DC"
                }
                
                $results += $result
                continue
            }
            
            # Analyze certificates
            $totalCerts = $certs.Count
            $expiringCerts = 0
            $criticalCerts = 0
            $nearestExpiration = $null
            $daysUntilNearest = 999
            
            foreach ($cert in $certs) {
                $daysUntilExpiration = ($cert.NotAfter - (Get-Date)).Days
                
                if ($daysUntilExpiration -lt $criticalThreshold) {
                    $criticalCerts++
                }
                elseif ($daysUntilExpiration -lt $warningThreshold) {
                    $expiringCerts++
                }
                
                if ($daysUntilExpiration -lt $daysUntilNearest) {
                    $daysUntilNearest = $daysUntilExpiration
                    $nearestExpiration = $cert.NotAfter
                }
            }
            
            # Determine status
            $hasIssue = ($criticalCerts -gt 0 -or $expiringCerts -gt 0)
            $severity = if ($criticalCerts -gt 0) { 'Critical' }
                       elseif ($expiringCerts -gt 0) { 'High' }
                       else { 'Info' }
            
            $result = [PSCustomObject]@{
                DomainController = $dc.Name
                TotalCertificates = $totalCerts
                ExpiringCertificates = $expiringCerts
                CriticalCertificates = $criticalCerts
                NearestExpiration = $nearestExpiration
                DaysUntilExpiration = $daysUntilNearest
                Severity = $severity
                Status = if ($criticalCerts -gt 0) { 'Failed' }
                        elseif ($expiringCerts -gt 0) { 'Warning' }
                        else { 'Healthy' }
                IsHealthy = -not $hasIssue
                HasIssue = $hasIssue
                Message = if ($criticalCerts -gt 0) {
                    "CRITICAL: $criticalCerts certificate(s) expiring in $daysUntilNearest days!"
                }
                elseif ($expiringCerts -gt 0) {
                    "WARNING: $expiringCerts certificate(s) expiring in $daysUntilNearest days"
                }
                else {
                    "All $totalCerts certificates valid (nearest expires in $daysUntilNearest days)"
                }
            }
            
            $results += $result
        }
        catch {
            Write-Warning "[DC-010] Failed to check certificates on $($dc.Name): $_"
            
            $results += [PSCustomObject]@{
                DomainController = $dc.Name
                TotalCertificates = 0
                ExpiringCertificates = 0
                CriticalCertificates = 0
                NearestExpiration = $null
                DaysUntilExpiration = 0
                Severity = 'Error'
                Status = 'Error'
                IsHealthy = $false
                HasIssue = $true
                Message = "Failed to query certificates: $_"
            }
        }
    }
    
    Write-Verbose "[DC-010] Check complete. DCs checked: $($results.Count)"
    
    return $results
}
catch {
    Write-Error "[DC-010] Check failed: $_"
    
    return @([PSCustomObject]@{
        DomainController = "Unknown"
        TotalCertificates = 0
        ExpiringCertificates = 0
        CriticalCertificates = 0
        NearestExpiration = $null
        DaysUntilExpiration = 0
        Severity = 'Error'
        Status = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $_"
    })
}
