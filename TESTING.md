# ADHealthCheck - Testing & Lab Environment

## Lab Environment

**Domain:** LAB.COM  
**Domain Controllers:** DC01.LAB.COM (Windows Server 2019), DC02.LAB.COM (Windows Server 2019)  
**Purpose:** Validation lab for ADHealthCheck detection capabilities

---

## Chaos Script

The file `Create-ADLabChaos.ps1` is a **lab setup utility** that intentionally introduces
25+ Active Directory issues to validate that ADHealthCheck detects them correctly.

### Important: Already Applied

**This script has already been executed against the LAB.COM environment.**
Do NOT run it again. The issues it creates are already present in the lab and are
intentional — they are not bugs in the tool.

### What the Script Created

| Category | Issues Introduced |
|---|---|
| Security | Weak password policy (6 chars, 90 days), lockout disabled, Guest account enabled, Pre-Windows 2000 Compatible Access group populated |
| Accounts | 200 test users with mixed issues (wrong UPN suffix, PasswordNeverExpires, disabled in wrong OU) |
| Service Accounts | 4 service accounts with duplicate SPNs |
| DNS | 3 orphaned zones, bad forwarders (non-existent IPs), scavenging disabled, insecure zone transfers |
| Replication | Phantom DC metadata (DC03 — not a real DC) |
| GPO | 3 orphaned GPOs (unlinked) |
| Stale Objects | 20 stale computer accounts (lastLogonTimestamp backdated 120 days) |
| Sites & Subnets | 3 subnets with no site assignment, 1 site with no DCs (OrphanedSite) |
| Disk | 500MB dummy file at C:\TestFiles\LargeTestFile.bin |

### Expected Detections

When ADHealthCheck runs against this lab, the following are **expected findings** —
they confirm the tool is working correctly, not errors to investigate:

- SEC-001: Weak password policy
- SEC-002: Account lockout disabled
- SEC-003/004: Stale user/computer accounts
- DNS-003: Bad or unreachable forwarders
- DNS-006: DNS scavenging disabled
- GPO-001: Orphaned GPOs
- OPS-005: Subnets without site assignment
- DCH-003: Disk space warning (DC with large test file)

### Known Lab Limitations

The following issues exist due to lab infrastructure constraints, not tool bugs:

- **DC01 RPC/WMI restrictions** — Some remote checks against DC01 may return limited data
- **Backup age** — Lab DCs have never been backed up; backup age checks will always alert
- **OPS-003 / OPS-004** — Return null in single-domain environments with no trusts (known PS 5.1 edge case)
- **Port 3269 (Global Catalog SSL)** — Test-NetConnection may hang; this is a lab network limitation

---

## Running ADHealthCheck in the Lab

```powershell
# Full run
cd C:\ADHealthCheck
.\Invoke-ADHealthCheck.ps1

# Specific categories only
.\Invoke-ADHealthCheck.ps1 -Categories Security,DNS,Replication

# Verbose output for debugging
.\Invoke-ADHealthCheck.ps1 -LogLevel Verbose
```

Reports are saved to `C:\ADHealthCheck\Output\` and opened automatically in the browser.

---

## Interpreting Results

| Score | Meaning |
|---|---|
| 85-100 | Healthy |
| 70-84 | Warning — review recommended |
| Below 70 | Critical issues present |

In this lab, a score below 70 is **expected** due to the intentional chaos issues.
A successful test run means all 25+ issues are detected and reported correctly.
