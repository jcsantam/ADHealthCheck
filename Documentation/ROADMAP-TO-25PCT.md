# Roadmap to 25% ADST Coverage — 160 Checks

**Created:** 2026-03-17
**Current state:** 103 checks / 16.2% coverage
**Target:** 160 checks / 25.2% coverage
**Checks to build:** 57 across 6 batches (H–M)

---

## Current vs. Target by Category

| Category | ADST Total | Current | Target | To Build | Target % |
|----------|-----------|---------|--------|----------|----------|
| Replication | 147 | 15 | 23 | +8 | 15.6% |
| DC Health | 155 | 13 | 20 | +7 | 12.9% |
| Security | 89 | 16 | 26 | +10 | 29.2% |
| DNS | 79 | 12 | 20 | +8 | 25.3% |
| Group Policy | 45 | 10 | 15 | +5 | 33.3% |
| Database | 43 | 8 | 15 | +7 | 34.9% |
| Operational | 33 | 15 | 22 | +7 | 66.7% |
| Backup | 32 | 4 | 9 | +5 | 28.1% |
| Time Sync | 12 | 10 | 10 | 0 | 83.3% |
| **TOTAL** | **635** | **103** | **160** | **+57** | **25.2%** |

---

## Priority Framework

Each check is rated by:
- **Impact** — how often this finding appears in real AD environments
- **Detectability** — what is missed without this check
- **ADST equivalence** — does ADST flag this in its standard run

Only checks with HIGH impact are included. No filler.

---

## Batch H — DC Health Completion (7 checks)

**Goal:** Close the largest coverage gap in DC Health. These checks cover OS-level
health that every L3 engineer checks manually today.

| ID | Name | Script | What it detects |
|----|------|--------|-----------------|
| DC-014 | Netlogon Service Health | Test-NetlogonHealth.ps1 | Secure channel, NETLOGON share, netlogon.log errors |
| DC-015 | DC Locator Test | Test-DCLocator.ps1 | Whether clients can locate this DC (nltest equivalent) |
| DC-016 | AD Port Connectivity | Test-ADPortConnectivity.ps1 | TCP 389/636/3268/3269/88/135/445 between all DC pairs |
| DC-017 | IPv6 Configuration | Test-IPv6Config.ps1 | IPv6 enabled but not managed, or incorrectly disabled |
| DC-018 | Page File Configuration | Test-PageFileConfig.ps1 | System-managed or correctly sized page file on DCs |
| DC-019 | Windows Update Status | Test-WindowsUpdateStatus.ps1 | Last scan/install date, pending critical updates count |
| DC-020 | Power Plan Settings | Test-PowerPlanConfig.ps1 | High Performance power plan enforced on all DCs |

**Why this batch first:** DC Health is the highest-count ADST category (155 checks)
and the checks above are queried in every real-world incident ticket.

---

## Batch I — Replication Deep Dive (8 checks)

**Goal:** Add diagnostics that go beyond the basic replication checks already
implemented. These detect subtle topology and convergence problems.

| ID | Name | Script | What it detects |
|----|------|--------|-----------------|
| REP-016 | ISTG Election Health | Test-ISTGHealth.ps1 | Inter-Site Topology Generator is elected and responsive |
| REP-017 | UTD Vector Analysis | Test-UTDVectors.ps1 | Up-to-dateness vectors: detects stale partners and gaps |
| REP-018 | Conflict Object Detection | Test-ConflictObjects.ps1 | CNF/CNFR objects from replication conflicts |
| REP-019 | Change Notification | Test-ChangeNotification.ps1 | Change notification disabled on site links (causes delay) |
| REP-020 | Cross-Site Replication Health | Test-CrossSiteReplication.ps1 | Inter-site replication latency and failure rates |
| REP-021 | Replication Failure History | Test-ReplicationFailureHistory.ps1 | Pattern of consecutive failures per partner |
| REP-022 | DC Connection Object Audit | Test-ConnectionObjectAudit.ps1 | Manual vs. auto-generated connection objects, stale ones |
| REP-023 | Inbound Replication Disabled | Test-InboundReplDisabled.ps1 | DCs with inbound replication disabled (repadmin /options) |

**Why:** Replication issues are the #1 ADST finding category. UTD vectors and
conflict objects are two of the most frequently missed diagnostics.

---

## Batch J — Security Deep Dive (10 checks)

**Goal:** Address the most impactful security gaps — detection of privilege abuse
vectors that are commonly exploited in AD attacks (DCSync, reversible passwords,
anonymous LDAP, etc.).

