<#
.SYNOPSIS
    Critical SRV Records Check (DNS-001)

.DESCRIPTION
    Validates that essential AD SRV records are present and correct:
    - _ldap._tcp.dc._msdcs.DOMAIN
    - _kerberos._tcp.dc._msdcs.DOMAIN
    - _gc._tcp.FOREST
    - _ldap._tcp.SITE._sites.dc._msdcs.DOMAIN

.PARAMETER Inventory
    Discovered AD inventory object

.EXAMPLE
    .\Test-CriticalSRVRecords.ps1 -Inventory $inventory

.OUTPUTS
    Array of SRV record validation results

.NOTES
    Check ID: DNS-001
    Category: DNS
    Severity: Critical
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [PSCustomObject]$Inventory
)

$ErrorActionPreference = 'Continue'
$results = @()

Write-Verbose "[DNS-001] Starting critical SRV records check..."

try {
    # Get forest and domain info
    $forestName = $Inventory.ForestInfo.Name
    $domains = $Inventory.Domains
    
    if (-not $domains -or $domains.Count -eq 0) {
        Write-Warning "[DNS-001] No domains found in inventory"
        return @()
    }
    
    Write-Verbose "[DNS-001] Checking SRV records for $($domains.Count) domain(s)..."
    
    foreach ($domain in $domains) {
        $domainName = $domain.Name
        
        Write-Verbose "[DNS-001] Processing domain: $domainName"
        
        # Critical SRV records to check
        $criticalRecords = @(
            @{
                Name = "_ldap._tcp.dc._msdcs.$domainName"
                Description = "LDAP service for domain controllers"
                Type = "Domain Controller Location"
            },
            @{
                Name = "_kerberos._tcp.dc._msdcs.$domainName"
                Description = "Kerberos service for domain controllers"
                Type = "Kerberos KDC"
            },
            @{
                Name = "_ldap._tcp.$domainName"
                Description = "LDAP service for domain"
                Type = "LDAP Service"
            },
            @{
                Name = "_kerberos._tcp.$domainName"
                Description = "Kerberos service for domain"
                Type = "Kerberos Service"
            },
            @{
                Name = "_gc._tcp.$forestName"
                Description = "Global Catalog service"
                Type = "Global Catalog"
            }
        )
        
        foreach ($record in $criticalRecords) {
            try {
                # Query DNS for SRV record
                $srvRecords = Resolve-DnsName -Name $record.Name -Type SRV -ErrorAction Stop
                
                if ($srvRecords -and $srvRecords.Count -gt 0) {
                    # Record exists
                    $result = [PSCustomObject]@{
                        Domain = $domainName
                        RecordName = $record.Name
                        RecordType = $record.Type
                        Description = $record.Description
                        RecordCount = $srvRecords.Count
                        Targets = ($srvRecords | ForEach-Object { $_.NameTarget }) -join ", "
                        Status = 'Healthy'
                        Severity = 'Info'
                        IsHealthy = $true
                        HasIssue = $false
                        Message = "SRV record found with $($srvRecords.Count) target(s)"
                    }
                }
                else {
                    # Record not found
                    $result = [PSCustomObject]@{
                        Domain = $domainName
                        RecordName = $record.Name
                        RecordType = $record.Type
                        Description = $record.Description
                        RecordCount = 0
                        Targets = "None"
                        Status = 'Failed'
                        Severity = 'Critical'
                        IsHealthy = $false
                        HasIssue = $true
                        Message = "CRITICAL: Required SRV record not found in DNS"
                    }
                }
                
                $results += $result
            }
            catch {
                # DNS query failed
                Write-Warning "[DNS-001] Failed to query SRV record $($record.Name): $($_.Exception.Message)"
                
                $result = [PSCustomObject]@{
                    Domain = $domainName
                    RecordName = $record.Name
                    RecordType = $record.Type
                    Description = $record.Description
                    RecordCount = 0
                    Targets = "Unknown"
                    Status = 'Failed'
                    Severity = 'Critical'
                    IsHealthy = $false
                    HasIssue = $true
                    Message = "CRITICAL: SRV record missing or DNS query failed"
                }
                
                $results += $result
            }
        }
    }
    
    Write-Verbose "[DNS-001] Check complete. SRV records checked: $($results.Count)"
    
    # Summary
    $missingCount = ($results | Where-Object { $_.HasIssue }).Count
    $healthyCount = ($results | Where-Object { $_.IsHealthy }).Count
    
    Write-Verbose "[DNS-001] Healthy: $healthyCount, Missing: $missingCount"
    
    if ($missingCount -gt 0) {
        Write-Warning "[DNS-001] CRITICAL: $missingCount SRV record(s) missing or inaccessible"
    }
    
    return $results
}
catch {
    Write-Error "[DNS-001] Check failed: $($_.Exception.Message)"
    
    return @([PSCustomObject]@{
        Domain = "Unknown"
        RecordName = "Unknown"
        RecordType = "Unknown"
        Description = "Unknown"
        RecordCount = 0
        Targets = "Unknown"
        Status = 'Error'
        Severity = 'Error'
        IsHealthy = $false
        HasIssue = $true
        Message = "Check execution failed: $($_.Exception.Message)"
    })
}
