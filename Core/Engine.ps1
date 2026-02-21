<#
.SYNOPSIS
    Main orchestration engine for AD Health Check

.DESCRIPTION
    Coordinates the entire health check process:
    1. Initialize system (logging, configuration, database)
    2. Discover AD topology
    3. Load check definitions
    4. Execute checks in parallel
    5. Evaluate results against rules
    6. Calculate health scores
    7. Save to database
    8. Generate reports
    
    This is the "brain" that ties all other modules together.

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Main entry point for health check execution
#>

# =============================================================================
# IMPORT ALL CORE MODULES
# =============================================================================

$moduleFiles = @(
    'Logger.ps1',
    'Discovery.ps1',
    'Executor.ps1',
    'Evaluator.ps1',
    'Scorer.ps1',
    'DatabaseOperations.ps1'
)

foreach ($moduleFile in $moduleFiles) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (Test-Path $modulePath) {
        . $modulePath
    }
    else {
        Write-Error "Required module not found: $modulePath"
        exit 1
    }
}

# =============================================================================
# FUNCTION: Invoke-HealthCheckEngine
# Purpose: Main orchestration function - runs entire health check
# =============================================================================
function Invoke-HealthCheckEngine {
    <#
    .SYNOPSIS
        Executes complete AD health check
    
    .PARAMETER OutputPath
        Path where results and reports will be saved
    
    .PARAMETER ConfigPath
        Path to settings.json configuration file
    
    .PARAMETER ThresholdsPath
        Path to thresholds.json configuration file
    
    .PARAMETER Categories
        Array of category IDs to run (empty = all categories)
    
    .PARAMETER MaxParallelJobs
        Maximum parallel check executions (default: 10)
    
    .PARAMETER LogLevel
        Logging level (Verbose, Information, Warning, Error)
    
    .EXAMPLE
        Invoke-HealthCheckEngine -OutputPath "C:\Reports"
    
    .EXAMPLE
        Invoke-HealthCheckEngine -Categories @('Replication', 'DCHealth') -LogLevel Verbose
    
    .OUTPUTS
        PSCustomObject with run summary and scores
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$OutputPath = "$PSScriptRoot\..\Output",
        
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath = "$PSScriptRoot\..\Config\settings.json",
        
        [Parameter(Mandatory = $false)]
        [string]$ThresholdsPath = "$PSScriptRoot\..\Config\thresholds.json",
        
        [Parameter(Mandatory = $false)]
        [array]$Categories = @(),
        
        [Parameter(Mandatory = $false)]
        [int]$MaxParallelJobs = 10,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
        [string]$LogLevel = 'Information'
    )
    
    $engineStart = Get-Date
    
    try {
        # =====================================================================
        # PHASE 1: INITIALIZATION
        # =====================================================================
        
        Write-Host "`n========================================" -ForegroundColor Cyan
        Write-Host " AD HEALTH CHECK - EXECUTION START" -ForegroundColor Cyan
        Write-Host "========================================`n" -ForegroundColor Cyan
        
        # Initialize logger
        $logPath = Join-Path $OutputPath "logs\healthcheck_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        Initialize-Logger -LogLevel $LogLevel -LogFilePath $logPath
        
        Write-LogInfo "===== PHASE 1: INITIALIZATION =====" -Category "Engine"
        
        # Load configuration
        Write-LogInfo "Loading configuration..." -Category "Engine"
        $config = Get-Configuration -ConfigPath $ConfigPath
        $thresholds = Get-Thresholds -ThresholdsPath $ThresholdsPath
        
        # Initialize database connection
        Write-LogInfo "Initializing database connection..." -Category "Engine"
        $databasePath = Join-Path $OutputPath "healthcheck.db"
        $dbConnection = Initialize-DatabaseConnection -DatabasePath $databasePath
        
        # Create run record
        $runId = [Guid]::NewGuid().ToString()
        Write-LogInfo "Run ID: $runId" -Category "Engine"
        
        # =====================================================================
        # PHASE 2: DISCOVERY
        # =====================================================================
        
        Write-LogInfo "`n===== PHASE 2: AD TOPOLOGY DISCOVERY =====" -Category "Engine"
        
        $inventory = Invoke-ADDiscovery `
            -IncludePerformanceCounters $config.discovery.includeDCPerformanceCounters `
            -ConnectionTimeout $config.discovery.connectionTimeoutSeconds
        
        # Save inventory to database
        Save-InventoryToDatabase -RunId $runId -Inventory $inventory -Connection $dbConnection
        
        # =====================================================================
        # PHASE 3: LOAD CHECK DEFINITIONS
        # =====================================================================
        
        Write-LogInfo "`n===== PHASE 3: LOADING CHECK DEFINITIONS =====" -Category "Engine"
        
        $checkDefinitions = Get-CheckDefinitions `
            -DefinitionsPath "$PSScriptRoot\..\Definitions" `
            -Categories $Categories `
            -EnabledOnly $true
        
        Write-LogInfo "Loaded $($checkDefinitions.Count) check definitions" -Category "Engine"
        
        # Save check definitions to database
        Save-CheckDefinitionsToDatabase -Definitions $checkDefinitions -Connection $dbConnection
        
        # =====================================================================
        # PHASE 4: EXECUTE CHECKS
        # =====================================================================
        
        Write-LogInfo "`n===== PHASE 4: CHECK EXECUTION =====" -Category "Engine"
        
        $checkResults = Invoke-ParallelCheckExecution `
            -CheckDefinitions $checkDefinitions `
            -Inventory $inventory `
            -MaxParallelJobs $MaxParallelJobs `
            -ExecutionTimeout $config.execution.executionTimeoutSeconds
        
        # Save check results to database
        Save-CheckResultsToDatabase -RunId $runId -Results $checkResults -Connection $dbConnection
        
        # =====================================================================
        # PHASE 5: EVALUATE RESULTS
        # =====================================================================
        
        Write-LogInfo "`n===== PHASE 5: RESULT EVALUATION =====" -Category "Engine"
        
        $evaluatedResults = Invoke-ResultEvaluation `
            -CheckResults $checkResults `
            -CheckDefinitions $checkDefinitions `
            -Thresholds $thresholds
        
        # Save issues to database
        Save-IssuesToDatabase -RunId $runId -Results $evaluatedResults -Connection $dbConnection
        
        # =====================================================================
        # PHASE 6: CALCULATE SCORES
        # =====================================================================
        
        Write-LogInfo "`n===== PHASE 6: HEALTH SCORING =====" -Category "Engine"
        
        $scores = Invoke-HealthScoring `
            -EvaluatedResults $evaluatedResults `
            -SeverityWeights $config.scoring.severityWeights `
            -CategoryWeights $config.scoring.categoryWeights
        
        # Save scores to database
        Save-ScoresToDatabase -RunId $runId -Scores $scores -Connection $dbConnection
        
        # =====================================================================
        # PHASE 7: UPDATE RUN RECORD
        # =====================================================================
        
        Write-LogInfo "`n===== PHASE 7: FINALIZING RUN =====" -Category "Engine"
        
        $runSummary = [PSCustomObject]@{
            RunId = $runId
            StartTime = $engineStart
            EndTime = Get-Date
            ForestName = $inventory.ForestInfo.Name
            DomainName = $inventory.ForestInfo.RootDomain
            ExecutedBy = $env:USERNAME
            ExecutionHost = $env:COMPUTERNAME
            Status = 'Completed'
            OverallScore = $scores.OverallScore
            TotalChecks = $checkResults.Count
            PassedChecks = ($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Pass' }).Count
            WarningChecks = ($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Warning' }).Count
            FailedChecks = ($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Fail' }).Count
            CriticalIssues = ($evaluatedResults | ForEach-Object { $_.Issues } | Where-Object { $_.Severity -eq 'Critical' }).Count
            HighIssues = ($evaluatedResults | ForEach-Object { $_.Issues } | Where-Object { $_.Severity -eq 'High' }).Count
            MediumIssues = ($evaluatedResults | ForEach-Object { $_.Issues } | Where-Object { $_.Severity -eq 'Medium' }).Count
            LowIssues = ($evaluatedResults | ForEach-Object { $_.Issues } | Where-Object { $_.Severity -eq 'Low' }).Count
        }
        
        # Update run record in database
        Update-RunRecord -Summary $runSummary -Connection $dbConnection
        
        # =====================================================================
        # PHASE 8: GENERATE REPORTS
        # =====================================================================
        
        Write-LogInfo "`n===== PHASE 8: REPORT GENERATION =====" -Category "Engine"
        
        $reportPath = Join-Path $OutputPath "HealthCheck_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
        New-Item -ItemType Directory -Path $reportPath -Force | Out-Null
        
        if ($config.reporting.generateJSON) {
            Write-LogInfo "Generating JSON report..." -Category "Engine"
            $jsonPath = Join-Path $reportPath "report.json"
            Export-JsonReport -Summary $runSummary -Scores $scores -Results $evaluatedResults -Path $jsonPath
        }
        
        if ($config.reporting.generateHTML) {
            Write-LogInfo "Generating HTML report..." -Category "Engine"
            $htmlPath = Join-Path $reportPath "report.html"
            Export-HtmlReport -Summary $runSummary -Scores $scores -Results $evaluatedResults -Path $htmlPath
        }
        
        # =====================================================================
        # COMPLETION
        # =====================================================================
        
        $totalDuration = ((Get-Date) - $engineStart).TotalSeconds
        
        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host " HEALTH CHECK COMPLETED SUCCESSFULLY" -ForegroundColor Green
        Write-Host "========================================`n" -ForegroundColor Green
        
        Write-LogInfo "Execution Summary:" -Category "Engine"
        Write-LogInfo "  Run ID: $runId" -Category "Engine"
        Write-LogInfo "  Forest: $($inventory.ForestInfo.Name)" -Category "Engine"
        Write-LogInfo "  Overall Score: $($scores.OverallScore)/100 ($(Get-ScoreRating -Score $scores.OverallScore))" -Category "Engine"
        Write-LogInfo "  Checks Executed: $($runSummary.TotalChecks)" -Category "Engine"
        Write-LogInfo "    Passed: $($runSummary.PassedChecks)" -Category "Engine"
        Write-LogInfo "    Warning: $($runSummary.WarningChecks)" -Category "Engine"
        Write-LogInfo "    Failed: $($runSummary.FailedChecks)" -Category "Engine"
        Write-LogInfo "  Issues Detected:" -Category "Engine"
        Write-LogInfo "    Critical: $($runSummary.CriticalIssues)" -Category "Engine"
        Write-LogInfo "    High: $($runSummary.HighIssues)" -Category "Engine"
        Write-LogInfo "    Medium: $($runSummary.MediumIssues)" -Category "Engine"
        Write-LogInfo "    Low: $($runSummary.LowIssues)" -Category "Engine"
        Write-LogInfo "  Total Duration: $([math]::Round($totalDuration, 2))s" -Category "Engine"
        Write-LogInfo "  Reports: $reportPath" -Category "Engine"
        
        # Close database connection
        Close-DatabaseConnection -Connection $dbConnection
        
        # Close logger
        Close-Logger
        
        return $runSummary
    }
    catch {
        Write-LogError "Health check engine failed: $($_.Exception.Message)" -Category "Engine" -Exception $_.Exception
        
        # Attempt to update run status to failed
        if ($dbConnection) {
            try {
                $failedSummary = [PSCustomObject]@{
                    RunId = $runId
                    Status = 'Failed'
                    EndTime = Get-Date
                }
                Update-RunRecord -Summary $failedSummary -Connection $dbConnection
            }
            catch {
                Write-LogWarning "Could not update run status: $($_.Exception.Message)" -Category "Engine"
            }
        }
        
        throw
    }
}

# =============================================================================
# HELPER FUNCTIONS (Stubs - to be implemented with database module)
# =============================================================================

function Get-Configuration {
    param([string]$ConfigPath)
    
    if (Test-Path $ConfigPath) {
        return Get-Content $ConfigPath -Raw | ConvertFrom-Json
    }
    
    # Return defaults
    return [PSCustomObject]@{
        execution = @{ executionTimeoutSeconds = 300 }
        discovery = @{ includeDCPerformanceCounters = $false; connectionTimeoutSeconds = 30 }
        scoring = @{ 
            severityWeights = @{ Critical = 10; High = 5; Medium = 2; Low = 1 }
            categoryWeights = @{ Replication = 25; DCHealth = 20; DNS = 15 }
        }
        reporting = @{ generateJSON = $true; generateHTML = $true }
    }
}

function Get-Thresholds {
    param([string]$ThresholdsPath)
    
    if (Test-Path $ThresholdsPath) {
        return Get-Content $ThresholdsPath -Raw | ConvertFrom-Json
    }
    
    return @{}
}

function Get-CheckDefinitions {
    param([string]$DefinitionsPath, [array]$Categories, [bool]$EnabledOnly)
    
    Write-LogInfo "Loading check definitions from: $DefinitionsPath" -Category "Engine"
    
    $allChecks = @()
    
    try {
        # Get all JSON definition files
        $definitionFiles = Get-ChildItem -Path $DefinitionsPath -Filter "*.json" -File -ErrorAction Stop
        
        foreach ($file in $definitionFiles) {
            try {
                Write-LogVerbose "Loading definitions from: $($file.Name)" -Category "Engine"
                
                $content = Get-Content -Path $file.FullName -Raw | ConvertFrom-Json
                
                # Extract checks from file
                foreach ($check in $content.Checks) {
                    # Filter by category if specified
                    if ($Categories.Count -gt 0 -and $check.CategoryId -notin $Categories) {
                        continue
                    }
                    
                    # Filter by enabled status
                    if ($EnabledOnly -and -not $check.IsEnabled) {
                        continue
                    }
                    
                    # Make script path absolute
                    if ($check.ScriptPath -like "..*") {
                        $check.ScriptPath = Join-Path $DefinitionsPath $check.ScriptPath
                        $check.ScriptPath = [System.IO.Path]::GetFullPath($check.ScriptPath)
                    }
                    
                    $allChecks += $check
                }
                
                Write-LogVerbose "Loaded $($content.Checks.Count) check(s) from $($file.Name)" -Category "Engine"
            }
            catch {
                Write-LogWarning "Failed to load definitions from $($file.Name): $($_.Exception.Message)" -Category "Engine"
            }
        }
        
        Write-LogInfo "Loaded $($allChecks.Count) check definition(s)" -Category "Engine"
        
        return $allChecks
    }
    catch {
        Write-LogError "Failed to load check definitions: $($_.Exception.Message)" -Category "Engine"
        return @()
    }
}

function Initialize-DatabaseConnection {
    param([string]$DatabasePath)
    Write-LogInfo "Database connection initialized (stub)" -Category "Engine"
    return $null
}

function Close-DatabaseConnection {
    param($Connection)
    Write-LogVerbose "Database connection closed" -Category "Engine"
}

function Save-InventoryToDatabase {
    param($RunId, $Inventory, $Connection)
    Write-LogVerbose "Saving inventory to database..." -Category "Engine"
    
    try {
        # Save forest info
        Save-InventoryItem -Connection $Connection -RunId $RunId `
            -ItemType "Forest" -ItemName $Inventory.ForestInfo.Name `
            -Properties $Inventory.ForestInfo
        
        # Save domains
        foreach ($domain in $Inventory.Domains) {
            Save-InventoryItem -Connection $Connection -RunId $RunId `
                -ItemType "Domain" -ItemName $domain.Name `
                -ParentItem $Inventory.ForestInfo.Name `
                -Properties $domain
        }
        
        # Save DCs
        foreach ($dc in $Inventory.DomainControllers) {
            Save-InventoryItem -Connection $Connection -RunId $RunId `
                -ItemType "DomainController" -ItemName $dc.Name `
                -ParentItem $dc.Domain `
                -Properties $dc
        }
        
        Write-LogInfo "Inventory saved to database" -Category "Engine"
    }
    catch {
        Write-LogWarning "Failed to save inventory to database: $($_.Exception.Message)" -Category "Engine"
    }
}

function Save-CheckDefinitionsToDatabase {
    param($Definitions, $Connection)
    Write-LogVerbose "Check definitions saved to database (stub)" -Category "Engine"
}

function Save-CheckResultsToDatabase {
    param($RunId, $Results, $Connection)
    Write-LogVerbose "Saving check results to database..." -Category "Engine"
    
    try {
        foreach ($result in $Results) {
            Save-CheckResult -Connection $Connection -RunId $RunId -Result $result
        }
        Write-LogInfo "Saved $($Results.Count) check result(s) to database" -Category "Engine"
    }
    catch {
        Write-LogWarning "Failed to save check results: $($_.Exception.Message)" -Category "Engine"
    }
}

function Save-IssuesToDatabase {
    param($RunId, $Results, $Connection)
    Write-LogVerbose "Saving issues to database..." -Category "Engine"
    
    try {
        $issueCount = 0
        foreach ($result in $Results) {
            if ($result.Issues -and $result.Issues.Count -gt 0) {
                foreach ($issue in $result.Issues) {
                    Save-Issue -Connection $Connection -RunId $RunId `
                        -ResultId ([Guid]::NewGuid().ToString()) `
                        -CheckId $result.CheckId -Issue $issue
                    $issueCount++
                }
            }
        }
        Write-LogInfo "Saved $issueCount issue(s) to database" -Category "Engine"
    }
    catch {
        Write-LogWarning "Failed to save issues: $($_.Exception.Message)" -Category "Engine"
    }
}

function Save-ScoresToDatabase {
    param($RunId, $Scores, $Connection)
    Write-LogVerbose "Saving scores to database..." -Category "Engine"
    
    try {
        # Save overall score
        Save-Score -Connection $Connection -RunId $RunId `
            -CategoryId $null -ScoreValue $Scores.OverallScore `
            -ChecksExecuted 0 -ChecksPassed 0
        
        # Save category scores
        foreach ($catScore in $Scores.CategoryScores) {
            Save-Score -Connection $Connection -RunId $RunId `
                -CategoryId $catScore.CategoryId -ScoreValue $catScore.ScoreValue `
                -ChecksExecuted $catScore.ChecksExecuted -ChecksPassed $catScore.ChecksPassed
        }
        
        Write-LogInfo "Saved overall and category scores to database" -Category "Engine"
    }
    catch {
        Write-LogWarning "Failed to save scores: $($_.Exception.Message)" -Category "Engine"
    }
}

function Update-RunRecord {
    param($Summary, $Connection)
    Write-LogVerbose "Run record updated (stub)" -Category "Engine"
}

function Export-JsonReport {
    param($Summary, $Scores, $Results, $Path)
    
    $report = @{
        Summary = $Summary
        Scores = $Scores
        Results = $Results
    } | ConvertTo-Json -Depth 10
    
    $report | Out-File -FilePath $Path -Encoding UTF8
    Write-LogInfo "JSON report exported: $Path" -Category "Engine"
}

function Export-HtmlReport {
    param($Summary, $Scores, $Results, $Path)
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>AD Health Check Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #2c3e50; }
        .score { font-size: 48px; font-weight: bold; color: #27ae60; }
        .summary { background: #ecf0f1; padding: 15px; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>AD Health Check Report</h1>
    <div class="summary">
        <h2>Overall Score: <span class="score">$($Scores.OverallScore)/100</span></h2>
        <p><strong>Forest:</strong> $($Summary.ForestName)</p>
        <p><strong>Date:</strong> $($Summary.StartTime)</p>
        <p><strong>Checks Executed:</strong> $($Summary.TotalChecks)</p>
        <p><strong>Issues Found:</strong> Critical: $($Summary.CriticalIssues), High: $($Summary.HighIssues)</p>
    </div>
</body>
</html>
"@
    
    $html | Out-File -FilePath $Path -Encoding UTF8
    Write-LogInfo "HTML report exported: $Path" -Category "Engine"
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================

Export-ModuleMember -Function @(
    'Invoke-HealthCheckEngine'
)
