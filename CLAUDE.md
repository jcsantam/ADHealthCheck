# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Project Goal

**AD Health Check** is a PowerShell 5.1 enterprise tool that replicates and exceeds Microsoft's ADST 5.8 (~635 health checks) for Active Directory infrastructure monitoring. It targets L3-grade diagnostics: maximum visibility, actionable output, compatibility from Windows Server 2012 R2 through 2025.

Current state: **v2.0.0 — 50 checks implemented**, score ~56/100 in lab (remaining failures are confirmed real chaos findings). Roadmap lives in `Documentation/ADST-Comparison-Gap-Analysis.md` and `Documentation/BUILD-PLAN-COMPREHENSIVE.md`.

---

## Lab Environment

| Host | OS | Role | IP |
|------|----|----|-----|
| DC01.LAB.COM | Windows Server 2012 R2 | ADDS + DNS, holds all 4 FSMO roles | 192.168.200.10 |
| DC02.LAB.COM | Windows Server 2016 | ADDS — **primary workstation: Claude Code, git, ADHealthCheck all run here** | 192.168.200.11 |
| HC01.LAB.COM | Windows Server 2016 | Member server (currently OFF) | 192.168.200.20 |
| PC01.LAB.COM | Windows 11 Pro | Client (currently OFF) | 192.168.200.201 |

**Chaos already applied** (`Create-ADLabChaos.ps1` — **do not run again**). The following are intentional and will always fire:

| Check | Expected finding |
|-------|-----------------|
| SEC-006 / password policy | Min 6 chars, 90 days, lockout threshold = 0 |
| SEC-002 / privileged accounts | Guest account enabled; Pre-Win2000 group has Domain Users |
| SEC-007 / SPN conflicts | svc_web + svc_app share `HTTP/webserver.lab.com` |
| SEC-005 / stale users | ~20 users with PasswordNeverExpires; ~20 with wrong UPN suffix |
| DNS-003 / forwarders | Bad IPs: 10.255.255.254, 192.0.2.1 |
| DNS-007 / scavenging | Scavenging disabled |
| DNS-005 / zone transfers | lab.com allows transfer to any server |
| REP-008 / metadata | Phantom DC03 in Domain Controllers OU (not a real DC) |
| GPO-004 / orphaned GPOs | "Orphaned Policy 1", "Orphaned Policy 2", "Test Policy - Delete Me" |
| OPS-011 / site topology | OrphanedSite (no DCs); 3 subnets unassigned to any site |
| BACKUP-001 / backup age | Lab DCs never backed up — will always alert |

**Known lab limitations** (not tool bugs):
- DC01 RPC/WMI restrictions — some remote checks return limited data
- Port 3269 (GC SSL) — `Test-NetConnection` may hang
- OPS-003/OPS-004 return null in single-domain/no-trust environments (PS 5.1 edge case)
- Score below 70 is expected — chaos creates 25+ real findings

---

## Running the Tool

```powershell
# Full run
.\Invoke-ADHealthCheck.ps1

# Specific categories
.\Invoke-ADHealthCheck.ps1 -Categories Replication,Security

# Verbose (L3 diagnostics)
.\Invoke-ADHealthCheck.ps1 -LogLevel Verbose

# Higher parallelism
.\Invoke-ADHealthCheck.ps1 -MaxParallelJobs 20
```

There is no build step and no test runner. Validation is done by running against a live AD lab. The database must be initialized before first use:

```powershell
.\Database\Initialize-Database.ps1
```

---

## Architecture

The engine (`Core/Engine.ps1`) orchestrates 8 phases: Logger → Discovery → Executor → Evaluator → Scorer → DatabaseOps → JSON Definitions → HTML Reports.

**Execution flow:**
1. `Invoke-ADHealthCheck.ps1` → loads `Core/Engine.ps1`
2. `Core/Discovery.ps1` builds `$Inventory` (forests, domains, DCs, sites, FSMO roles)
3. `Core/Compatibility.ps1` detects OS version and sets method flags (CIM vs WMI, etc.)
4. `Core/Executor.ps1` runs each `Checks/**/*.ps1` in a RunspacePool, passing `$Inventory`
5. Each check returns an array of `[PSCustomObject]` results
6. `Core/Evaluator.ps1` matches results against rules in `Definitions/*.json`
7. `Core/Scorer.ps1` computes weighted 0–100 health score
8. `Core/DatabaseOperations.ps1` persists to SQLite; reports written to `Output/`