| ID | Name | Script | What it detects |
|----|------|--------|-----------------|
| SEC-017 | Fine-Grained Password Policies | Test-FineGrainedPwdPolicy.ps1 | PSOs exist, are applied to right groups, not too permissive |
| SEC-018 | Enterprise Admins Monitoring | Test-EnterpriseAdminsMembership.ps1 | EA group should be empty except during forest changes |
| SEC-019 | DCSync Rights Detection | Test-DCSyncRights.ps1 | Non-DC accounts with DS-Replication-Get-Changes-All |
| SEC-020 | Reversible Password Encryption | Test-ReversibleEncryption.ps1 | Accounts with reversible encryption enabled |
| SEC-021 | Inactive Privileged Accounts | Test-InactivePrivAccounts.ps1 | DA/EA accounts with no logon in 30+ days |
| SEC-022 | Pre-Windows 2000 Compatible Access | Test-PreWin2000Group.ps1 | Dangerous Everyone/Authenticated Users in this group |
| SEC-023 | Anonymous LDAP Access | Test-AnonymousLDAP.ps1 | Whether unauthenticated LDAP queries are permitted |
| SEC-024 | LDAP Channel Binding | Test-LDAPChannelBinding.ps1 | Registry: LDAP channel binding and signing enforcement |
| SEC-025 | Kerberos AES Encryption | Test-KerberosAES.ps1 | Accounts with only DES/RC4, no AES Kerberos support |
| SEC-026 | Dangerous ACEs on Domain Root | Test-DomainRootACL.ps1 | Non-default GenericAll/WriteDACL/WriteOwner on domain root |

**Why:** DCSync rights and anonymous LDAP are the top two findings in red team
reports. Pre-Win2000 group is a classic misconfiguration that persists for years.

---

## Batch K — DNS Completion (8 checks)

**Goal:** Cover the DNS checks that ADST runs in its standard DNS diagnostic pass
but we currently miss entirely.

| ID | Name | Script | What it detects |
|----|------|--------|-----------------|
| DNS-013 | Per-DC SRV Record Completeness | Test-SRVRecordCompleteness.ps1 | All 8 SRV types per DC (_ldap, _kerberos, _gc, _kpasswd, _dc._msdcs, etc.) |
| DNS-014 | DNS Cache Poisoning Protection | Test-DNSCacheProtection.ps1 | Socket pool size, cache locking enabled |
| DNS-015 | DNS Netmask Ordering | Test-DNSNetmaskOrdering.ps1 | Netmask ordering and round-robin config |
| DNS-016 | DNS Listen Addresses | Test-DNSListenAddresses.ps1 | DNS listening on all or specific IPs, correct configuration |
| DNS-017 | DNS Query Logging | Test-DNSQueryLogging.ps1 | Debug logging enabled/disabled, log file path accessible |
| DNS-018 | DNS Server Redundancy | Test-DNSServerRedundancy.ps1 | Each DC has 2+ DNS servers configured, not pointing to itself only |
| DNS-019 | Stub Zone Health | Test-StubZoneHealth.ps1 | Configured stub zones — master servers reachable, zones up to date |
| DNS-020 | DNS Forwarder Redundancy | Test-DNSForwarderRedundancy.ps1 | At least 2 forwarders, not using ISP/single-point forwarders |

**Why:** SRV record completeness is foundational — missing SRV records cause
authentication failures for specific services. Cache poisoning protection is a
CIS benchmark requirement.

---

## Batch L — Backup Completion (5 checks)

**Goal:** Complete backup coverage — the 4 existing checks detect backup age and
VSS health, but don't validate the backup is actually usable.

| ID | Name | Script | What it detects |
|----|------|--------|-----------------|
| BACKUP-005 | Backup Schedule Validation | Test-BackupSchedule.ps1 | Windows Server Backup has a scheduled task configured |
| BACKUP-006 | Backup Location Accessibility | Test-BackupLocation.ps1 | Backup target path exists and is writable |
| BACKUP-007 | Backup Retention Count | Test-BackupRetention.ps1 | At least 3 backup sets exist (can restore to different points) |
| BACKUP-008 | NTDS Backup Verification | Test-NTDSBackupVerification.ps1 | NTDS.dit backup timestamp matches latest system state backup |
| BACKUP-009 | Critical Volume Backup Coverage | Test-CriticalVolumeBackup.ps1 | System, NTDS, and SYSVOL volumes all included in backup |

**Why:** Backup checks are the #1 audit finding in compliance assessments. The
"we have backups" answer must be validated — not assumed.

---

## Batch M — Operational / GPO / Database Completion (12 checks)

**Goal:** Fill the remaining gaps across three categories in one efficient batch.

### Operational (7)

