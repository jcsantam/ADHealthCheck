# AD Health Check - Changelog

## [2.0.0] - 2026-03-16

### Summary
First stable release. 50 checks across 9 categories. All known false positives resolved.
Score in lab: ~56/100 — remaining failures are confirmed real chaos findings.

### Fixed

#### Evaluator.ps1 — Single-quoted string regex
- `"^'(.*)' $"` had trailing space before `$`; single-quoted string literals in conditions
  (e.g. `'Not Responding'`, `'Stopped'`) never parsed correctly. All quoted conditions silently
  matched nothing.
- Fix: `"^'(.*)'$"` — removed the trailing space.

#### DB-001 (NTDS Database Health) — Array coercion false positive
- `[bool]@($false, $false)` evaluates to `$true` in PowerShell (non-empty array is truthy).
  Scalar conditions (`HasIssue == true`) against per-DC array results always triggered.
- Fix: All DB-001 conditions changed to `Any(...)` form in `Definitions/Database.json`.

#### REP-010 (Connection Objects) — FQDN in DN match
- `$dc.Name` is an FQDN (`DC01.LAB.COM`) but connection object DNs use short hostnames
  (`CN=DC01,...`). Pattern never matched.
- Fix: Use `$dc.HostName` (short name) in DN regex.

#### REP-004 (Replication Latency) — CSV field offset from quoted DN
- `repadmin /showrepl /csv` wraps the naming context DN in quotes (`"DC=LAB,DC=COM"`).
  Naive `-split ','` shifted all field indices by 1; `$fields[5]` landed on the site name
  instead of LastSuccessTime, causing DateTime.Parse failure → 999999 min latency → always fail.
- Fix: Rewrite using `ConvertFrom-Csv -Header` with named columns.

#### REP-007 (Failed Replications) — Same CSV field offset
- Same root cause; `$fields[4]` was reading `DC=COM"` as failure count → always 0 → false Pass.
- Fix: Same `ConvertFrom-Csv` approach, using `$row.Failures`.

#### REP-005 (SYSVOL Replication) — Local-only check
- `Get-Service` and `Get-WmiObject` calls had no `-ComputerName`; only checked the local DC.
- Fix: Iterate `$Inventory.DomainControllers`, pass `-ComputerName $dc.Name` to all calls.
  WMI namespace failures skip the DC (no false error result added).

#### REP-008 (Metadata Consistency) — FQDN vs short name phantom detection
- `$reachableDCs` collected FQDNs; AD server objects in Configuration partition use short names.
  All DCs were flagged as phantom.
- Fix: Use `$dc.HostName` (or `($dc.Name -split '\.')[0]` fallback) for the reachable list.

#### DNS-002 (DNS Zone Health) — TrustAnchors false positive
- `TrustAnchors` is a DNSSEC system zone that legitimately has `DynamicUpdate=None`.
  The check flagged it as a configuration issue.
- Fix: Exclude known system zones (`TrustAnchors`, `0.in-addr.arpa`, `127.in-addr.arpa`,
  `255.in-addr.arpa`) from the dynamic update check.

### Changed
- All version strings updated from beta designations to `2.0.0`
- `Config/settings.json` cleaned of beta calibration comments
- CLAUDE.md updated to reflect `$dc.HostName` availability (added in Discovery.ps1)

---

## [1.1.0-beta1] - 2026-03-02

### Summary
Beta 1.1 focuses on detection accuracy: fixing 10 checks that returned false Pass
results despite known infrastructure issues, recalibrating the health score to reflect
true severity, and improving performance on the slow DC-001 check.

---

### Fixed

#### Priority 1: False Pass Results (10 checks corrected)

**Root Cause:** Property name mismatch between check script output and JSON rule conditions.
The condition engine was working correctly - the property names in the conditions simply
didn't match what the check scripts were outputting.

**Solution applied in two layers:**