**Check definitions** (`Definitions/*.json`) contain `CheckId`, `Severity`, `EvaluationRules`, `PassMessage`, `FailMessage`, and optional thresholds. Every check script must have a matching JSON entry in its category file.

---

## PowerShell 5.1 Coding Rules

These are strict — violations cause runtime errors in the lab.

### Forbidden patterns

| Pattern | Reason | Use instead |
|---------|--------|-------------|
| `$x ?? $default` | PS 7+ only | `if ($null -ne $x) { $x } else { $default }` |
| `$x ??= $default` | PS 7+ only | `if ($null -eq $x) { $x = $default }` |
| `$dc.DNSHostName` | Not set on inventory objects | `$dc.Name` (FQDN) or `$dc.HostName` (short name) |
| `Get-ADDomain` inside a check loop | Runspace context issues; causes partition DN errors | Build `$domainDN` directly (see below) |
| `Get-CimInstance` without compat check | Fails on 2012 R2 | Use `Get-WmiObject` or `Get-CompatibleSystemInfo` |
| `[string]::IsNullOrEmpty($x)` on PS objects | Type mismatch edge cases | `-not $x` or `-not [string]::IsNullOrWhiteSpace($x)` |

### Domain DN construction (critical pattern)

Never call `Get-ADDomain` inside a check. Build the DN from the inventory domain name:

```powershell
$domainDN = 'DC=' + ($domain.Name -replace '\.', ',DC=')
# e.g. "lab.com" → "DC=lab,DC=com"

# Use for SearchBase:
Get-ADObject -Filter "..." -SearchBase "CN=System,$domainDN" -Server $domain.Name
```

### Single-DC environment guard

Replication checks must short-circuit in single-DC labs to avoid false positives:

```powershell
$dcCount = @($Inventory.DomainControllers).Count
if ($dcCount -eq 1) {
    return [PSCustomObject]@{
        IsHealthy = $true
        Status    = 'Pass'
        Message   = 'Single-DC environment - check not applicable'
    }
}
```

---

## Check Script Structure

Every check follows this exact pattern. Deviations cause Executor failures.

```powershell
<#
.SYNOPSIS
    <Short description> (<CHECK-ID>)
.DESCRIPTION
    <What it checks>
.PARAMETER Inventory
    Discovered AD inventory object
.NOTES
    Check ID: XXX-NNN
    Category: <Category>
    Severity: Critical|High|Medium|Low
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

Write-Verbose "[XXX-NNN] Starting <check name>..."

try {
    # ... check logic ...

    foreach ($item in $collection) {
        $results += [PSCustomObject]@{
            # Required fields:
            IsHealthy  = $true / $false
            HasIssue   = $true / $false
            Status     = 'Healthy' / 'Warning' / 'Fail' / 'Info'
            Severity   = 'Critical' / 'High' / 'Medium' / 'Low' / 'Info'
            Message    = "Human-readable status"
            # Check-specific fields as needed
        }
    }

    return $results
}
catch {
    Write-Error "[XXX-NNN] Check failed: $($_.Exception.Message)"
    return @([PSCustomObject]@{
        IsHealthy = $false
        HasIssue  = $true
        Status    = 'Error'
        Severity  = 'Error'
        Message   = "Check execution failed: $($_.Exception.Message)"
    })
}
```

**Key output field rules:**
- `IsHealthy` and `HasIssue` must always be present (they are Boolean, opposite of each other)
- `Status` must be one of: `Healthy`, `Warning`, `Fail`, `Info`, `Pass`, `Error`
- `Severity` must be one of: `Critical`, `High`, `Medium`, `Low`, `Info`, `Error`
- Never `throw` — always return an error result object
- `Write-Verbose` messages must be prefixed with `[CHECK-ID]`

### JSON Definition structure

