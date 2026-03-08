<#
.SYNOPSIS
    AD Health Check - Core Engine

.DESCRIPTION
    Main orchestrator. Runs Discovery, Execution, Evaluation, Scoring, and Reporting.

.NOTES
    Version: 1.1.0-beta1
    Compatibility: PowerShell 5.1+

    Beta 1.1 Changes:
        - ConvertFrom-Json PSCustomObject-to-Hashtable conversion hardened
        - ReportPath properly attached to result object via Add-Member
        - Phase error messages improved with exact failure context
        - Database warnings suppressed to Verbose level
#>

# =============================================================================
# HELPER: Safe PSCustomObject -> Hashtable Conversion (PS 5.1 fix)
# =============================================================================

function ConvertTo-HashtableDeep {
    <#
    .SYNOPSIS
        Recursively converts PSCustomObject (returned by ConvertFrom-Json in PS 5.1)
        into a proper [hashtable]. Safe to call on already-hashtable objects.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) { return @{} }

    # Already a Hashtable - pass through
    if ($InputObject -is [System.Collections.Hashtable]) {
        return $InputObject
    }

    # PSCustomObject from ConvertFrom-Json - recurse into properties
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $val = $prop.Value
            if ($null -ne $val -and (
                $val -is [System.Management.Automation.PSCustomObject] -or
                $val -is [System.Collections.Hashtable]
            )) {
                $ht[$prop.Name] = ConvertTo-HashtableDeep -InputObject $val
            }
            else {
                $ht[$prop.Name] = $val
            }
        }
        return $ht
    }

    # Array - recurse into each element
    if ($InputObject -is [System.Array] -or $InputObject -is [System.Collections.ArrayList]) {
        $arr = @()
        foreach ($item in $InputObject) {
            if ($null -ne $item -and (
                $item -is [System.Management.Automation.PSCustomObject] -or
                $item -is [System.Collections.Hashtable]
            )) {
                $arr += ConvertTo-HashtableDeep -InputObject $item
            }
            else {
                $arr += $item
            }
        }
        return $arr
    }

    # Primitive value
    return $InputObject
}

# =============================================================================
# HELPER: Load JSON config file safely, always returning a Hashtable
# =============================================================================

function Get-JsonConfig {
    param(
        [string]$Path,
        [hashtable]$DefaultValue = @{}
    )

    if (-not (Test-Path $Path)) {
        Write-Verbose "[Engine] Config not found: $Path - using defaults"
        return $DefaultValue
    }

    try {
        $raw    = Get-Content -Path $Path -Raw -Encoding UTF8
        $parsed = $raw | ConvertFrom-Json
        return ConvertTo-HashtableDeep -InputObject $parsed
    }
    catch {
        Write-Warning "[Engine] Failed to parse config '$Path': $($_.Exception.Message)"
        return $DefaultValue
    }
}

# =============================================================================
# MAIN ENGINE
# =============================================================================