1. **Evaluator.ps1 - Property Alias Map**
   - Added `$script:PropertyAliasMap` that normalizes output property names to canonical
     condition names at evaluation time. No check scripts need to be rewritten.
   - Examples: `State` → `ServiceStatus`, `FreeGB` → `FreeSpaceGB`, `TimeDifferenceSec` → `OffsetSeconds`
   - `Add-PropertyAliases` function injects aliases onto each object before condition testing.

2. **Definitions JSON - Multiple Condition Variants**
   - All definition files now include multiple `EvaluationRules` per check, covering all
     known property name variants from check scripts.
   - Rules are evaluated in order; first match wins. If a check script uses `State`,
     `Status`, or `ServiceStatus` - at least one rule will detect it.
   - Fallback: `IsHealthy == false` as final catch-all rule in every check.

**Checks fixed:**

| Check | Issue | Fix |
|-------|-------|-----|
| REP-001 | `Any(Status == 'Failed')` not matching - script used `ReplicationStatus` | Added alias + alternate rule |
| REP-002 | Condition `Any(ErrorCode != 0)` - script used `LastError` | Added `LastError != 0` rule + alias |
| REP-003 | Condition `HasIssue == true` - script used `USNRollbackDetected` | Added both property rules |
| DC-001  | `Any(ServiceStatus == 'Stopped')` - script outputs `Status` and `State` | Added all 3 variants + alias |
| DC-002  | `FreeSpaceGB < 5` - script used `FreeGB` or `FreeSpacePercent` | Added 5 rule variants + aliases |
| DC-003  | `Reachable == false` - script used `IsReachable` or `PingSuccess` | Added all variants + aliases |
| DNS-001 | `Exists == false` - script used `RecordExists` or `SRVExists` | Added all variants + aliases |
| DNS-002 | `Status == 'NotRunning'` - script used `ZoneStatus` | Added `ZoneStatus` rule + alias |
| TIME-002| `OffsetSeconds > 300` - script used `TimeDifferenceSec` | Added both names + alias |
| SEC-002 | `MissingAdminSDHolder == true` - script used `AdminSDHolderMissing` | Added both names + alias |

---

#### Priority 2: Score Calibration

**Problem:** 5 Critical issues scored 96/100. A perfect score for a broken AD.

**Root Cause:** Default severity weights in Scorer.ps1 were `critical=10`. With base
score 100 and 5 criticals = 50 penalty. But the penalty was capped and applied
inconsistently, resulting in only a 4-point deduction.

**Fix in Scorer.ps1 and settings.json:**
```
Before:  critical=10, high=5,  medium=2, low=1
After:   critical=15, high=7,  medium=3, low=1
```

**New score examples:**
```
5 Critical + 3 Medium = (5×15) + (3×3) = 75+9 = 84 penalty → Score: 16/100 (F)
1 Critical + 2 Medium = 15+6 = 21 penalty → Score: 79/100 (C)
0 Critical + 2 Medium = 6 penalty → Score: 94/100 (A)
Clean environment     = 0 penalty → Score: 100/100 (A)
```

**Letter grades added:**

| Score | Grade | Meaning |
|-------|-------|---------|
| 90-100 | A | Healthy |
| 80-89  | B | Minor issues |
| 70-79  | C | Attention needed |
| 60-69  | D | Significant problems |
| <60    | F | Critical failures |

---

#### Priority 3: DC-001 Performance

**Problem:** Critical Services check (DC-001) took ~110 seconds.

**Root Cause:** Sequential service checks - the script iterated each DC, then each
service with individual WMI/Get-Service calls. With 2 DCs × 8 services = 16 serial calls.

**Fix in Test-CriticalServices.ps1:**
- One `Start-Job` per DC (parallel across DCs)
- All services checked within each job sequentially (Get-Service is fast locally)
- Jobs collected with `Wait-Job -Timeout 60`
- Expected time: ~15-25 seconds (was ~110 seconds)

---

#### Priority 4: Database Stub Noise

**Problem:** Console showed "Connection is null" warnings on every run.

**Fix in Engine.ps1:**
- Database save wrapped in `try/catch` with `Write-Log -Level Verbose` (not Warning)
- No console output for database operations
- Setting `DatabaseVerbosity: "Verbose"` in settings.json documents the intent

