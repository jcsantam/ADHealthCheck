<#
.SYNOPSIS
    Rule-based result evaluation engine

.DESCRIPTION
    Evaluates check execution results against defined rules to determine:
    - Pass/Warning/Fail status
    - Issue severity
    - Affected objects
    - Recommendations
    
    Rules are defined in JSON and evaluated dynamically, avoiding
    hardcoded logic for each check.

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Supports complex rule expressions
#>

# Import logger if available
if (Test-Path "$PSScriptRoot\Logger.ps1") {
    . "$PSScriptRoot\Logger.ps1"
}

# =============================================================================
# FUNCTION: Invoke-ResultEvaluation
# Purpose: Evaluate check results against defined rules
# =============================================================================
function Invoke-ResultEvaluation {
    <#
    .SYNOPSIS
        Evaluates check results against evaluation rules
    
    .PARAMETER CheckResults
        Array of check execution results from Executor
    
    .PARAMETER CheckDefinitions
        Array of check definitions with evaluation rules
    
    .PARAMETER Thresholds
        Threshold configuration object
    
    .EXAMPLE
        $evaluated = Invoke-ResultEvaluation -CheckResults $results -CheckDefinitions $checks -Thresholds $thresholds
    
    .OUTPUTS
        Array of evaluated results with Pass/Warning/Fail status and issues
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$CheckResults,
        
        [Parameter(Mandatory = $true)]
        [array]$CheckDefinitions,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Thresholds
    )
    
    Write-LogInfo "Starting result evaluation" -Category "Evaluator"
    Write-LogInfo "  Results to evaluate: $($CheckResults.Count)" -Category "Evaluator"
    
    $evaluatedResults = @()
    
    foreach ($result in $CheckResults) {
        Write-LogVerbose "Evaluating result for check: $($result.CheckId)" -Category "Evaluator"
        
        # Find corresponding check definition
        $checkDef = $CheckDefinitions | Where-Object { $_.CheckId -eq $result.CheckId } | Select-Object -First 1
        
        if (-not $checkDef) {
            Write-LogWarning "No check definition found for CheckId: $($result.CheckId)" -Category "Evaluator"
            continue
        }
        
        # Create evaluated result object
        $evaluatedResult = [PSCustomObject]@{
            CheckId = $result.CheckId
            CheckName = $checkDef.CheckName
            CategoryId = $checkDef.CategoryId
            Severity = $checkDef.Severity
            StartTime = $result.StartTime
            EndTime = $result.EndTime
            DurationMs = $result.DurationMs
            ExecutionStatus = $result.Status  # Completed/Error
            EvaluationStatus = 'Unknown'      # Pass/Warning/Fail
            RawOutput = $result.RawOutput
            ProcessedOutput = $null
            Issues = @()
            IssueCount = 0
            ErrorMessage = $result.ErrorMessage
        }
        
        # If execution failed, mark as failed evaluation
        if ($result.Status -eq 'Error') {
            $evaluatedResult.EvaluationStatus = 'Fail'
            $evaluatedResult.Issues = @(
                [PSCustomObject]@{
                    IssueId = [guid]::NewGuid().ToString()
                    Severity = $checkDef.Severity
                    Title = "Check Execution Failed"
                    Description = "The check script failed to execute: $($result.ErrorMessage)"
                    AffectedObject = "N/A"
                    Evidence = @{ ErrorMessage = $result.ErrorMessage }
                    Recommendation = "Review check script and execution logs"
                }
            )
            $evaluatedResult.IssueCount = 1
        }
        else {
            # Evaluate based on rules
            try {
                $evaluation = Invoke-RuleEvaluation `
                    -CheckDefinition $checkDef `
                    -RawOutput $result.RawOutput `
                    -Thresholds $Thresholds
                
                $evaluatedResult.EvaluationStatus = $evaluation.Status
                $evaluatedResult.ProcessedOutput = $evaluation.ProcessedOutput
                $evaluatedResult.Issues = $evaluation.Issues
                $evaluatedResult.IssueCount = $evaluation.Issues.Count
                
                Write-LogVerbose "  Status: $($evaluation.Status), Issues: $($evaluation.Issues.Count)" -Category "Evaluator"
            }
            catch {
                Write-LogError "Failed to evaluate check $($result.CheckId): $($_.Exception.Message)" -Category "Evaluator"
                $evaluatedResult.EvaluationStatus = 'Fail'
                $evaluatedResult.ErrorMessage = "Evaluation failed: $($_.Exception.Message)"
            }
        }
        
        $evaluatedResults += $evaluatedResult
    }
    
    # Summary statistics
    $passCount = ($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Pass' }).Count
    $warnCount = ($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Warning' }).Count
    $failCount = ($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Fail' }).Count
    $totalIssues = ($evaluatedResults | Measure-Object -Property IssueCount -Sum).Sum
    
    Write-LogInfo "Result evaluation completed" -Category "Evaluator"
    Write-LogInfo "  Pass: $passCount" -Category "Evaluator"
    Write-LogInfo "  Warning: $warnCount" -Category "Evaluator"
    Write-LogInfo "  Fail: $failCount" -Category "Evaluator"
    Write-LogInfo "  Total issues detected: $totalIssues" -Category "Evaluator"
    
    return $evaluatedResults
}

# =============================================================================
# FUNCTION: Invoke-RuleEvaluation
# Purpose: Evaluate rules for a specific check
# =============================================================================
function Invoke-RuleEvaluation {
    <#
    .SYNOPSIS
        Evaluates rules for a specific check result
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $CheckDefinition,
        
        [Parameter(Mandatory = $true)]
        $RawOutput,
        
        [Parameter(Mandatory = $true)]
        $Thresholds
    )
    
    # Parse evaluation rules from check definition
    $evaluationRules = $null
    if ($CheckDefinition.EvaluationRules) {
        try {
            $evaluationRules = $CheckDefinition.EvaluationRules | ConvertFrom-Json
        }
        catch {
            Write-LogWarning "Failed to parse evaluation rules for $($CheckDefinition.CheckId): $($_.Exception.Message)" -Category "Evaluator"
        }
    }
    
    # Default evaluation result
    $result = [PSCustomObject]@{
        Status = 'Pass'
        ProcessedOutput = $RawOutput
        Issues = @()
    }
    
    # If no rules defined, use default pass/fail logic
    if (-not $evaluationRules) {
        return Invoke-DefaultEvaluation -RawOutput $RawOutput -CheckDefinition $CheckDefinition
    }
    
    # Evaluate each rule
    foreach ($rule in $evaluationRules.Rules) {
        try {
            $ruleMatched = Test-RuleCondition -Condition $rule.Condition -Data $RawOutput -Thresholds $Thresholds
            
            if ($ruleMatched) {
                # Update status (highest severity wins)
                if ($rule.Status -eq 'Fail' -or $result.Status -eq 'Pass') {
                    $result.Status = $rule.Status
                }
                
                # Create issue if this is warning or fail
                if ($rule.Status -in @('Warning', 'Fail')) {
                    $issue = [PSCustomObject]@{
                        IssueId = [guid]::NewGuid().ToString()
                        Severity = Get-SeverityFromStatus -Status $rule.Status -DefaultSeverity $CheckDefinition.Severity
                        Title = $rule.Title
                        Description = $rule.Description
                        AffectedObject = Get-AffectedObject -Data $RawOutput -Rule $rule
                        Evidence = $RawOutput
                        Recommendation = $CheckDefinition.RemediationSteps
                    }
                    
                    $result.Issues += $issue
                }
            }
        }
        catch {
            Write-LogWarning "Failed to evaluate rule for $($CheckDefinition.CheckId): $($_.Exception.Message)" -Category "Evaluator"
        }
    }
    
    return $result
}

# =============================================================================
# FUNCTION: Invoke-DefaultEvaluation
# Purpose: Default evaluation logic when no rules are defined
# =============================================================================
function Invoke-DefaultEvaluation {
    <#
    .SYNOPSIS
        Performs default evaluation when no specific rules are defined
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $RawOutput,
        
        [Parameter(Mandatory = $true)]
        $CheckDefinition
    )
    
    $result = [PSCustomObject]@{
        Status = 'Pass'
        ProcessedOutput = $RawOutput
        Issues = @()
    }
    
    # Simple default logic: if output is a collection, check if any items indicate failure
    if ($RawOutput -is [System.Collections.IEnumerable] -and $RawOutput -isnot [string]) {
        $failedItems = @($RawOutput | Where-Object { 
            $_.Status -eq 'Failed' -or 
            $_.Status -eq 'Error' -or 
            $_.IsHealthy -eq $false -or
            $_.HasIssue -eq $true
        })
        
        if ($failedItems.Count -gt 0) {
            $result.Status = 'Fail'
            
            foreach ($item in $failedItems) {
                $issue = [PSCustomObject]@{
                    IssueId = [guid]::NewGuid().ToString()
                    Severity = $CheckDefinition.Severity
                    Title = "$($CheckDefinition.CheckName) Failed"
                    Description = "Item failed validation"
                    AffectedObject = if ($item.Name) { $item.Name } elseif ($item.ComputerName) { $item.ComputerName } else { "Unknown" }
                    Evidence = $item
                    Recommendation = $CheckDefinition.RemediationSteps
                }
                
                $result.Issues += $issue
            }
        }
    }
    # If output has a "Status" property
    elseif ($RawOutput.Status) {
        if ($RawOutput.Status -in @('Failed', 'Error', 'Critical')) {
            $result.Status = 'Fail'
            
            $issue = [PSCustomObject]@{
                IssueId = [guid]::NewGuid().ToString()
                Severity = $CheckDefinition.Severity
                Title = "$($CheckDefinition.CheckName) Failed"
                Description = if ($RawOutput.Message) { $RawOutput.Message } else { "Check returned failure status" }
                AffectedObject = if ($RawOutput.AffectedObject) { $RawOutput.AffectedObject } else { "N/A" }
                Evidence = $RawOutput
                Recommendation = $CheckDefinition.RemediationSteps
            }
            
            $result.Issues += $issue
        }
        elseif ($RawOutput.Status -eq 'Warning') {
            $result.Status = 'Warning'
        }
    }
    
    return $result
}

# =============================================================================
# FUNCTION: Test-RuleCondition
# Purpose: Test if a rule condition is met
# =============================================================================
function Test-RuleCondition {
    <#
    .SYNOPSIS
        Tests if a rule condition evaluates to true
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$Condition,
        
        [Parameter(Mandatory = $true)]
        $Data,
        
        [Parameter(Mandatory = $true)]
        $Thresholds
    )
    
    # Simple expression evaluation
    # This is a simplified implementation - in production you'd use a proper expression parser
    
    # Replace placeholders with actual values
    $expression = $Condition
    
    # Handle common patterns
    if ($Data -is [System.Collections.IEnumerable] -and $Data -isnot [string]) {
        # For collections
        $expression = $expression -replace 'Count', $Data.Count
        $expression = $expression -replace 'Any\(\s*(\w+)\s*==\s*([^\)]+)\)', 
            { param($m) 
                $prop = $m.Groups[1].Value
                $val = $m.Groups[2].Value
                $hasMatch = $Data | Where-Object { $_.$prop -eq $val }
                return ($hasMatch.Count -gt 0)
            }
    }
    else {
        # For single objects, replace property references
        foreach ($prop in $Data.PSObject.Properties) {
            $expression = $expression -replace "\b$($prop.Name)\b", $prop.Value
        }
    }
    
    # Evaluate the expression
    try {
        $result = Invoke-Expression $expression
        return [bool]$result
    }
    catch {
        Write-LogVerbose "Failed to evaluate condition: $Condition - $($_.Exception.Message)" -Category "Evaluator"
        return $false
    }
}

# =============================================================================
# FUNCTION: Get-SeverityFromStatus
# Purpose: Map evaluation status to severity level
# =============================================================================
function Get-SeverityFromStatus {
    param(
        [string]$Status,
        [string]$DefaultSeverity
    )
    
    switch ($Status) {
        'Fail'    { return 'Critical' }
        'Warning' { return 'Medium' }
        'Pass'    { return 'Low' }
        default   { return $DefaultSeverity }
    }
}

# =============================================================================
# FUNCTION: Get-AffectedObject
# Purpose: Extract affected object name from data
# =============================================================================
function Get-AffectedObject {
    param($Data, $Rule)
    
    # Try to find object identifier in various common properties
    $possibleProperties = @('Name', 'ComputerName', 'ServerName', 'DomainController', 'DN', 'DistinguishedName')
    
    foreach ($prop in $possibleProperties) {
        if ($Data.$prop) {
            return $Data.$prop
        }
    }
    
    # If it's a collection, return count
    if ($Data -is [System.Collections.IEnumerable] -and $Data -isnot [string]) {
        return "$($Data.Count) objects"
    }
    
    return "N/A"
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================

Export-ModuleMember -Function @(
    'Invoke-ResultEvaluation'
)