function Invoke-HealthCheckEngine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]  [string]$OutputPath,
        [Parameter(Mandatory = $false)] [array]$Categories = @(),
        [Parameter(Mandatory = $false)] [int]$MaxParallelJobs = 10,
        [Parameter(Mandatory = $false)] [string]$LogLevel = 'Information'
    )

    # -----------------------------------------------------------------------
    # SETUP
    # -----------------------------------------------------------------------

    $engineStart     = Get-Date
    $runId           = [System.Guid]::NewGuid().ToString().Substring(0, 8).ToUpper()
    $scriptRoot      = Split-Path -Parent $PSScriptRoot   # ADHealthCheck root
    $coreRoot        = $PSScriptRoot                       # Core/ directory
    $definitionsPath = Join-Path $scriptRoot 'Definitions'
    $configPath      = Join-Path $scriptRoot 'Config'
    $checksPath      = Join-Path $scriptRoot 'Checks'

    # Ensure output dirs exist
    foreach ($dir in @($OutputPath, (Join-Path $OutputPath 'logs'))) {
        if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    }

    Write-Host ""
    Write-Host "  [Engine] Run ID : $runId" -ForegroundColor DarkCyan
    Write-Host "  [Engine] Output : $OutputPath" -ForegroundColor DarkCyan
    Write-Host ""

    # -----------------------------------------------------------------------
    # PHASE 1: LOAD MODULES
    # -----------------------------------------------------------------------

    Write-Host "[Phase 1/7] Loading core modules..." -ForegroundColor Yellow

    $modules = @('Logger','Compatibility','Discovery','Executor','Evaluator','Scorer','HtmlReporter','DatabaseOperations')

    foreach ($mod in $modules) {
        $modPath = Join-Path $coreRoot "$mod.ps1"
        if (-not (Test-Path $modPath)) {
            # DatabaseOperations is optional (stub)
            if ($mod -eq 'DatabaseOperations') {
                Write-Host "  SKIP $mod (not found - trending disabled)" -ForegroundColor DarkGray
                continue
            }
            throw "Critical module missing: $modPath"
        }
        try {
            . $modPath
            Write-Host "  OK   $mod" -ForegroundColor Green
        }
        catch {
            throw "Failed to load module '$mod': $($_.Exception.Message)"
        }
    }

    # Init logger
    $logFile = Join-Path $OutputPath "logs\ADHealthCheck-$runId.log"
    Initialize-Logger -LogFilePath $logFile -LogLevel $LogLevel
    Write-Log -Level Information -Message "=== AD Health Check v1.1.0-beta1 | RunID=$runId ==="
    Write-Host ""

    # -----------------------------------------------------------------------
    # PHASE 2: DISCOVERY
    # -----------------------------------------------------------------------

    Write-Host "[Phase 2/7] Discovering AD topology..." -ForegroundColor Yellow
    Write-Log -Level Information -Message "Phase 2: AD Discovery"

    try {
        $inventory = Invoke-ADDiscovery
        Write-Log -Level Information -Message "Discovery OK. Forest=$($inventory.ForestInfo.Name) DCs=$(@($inventory.DomainControllers).Count) Sites=$(@($inventory.Sites).Count)"
        Write-Host "  Forest  : $($inventory.ForestInfo.Name)" -ForegroundColor White
        Write-Host "  DCs     : $(@($inventory.DomainControllers).Count)" -ForegroundColor White
        Write-Host "  Sites   : $(@($inventory.Sites).Count)" -ForegroundColor White
        Write-Host "  Subnets : $(@($inventory.Subnets).Count)" -ForegroundColor White
        Write-Host ""
    }
    catch {
        Write-Log -Level Error -Message "Discovery failed: $($_.Exception.Message)"
        throw "Phase 2 (Discovery) failed: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # PHASE 3: LOAD DEFINITIONS
    # -----------------------------------------------------------------------

    Write-Host "[Phase 3/7] Loading check definitions..." -ForegroundColor Yellow
    Write-Log -Level Information -Message "Phase 3: Load Definitions from $definitionsPath"

    $checkDefinitions = @()
    $defFiles = @(Get-ChildItem -Path $definitionsPath -Filter '*.json' -ErrorAction SilentlyContinue)

    if ($defFiles.Count -eq 0) {
        throw "No definition files found in: $definitionsPath"
    }

    foreach ($f in $defFiles) {
        $cat = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)

        if (@($Categories).Count -gt 0 -and $Categories -notcontains $cat) {
            Write-Log -Level Verbose -Message "Skipping category: $cat"
            continue
        }

        try {
		$raw    = Get-Content -Path $f.FullName -Raw -Encoding UTF8
		$parsed = $raw | ConvertFrom-Json

	# Handle both flat array and wrapped { "Checks": [...] } structure
		$checksProperty = $null
		try { $checksProperty = $parsed.Checks } catch { }

		if ($null -ne $checksProperty) {
			$defs = @($checksProperty)
		} else {
		$defs = @($parsed)
		}

$checkDefinitions += $defs

            Write-Host "  $($f.Name) - $($defs.Count) checks" -ForegroundColor Gray
            Write-Log -Level Verbose -Message "Loaded $($defs.Count) checks from $($f.Name)"
        }
        catch {
            Write-Warning "  SKIP $($f.Name): $($_.Exception.Message)"
            Write-Log -Level Warning -Message "Failed to parse $($f.Name): $($_.Exception.Message)"
        }
    }

    $totalChecks = @($checkDefinitions).Count
    Write-Host "  Total: $totalChecks checks" -ForegroundColor White
    Write-Log -Level Information -Message "Definitions loaded: $totalChecks checks"
    Write-Host ""

    if ($totalChecks -eq 0) { throw "No checks loaded from: $definitionsPath" }

    # -----------------------------------------------------------------------
    # PHASE 4: EXECUTION
    # -----------------------------------------------------------------------

    Write-Host "[Phase 4/7] Executing $totalChecks checks (max $MaxParallelJobs parallel)..." -ForegroundColor Yellow
    Write-Log -Level Information -Message "Phase 4: Execution (MaxParallelJobs=$MaxParallelJobs)"

    try {
        $executionResults = Invoke-CheckExecution `
            -CheckDefinitions $checkDefinitions `
            -Inventory $inventory `
            -ChecksPath $checksPath `
            -MaxParallelJobs $MaxParallelJobs

        $successCount = @($executionResults | Where-Object { $_.Status -eq 'Completed' }).Count
        $errorCount   = @($executionResults | Where-Object { $_.Status -eq 'Error' }).Count
        $timeoutCount = @($executionResults | Where-Object { $_.TimedOut -eq $true }).Count

        Write-Host "  Completed : $successCount" -ForegroundColor Green
        if ($errorCount   -gt 0) { Write-Host "  Errors    : $errorCount"   -ForegroundColor Red    }
        if ($timeoutCount -gt 0) { Write-Host "  Timeouts  : $timeoutCount" -ForegroundColor Yellow }
        Write-Log -Level Information -Message "Execution OK. Completed=$successCount Errors=$errorCount Timeouts=$timeoutCount"
        Write-Host ""
    }
    catch {
        Write-Log -Level Error -Message "Execution failed: $($_.Exception.Message)"
        throw "Phase 4 (Execution) failed: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # PHASE 5: EVALUATION
    # -----------------------------------------------------------------------

    Write-Host "[Phase 5/7] Evaluating results against rules..." -ForegroundColor Yellow
    Write-Log -Level Information -Message "Phase 5: Evaluation"

    try {
        $evaluatedResults = Invoke-ResultEvaluation -ExecutionResults $executionResults

        $passCount = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Pass'    }).Count
        $warnCount = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Warning' }).Count
        $failCount = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Fail'    }).Count

        Write-Host "  Pass    : $passCount" -ForegroundColor Green
        Write-Host "  Warning : $warnCount" -ForegroundColor Yellow
        Write-Host "  Fail    : $failCount" -ForegroundColor Red
        Write-Log -Level Information -Message "Evaluation OK. Pass=$passCount Warning=$warnCount Fail=$failCount"
        Write-Host ""
    }
    catch {
        Write-Log -Level Error -Message "Evaluation failed: $($_.Exception.Message)"
        throw "Phase 5 (Evaluation) failed: $($_.Exception.Message)"
    }

    # -----------------------------------------------------------------------
    # PHASE 6: SCORING
    # -----------------------------------------------------------------------

    Write-Host "[Phase 6/7] Calculating health score..." -ForegroundColor Yellow
    Write-Log -Level Information -Message "Phase 6: Scoring"

    # Load settings - always returns Hashtable (ConvertTo-HashtableDeep handles PS 5.1 PSCustomObject)
    $settings = Get-JsonConfig -Path (Join-Path $configPath 'settings.json') -DefaultValue @{
        Scoring = @{
            SeverityWeights = @{ critical=10; high=5; medium=2; low=1; informational=0 }
            BaseScore  = 100
            MaxPenalty = 100
        }
    }

    # Extract severity weights - guaranteed to be a Hashtable
    $scoringSection = $settings['Scoring']
    if ($null -eq $scoringSection) { $scoringSection = @{} }

    $severityWeights = $scoringSection['SeverityWeights']
    if ($null -eq $severityWeights -or $severityWeights -isnot [System.Collections.Hashtable]) {
        Write-Log -Level Warning -Message "SeverityWeights missing or invalid - using defaults"
        $severityWeights = @{ critical=10; high=5; medium=2; low=1; informational=0 }
    }

    try {
        $scoreResult = Invoke-HealthScoring `
            -EvaluatedResults $evaluatedResults `
            -SeverityWeights $severityWeights

        $scoreColor = if ($scoreResult.OverallScore -ge 85) { 'Green' }
                      elseif ($scoreResult.OverallScore -ge 70) { 'Yellow' }
                      else { 'Red' }

        Write-Host "  Score : $($scoreResult.OverallScore)/100 (Grade $($scoreResult.Grade))" -ForegroundColor $scoreColor
        Write-Log -Level Information -Message "Scoring OK. Score=$($scoreResult.OverallScore) Grade=$($scoreResult.Grade)"
        Write-Host ""
    }
    catch {
        Write-Log -Level Error -Message "Scoring failed: $($_.Exception.Message)"
        throw "Phase 6 (Scoring) failed: $($_.Exception.Message)"
    }
    # -----------------------------------------------------------------------
    # BUILD RESULT OBJECT
    # -----------------------------------------------------------------------

    $runSummary = [PSCustomObject]@{
        RunId           = $runId
        ForestName      = $inventory.ForestInfo.Name
        GeneratedAt     = $engineStart
        DurationSeconds = ((Get-Date) - $engineStart).TotalSeconds

        OverallScore    = $scoreResult.OverallScore
        Grade           = $scoreResult.Grade

        TotalChecks     = @($evaluatedResults).Count
        PassedChecks    = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Pass'    }).Count
        WarningChecks   = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Warning' }).Count
        FailedChecks    = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Fail'    }).Count

        CriticalIssues  = $scoreResult.CriticalCount
        HighIssues      = $scoreResult.HighCount
        MediumIssues    = $scoreResult.MediumCount
        LowIssues       = $scoreResult.LowCount

        LogPath         = $logFile
    }
    # -----------------------------------------------------------------------
    # PHASE 7: REPORT
    # -----------------------------------------------------------------------

    Write-Host "[Phase 7/7] Generating HTML report..." -ForegroundColor Yellow
    Write-Log -Level Information -Message "Phase 7: HTML Report"

    $reportFileName = "ADHealthCheck-$($inventory.ForestInfo.Name)-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$runId.html"
    $reportPath     = Join-Path $OutputPath $reportFileName

    try {
        Export-EnhancedHtmlReport `
			-Summary $runSummary `
			-Scores  $scoreResult `
			-Results $evaluatedResults `
			-Path    $reportPath

        Write-Host "  Report : $reportPath" -ForegroundColor Cyan
        Write-Log -Level Information -Message "Report saved: $reportPath"

        if ([System.Environment]::UserInteractive) {
            Start-Process $reportPath -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log -Level Error -Message "Report generation failed: $($_.Exception.Message)"
        Write-Warning "  Report generation failed: $($_.Exception.Message)"
        $reportPath = "GENERATION_FAILED"
    }

    Write-Host ""

    # -----------------------------------------------------------------------
    # OPTIONAL: DATABASE SAVE
    # -----------------------------------------------------------------------

    # Suppress noisy "Connection is null" warnings - log at Verbose only
    if (Get-Command -Name 'Save-RunToDatabase' -ErrorAction SilentlyContinue) {
        try {
            Save-RunToDatabase -ScoreResult $scoreResult -EvaluatedResults $evaluatedResults -RunId $runId
        }
        catch {
            # Database is optional (stub) - only log at Verbose, no console noise
            Write-Log -Level Verbose -Message "Database save skipped: $($_.Exception.Message)"
        }
    }

    # ReportPath added via Add-Member to avoid timing issues with variable scope
    $runSummary | Add-Member -NotePropertyName 'ReportPath' -NotePropertyValue $reportPath -Force

    Write-Log -Level Information -Message "=== Engine finished. Score=$($runSummary.OverallScore) Duration=$([math]::Round($runSummary.DurationSeconds,1))s ==="

    return $runSummary
}