---

### Changed

#### Engine.ps1
- `ConvertTo-HashtableDeep` function added - recursively converts PSCustomObject to
  Hashtable. Called by `Get-JsonConfig` before passing settings to Scorer.
- `Get-JsonConfig` helper added - loads any JSON file and always returns a Hashtable.
- `$runSummary | Add-Member -NotePropertyName 'ReportPath'` - ReportPath attached after
  report generation to avoid null reference (Beta 1.0 fix confirmed working).
- Database save now Verbose-only (no console warnings).

#### Scorer.ps1
- Removed `[hashtable]` type constraint on `$SeverityWeights` parameter - accepts
  PSCustomObject from ConvertFrom-Json and converts internally.
- Added Grade calculation (A/B/C/D/F).
- Added `CategoryBreakdown` hashtable in result object for per-category scores.
- All `@()` wrappers confirmed on collection `.Count` operations.

#### Evaluator.ps1
- **DO NOT call `ConvertFrom-Json` on `EvaluationRules`** - they are already PSCustomObject
  from the definition loader. Double-parse causes "Invalid JSON primitive" errors.
- Added `$script:PropertyAliasMap` for property name normalization.
- Added `Add-PropertyAliases` function - injects canonical names onto objects.
- `Get-DataAsArray` improved - checks more collection property names.
- `Test-SimpleCondition` - improved null handling in `Compare-Values`.
- Removed double ConvertFrom-Json on EvaluationRules.

#### Definitions/*.json
- All 5 definition files updated with multiple rule variants per check.
- Every check has `IsHealthy == false` as final fallback rule.
- Property name coverage: Status/State/ServiceStatus, FreeGB/FreeSpaceGB,
  OffsetSeconds/TimeDifferenceSec, Exists/RecordExists/SRVExists, etc.

---

### Architecture Notes

**Why property alias map in Evaluator vs fixing check scripts:**
The check scripts are already running correctly and producing valid output. Rewriting
25+ scripts to match JSON condition names risks introducing new bugs. The alias map
is a single-point normalization layer that doesn't touch proven code.

**Why multiple rules per check vs single rule:**
Check scripts were written by different contributors (or at different times) and
naturally use different property names. Multiple rules are defensive programming -
if one property name convention changes, the other rules catch it.

---

## [1.0.0-beta1] - 2026-03-01

### Summary
Initial beta release. 15 checks running across 9 categories. Core engine functional.
96/100 health score (pre-calibration) with 8 real issues detected.

### Issues detected in lab (LAB.COM):
- CRITICAL: No system state backup found (BACKUP-001)
- CRITICAL: NTDS database not cleanly shut down (DB-001)
- CRITICAL: Orphaned GPOs detected (GPO-001)
- CRITICAL: Stale computer accounts (SEC-001)
- CRITICAL: PDC missing external time source (TIME-001)
- MEDIUM: GPO version mismatch (GPO-001)
- MEDIUM: Stale computer accounts 90d (SEC-001)
- MEDIUM: Missing AdminSDHolder protection (SEC-002)

### Key fixes applied in Beta 1.0:
1. Engine.ps1: PSCustomObject→Hashtable conversion
2. Engine.ps1: ReportPath via Add-Member
3. Invoke-ADHealthCheck.ps1: Fixed ReportDirectory→ReportPath property
4. Executor.ps1: Removed nested Start-Job (null RawOutput fix)
5. Scorer.ps1: Removed [hashtable] type constraints
6. Evaluator.ps1: Complete condition engine rewrite with DSL parser
7. Evaluator.ps1: Get-AffectedObject null safety
8. Evaluator.ps1: Removed double ConvertFrom-Json on EvaluationRules
9. Test-PDCTimeSource.ps1: Fixed ${pdcName} variable syntax
10. Test-DCTimeOffset.ps1: Fixed ${pdcName} variable syntax
11. HtmlReporter.ps1: Encoding fix (WriteAllText, no BOM)