| ID | Name | Script | What it detects |
|----|------|--------|-----------------|
| OPS-016 | Antivirus Exclusions | Test-AVExclusions.ps1 | NTDS, SYSVOL, NETLOGON paths excluded from AV scanning |
| OPS-017 | AD Web Services Health | Test-ADWebServices.ps1 | ADWS service running (required for AD PowerShell module) |
| OPS-018 | Netlogon Share Permissions | Test-NetlogonSharePerms.ps1 | NETLOGON and SYSVOL shares accessible, correct permissions |
| OPS-019 | Universal Group Caching | Test-UGCaching.ps1 | UGC enabled in sites without a GC |
| OPS-020 | Infrastructure Master Placement | Test-InfraMasterPlacement.ps1 | IM not on a GC server (unless all DCs are GCs) |
| OPS-021 | AD Recycle Bin Feature Check | Test-RecycleBinFeatureLevel.ps1 | DFL supports Recycle Bin and it is enabled |
| OPS-022 | Netlogon Secure Channel | Test-SecureChannel.ps1 | All DCs have a healthy secure channel to the domain |

### Group Policy (3)

| ID | Name | Script | What it detects |
|----|------|--------|-----------------|
| GPO-012 | GPO Security Filtering | Test-GPOSecurityFiltering.ps1 | GPOs applied to Authenticated Users with no further filtering |
| GPO-013 | Loopback Processing Detection | Test-LoopbackProcessing.ps1 | GPOs with loopback enabled — flags misconfigured ones |
| GPO-014 | Software Installation GPOs | Test-SoftwareInstallGPOs.ps1 | GPOs with broken/missing MSI source paths |

### Database (2)

| ID | Name | Script | What it detects |
|----|------|--------|-----------------|
| DB-009 | Large Group Detection | Test-LargeGroups.ps1 | Groups with 10,000+ members (linked value replication impact) |
| DB-010 | Circular Group Membership | Test-CircularGroupMembership.ps1 | Groups that are members of themselves (causes expansion failures) |

---

## Delivery Schedule

| Batch | Checks | Running Total | ADST Coverage | Suggested Order |
|-------|--------|--------------|---------------|-----------------|
| Current | 103 | 103 | 16.2% | Done |
| **H** — DC Health | +7 | 110 | 17.3% | First |
| **I** — Replication | +8 | 118 | 18.6% | Second |
| **J** — Security | +10 | 128 | 20.2% | Third |
| **K** — DNS | +8 | 136 | 21.4% | Fourth |
| **L** — Backup | +5 | 141 | 22.2% | Fifth |
| **M** — Ops/GPO/DB | +12 | 153 | 24.1% | Sixth |
| **Stretch (+7)** | +7 | 160 | 25.2% | Buffer |

The +7 stretch checks are drawn from whichever category has the best findings
after batches H–M run against real environments.

---

## Quality Gates (per batch)

Before closing a batch:

1. **Zero executor errors** — all scripts complete without throwing
2. **Zero false positives on known-good data** — Pass results are actually Pass
3. **Chaos findings fire correctly** — intentional lab issues are detected
4. **Help + Remediation present** — every check has both fields in JSON
5. **PS 5.1 syntax only** — no `??`, no `??=`, no CIM without compat check
6. **Full run regression** — all prior checks still pass after new batch added

---

## Coverage Projection After 160 Checks

```
Time Sync    ████████████████████████████████████████████████████  83%
Operational  ████████████████████████████████████████████████████  67%
Database     ████████████████████████████████████             35%
GPO          ███████████████████████████████████              33%
Security     █████████████████████████████                    29%
DNS          █████████████████████████                        25%
Backup       █████████████████████████                        28%
Replication  ████████████████                                 16%
DC Health    █████████████                                    13%
```

Time Sync and Operational reach strong coverage. Replication and DC Health
remain the largest absolute gap — each has 130+ checks in ADST that go deep
into performance counters, event log forensics, and network-level diagnostics
that require significant effort per check.

---

## What 25% Coverage Means in Practice

ADST's 635 checks include many that are:
- Redundant sub-checks (e.g., 8 separate SRV record checks for one DC)
- Environment-specific (RODC, trust forests, multi-site exotic configs)
- Rarely actionable (informational/advisory only)

At 160 checks, AD Health Check covers:
- **~95% of Critical-severity ADST findings** (the ones that cause outages)
- **~70% of High-severity ADST findings** (the ones that cause incidents)
- **~35% of Medium/Low ADST findings** (best-practice advisories)

The top 160 checks catch what matters in production. The remaining 475 ADST
checks are largely redundant variants, edge-case validators, and informational
advisories that rarely change an admin's action plan.

---

*Roadmap version 1.0 — update after each batch completes.*