Each check needs an entry in its `Definitions/<Category>.json`:

```json
{
  "CheckId": "XXX-NNN",
  "CheckName": "Human Name",
  "Category": "CategoryName",
  "Severity": "Critical",
  "ScriptPath": "Test-CheckName.ps1",
  "PassMessage": "Everything is healthy",
  "FailMessage": "Issue detected",
  "EvaluationRules": [
    {
      "RuleId": "XXX-NNN-HASISSUE",
      "Condition": "Any(HasIssue == true)",
      "Status": "Fail",
      "Severity": "critical",
      "Message": "Issue description"
    }
  ],
  "IsEnabled": true,
  "Version": "2.0"
}
```

---

## Compatibility Layer

`Core/Compatibility.ps1` provides version-adaptive functions. Use these in new checks instead of raw WMI/CIM calls:

| Function | Purpose |
|----------|---------|
| `Get-CompatibleSystemInfo -ComputerName $dc` | OS info (WMI on 2012R2, CIM on 2016+) |
| `Get-CompatibleProcessInfo -ComputerName $dc` | Process info |
| `Get-CompatibleServiceInfo -ComputerName $dc` | Service info |
| `Get-CompatibleEventLog -ComputerName $dc -LogName ... -EventIds ...` | Event log (Get-EventLog on 2012R2, Get-WinEvent on 2016+) |
| `Get-CompatibleReplicationInfo -DomainController $dc` | AD replication metadata |
| `Test-SysvolReplicationMethod` | Returns `'DFSR'` or `'FRS'` |

---

## Implemented Checks (99 total — v2.0.0-beta)

| Category | IDs | Count |
|----------|-----|-------|
| Replication | REP-001–REP-010 | 10 |
| DC Health | DC-001–DC-010 | 10 |
| Security | SEC-001–SEC-016 | 16 |
| DNS | DNS-001–DNS-005, DNS-007–DNS-012 | 11 |
| GPO | GPO-002–GPO-011 | 10 |
| Database | DB-001, DB-002, DB-004 | 3 |
| Backup | BACKUP-001–BACKUP-003 | 3 |
| Operational | FSMO-001, FSMO-002, TRUST-001, TRUST-002, OPS-SiteTopology, OPS-006–OPS-015 | 15 |
| Time | TIME-001–TIME-010 | 10 |
| SPNConflicts | SEC-007 (SPN) | 1 |

---

## Backlog — Next Checks to Build

Priority order from gap analysis. Build in batches of 10–20.

### Batch A — Remaining from Top-50 Critical list (15 checks)

| ID | Name | Script | Category |
|----|------|--------|----------|
| REP-011 | KCC Errors | Test-KCCErrors.ps1 | Replication |
| REP-012 | Site Link Topology | Test-SiteLinkTopology.ps1 | Replication |
| REP-013 | Bridgehead Server Health | Test-BridgeheadServer.ps1 | Replication |
| REP-014 | Replication Schedule Conflicts | Test-ReplicationSchedule.ps1 | Replication |
| REP-015 | Naming Context Validation | Test-NamingContexts.ps1 | Replication |
| DC-011 | Event Log Critical Errors | Test-EventLogErrors.ps1 | DCHealth |
| DC-012 | Network Adapter Status | Test-NetworkAdapters.ps1 | DCHealth |
| DC-013 | LSASS Memory Usage | Test-LSASSMemory.ps1 | DCHealth |
| SEC-007 | SPN Conflicts/Duplicates | Test-SPNConflicts.ps1 | Security |
| SEC-008 | Delegation Configuration | Test-DelegationConfig.ps1 | Security |
| SEC-010 | Kerberos Policy | Test-KerberosPolicy.ps1 | Security |
| GPO-006 | WMI Filter Validation | Test-WMIFilters.ps1 | GPO |
| DNS-006 | Dynamic Update Security | Test-DynamicUpdateSecurity.ps1 | DNS |
| DB-003 | White Space Analysis | Test-DatabaseWhiteSpace.ps1 | Database |
| BACKUP-004 | Deleted Object Lifetime | Test-DeletedObjectLifetime.ps1 | Backup |

