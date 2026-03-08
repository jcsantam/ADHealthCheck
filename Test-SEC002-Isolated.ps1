# =============================================================================
# Test-SEC002-Isolated.ps1
# Isolates the SEC-002 parameter set issue in a runspace environment
# Run this on the DC to find which AD cmdlet works correctly
# =============================================================================

$ErrorActionPreference = 'Continue'

$groupsToTest = @('Domain Admins', 'Enterprise Admins', 'Schema Admins', 'Administrators')

Write-Host ""
Write-Host "=== SEC-002 Isolation Test ===" -ForegroundColor Cyan
Write-Host ""

# Simulate the JSON round-trip that Executor does
$fakeInventory = [PSCustomObject]@{
    Domains = @(
        [PSCustomObject]@{ Name = "LAB.COM" }
    )
}
$invJson = $fakeInventory | ConvertTo-Json -Depth 10 -Compress
$inv = $invJson | ConvertFrom-Json

Write-Host "Domain from JSON: $($inv.Domains[0].Name)" -ForegroundColor Gray
Write-Host ""

# Create a runspace exactly like Executor does
$sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$sessionState.ImportPSModule('ActiveDirectory')
$sessionState.ImportPSModule('DnsServer')
$sessionState.ImportPSModule('GroupPolicy')

$pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 3, $sessionState, $Host)
$pool.Open()

Write-Host "RunspacePool created. Testing AD cmdlets..." -ForegroundColor Yellow
Write-Host ""

# Test each approach in a runspace
$approaches = @(
    @{
        Name = "Approach 1: Get-ADGroup -Identity -Server"
        Script = {
            param($groupName, $domainName)
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            try {
                $g = Get-ADGroup -Identity $groupName -Server $domainName -ErrorAction Stop
                return "OK: $($g.DistinguishedName)"
            } catch {
                return "FAIL: $_"
            }
        }
    },
    @{
        Name = "Approach 2: Get-ADGroup -Identity (no -Server)"
        Script = {
            param($groupName, $domainName)
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            try {
                $g = Get-ADGroup -Identity $groupName -ErrorAction Stop
                return "OK: $($g.DistinguishedName)"
            } catch {
                return "FAIL: $_"
            }
        }
    },
    @{
        Name = "Approach 3: Get-ADGroup -Filter"
        Script = {
            param($groupName, $domainName)
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            try {
                $g = Get-ADGroup -Filter { Name -eq $groupName } -Server $domainName -ErrorAction Stop | Select-Object -First 1
                return "OK: $($g.DistinguishedName)"
            } catch {
                return "FAIL: $_"
            }
        }
    },
    @{
        Name = "Approach 4: Get-ADObject -Filter objectClass=group"
        Script = {
            param($groupName, $domainName)
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            try {
                $g = Get-ADObject -Filter { objectClass -eq 'group' -and Name -eq $groupName } `
                    -Server $domainName -ErrorAction Stop | Select-Object -First 1
                return "OK: $($g.DistinguishedName)"
            } catch {
                return "FAIL: $_"
            }
        }
    },
    @{
        Name = "Approach 5: Get-ADGroupMember -Identity DN (no -Server)"
        Script = {
            param($groupName, $domainName)
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            try {
                $g = Get-ADGroup -Identity $groupName -ErrorAction Stop
                $members = @(Get-ADGroupMember -Identity $g.DistinguishedName -ErrorAction Stop)
                return "OK: $($members.Count) members"
            } catch {
                return "FAIL: $_"
            }
        }
    },
    @{
        Name = "Approach 6: Get-ADGroup -Properties member"
        Script = {
            param($groupName, $domainName)
            Import-Module ActiveDirectory -ErrorAction SilentlyContinue
            try {
                $g = Get-ADGroup -Identity $groupName -Properties member -ErrorAction Stop
                $count = @($g.member).Count
                return "OK: $count members in member attribute"
            } catch {
                return "FAIL: $_"
            }
        }
    }
)

$testGroup = $groupsToTest[0]  # Test with "Domain Admins"
$testDomain = $inv.Domains[0].Name

Write-Host "Testing group: '$testGroup' in domain: '$testDomain'" -ForegroundColor White
Write-Host ""

foreach ($approach in $approaches) {
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.RunspacePool = $pool
    $null = $ps.AddScript($approach.Script)
    $null = $ps.AddArgument($testGroup)
    $null = $ps.AddArgument($testDomain)
    
    $async = $ps.BeginInvoke()
    $result = $ps.EndInvoke($async)
    
    $color = if ($result -match "^OK") { 'Green' } else { 'Red' }
    Write-Host "  $($approach.Name)" -ForegroundColor White
    Write-Host "  Result: $result" -ForegroundColor $color
    Write-Host ""
    
    $ps.Dispose()
}

$pool.Close()
$pool.Dispose()

Write-Host "=== Test Complete ===" -ForegroundColor Cyan