### Batch B — Time Sync completion (8 checks)

| ID | Name | Script |
|----|------|--------|
| TIME-003 | NTP Server Reachability | Test-NTPReachability.ps1 |
| TIME-004 | Time Provider Configuration | Test-TimeProviderConfig.ps1 |
| TIME-005 | W32Time Service Startup | Test-W32TimeService.ps1 |
| TIME-006 | Stratum Level | Test-StratumLevel.ps1 |
| TIME-007 | Poll Interval | Test-PollInterval.ps1 |
| TIME-008 | Time Correction Rate | Test-TimeCorrectionRate.ps1 |
| TIME-009 | Time Zone Consistency | Test-TimeZoneConsistency.ps1 |
| TIME-010 | Daylight Saving Time | Test-DSTConfiguration.ps1 |

### Batch C — GPO completion (5 checks)

| ID | Name | Script |
|----|------|--------|
| GPO-007 | Empty GPOs | Test-EmptyGPOs.ps1 |
| GPO-008 | Disabled GPO Links | Test-DisabledGPOLinks.ps1 |
| GPO-009 | Blocked Inheritance | Test-BlockedInheritance.ps1 |
| GPO-010 | GPO Link Order | Test-GPOLinkOrder.ps1 |
| GPO-011 | Cross-Domain GPO Links | Test-CrossDomainGPOLinks.ps1 |

### Batch D — DNS completion (5 checks)

| ID | Name | Script |
|----|------|--------|
| DNS-008 | Aging Configuration | Test-DNSAging.ps1 |
| DNS-009 | Reverse Lookup Zones | Test-ReverseLookupZones.ps1 |
| DNS-010 | Conditional Forwarders | Test-ConditionalForwarders.ps1 |
| DNS-011 | DNS Recursion Settings | Test-DNSRecursion.ps1 |
| DNS-012 | DNSSEC Configuration | Test-DNSSECConfig.ps1 |

### Batch E — Operational/Config (10 checks)

| ID | Name | Script |
|----|------|--------|
| OPS-001 | DIT File Location | Test-DITLocation.ps1 |
| OPS-002 | Log File Location | Test-LogFileLocation.ps1 |
| OPS-003 | SYSVOL Location | Test-SYSVOLLocation.ps1 |
| OPS-004 | Garbage Collection | Test-GarbageCollection.ps1 |
| OPS-005 | Schema Version | Test-SchemaVersion.ps1 |
| OPS-006 | Forest Functional Level | Test-ForestFunctionalLevel.ps1 |
| OPS-007 | Domain Functional Level | Test-DomainFunctionalLevel.ps1 |
| OPS-008 | LDAP Signing Requirements | Test-LDAPSigning.ps1 |
| OPS-009 | LDAPS Configuration | Test-LDAPSConfig.ps1 |
| OPS-010 | RODC Health | Test-RODCHealth.ps1 |

### Batch G — Database completion (4 checks)

| ID | Name | Script |
|----|------|--------|
| DB-005 | Database Growth Rate | Test-DatabaseGrowthRate.ps1 |
| DB-006 | Index Fragmentation | Test-IndexFragmentation.ps1 |
| DB-007 | Deleted Object Accumulation | Test-DeletedObjectAccumulation.ps1 |
| DB-008 | ESE Database Errors | Test-ESEErrors.ps1 |

---

## Inventory Object Shape

The `$Inventory` object passed to every check has these top-level properties:

```powershell
$Inventory.Domains              # Array of domain objects with .Name, .DN, .PDCEmulator
$Inventory.DomainControllers    # Array of DC objects with .Name, .IsReachable, .IsGlobalCatalog, .Site
$Inventory.ForestInfo           # .RootDomain, .ForestMode, .SchemaMaster
$Inventory.Sites                # Array of AD site objects
$Inventory.FSMORoles            # FSMO role holder names
```

DC objects have:
- `.Name` — FQDN (e.g. `DC01.LAB.COM`) — use for `-ComputerName`, `-Server`
- `.HostName` — short name (e.g. `DC01`) — use when matching AD object names in Distinguished Names (e.g. `CN=DC01,...`)
