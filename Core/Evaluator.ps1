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
    $passCount = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Pass' }).Count
    $warnCount = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Warning' }).Count
    $failCount = @($evaluatedResults | Where-Object { $_.EvaluationStatus -eq 'Fail' }).Count
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
        $evaluationRules = $CheckDefinition.EvaluationRules
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
    .DESCRIPTION
        Proper condition parser supporting:
        - Any(Property == 'value')
        - Any(Property > number)
        - Property == value
        - Property != value
        - Property > number
        - Property < number
        - Property >= number
        - Property <= number
        - true/false/null literals
        - Threshold references (CriticalThreshold, WarningThreshold)
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$Condition,
        
        [Parameter(Mandatory = $true)]
        $Data,
        
        [Parameter(Mandatory = $false)]
        $Thresholds
    )
    
    try {
        $condition = $Condition.Trim()
        
        # =====================================================================
        # Handle Any() - collection pattern
        # Any(Property operator value)
        # =====================================================================
        if ($condition -match '^Any\((.+)\)$') {
            $innerCondition = $matches[1].Trim()
            
            # Ensure Data is a collection
            $collection = @($Data)
            if ($collection.Count -eq 0) { return $false }
            
            foreach ($item in $collection) {
                if (Test-SingleCondition -Condition $innerCondition -Item $item -Thresholds $Thresholds) {
                    return $true
                }
            }
            return $false
        }
        
        # =====================================================================
        # Handle All() - all items must match
        # =====================================================================
        if ($condition -match '^All\((.+)\)$') {
            $innerCondition = $matches[1].Trim()
            $collection = @($Data)
            if ($collection.Count -eq 0) { return $false }
            
            foreach ($item in $collection) {
                if (-not (Test-SingleCondition -Condition $innerCondition -Item $item -Thresholds $Thresholds)) {
                    return $false
                }
            }
            return $true
        }
        
        # =====================================================================
        # Handle None() - no items match
        # =====================================================================
        if ($condition -match '^None\((.+)\)$') {
            $innerCondition = $matches[1].Trim()
            $collection = @($Data)
            
            foreach ($item in $collection) {
                if (Test-SingleCondition -Condition $innerCondition -Item $item -Thresholds $Thresholds) {
                    return $false
                }
            }
            return $true
        }
        
        # =====================================================================
        # Handle Count() comparisons
        # Count > 0, Count == 0, etc.
        # =====================================================================
        if ($condition -match '^Count\s*(==|!=|>|<|>=|<=)\s*(.+)$') {
            $operator = $matches[1]
            $compareValue = Resolve-ConditionValue -Value $matches[2].Trim() -Item $null -Thresholds $Thresholds
            $count = @($Data).Count
            return (Compare-Values -Left $count -Operator $operator -Right $compareValue)
        }
        
        # =====================================================================
        # Handle direct property conditions on single object or collection
        # =====================================================================
        # Try as single object first
        $dataItem = $Data
        if ($Data -is [System.Collections.IEnumerable] -and $Data -isnot [string]) {
            $dataItem = @($Data) | Select-Object -First 1
        }
        
        return (Test-SingleCondition -Condition $condition -Item $dataItem -Thresholds $Thresholds)
    }
    catch {
        Write-LogVerbose "Failed to evaluate condition: $Condition - $($_.Exception.Message)" -Category "Evaluator"
        return $false
    }
}

# =============================================================================
# FUNCTION: Test-SingleCondition
# Purpose: Evaluate a simple condition against a single data item
# =============================================================================
function Test-SingleCondition {
    param(
        [string]$Condition,
        $Item,
        $Thresholds
    )
    
    $condition = $Condition.Trim()
    
    # Pattern: Property operator Value
    # Supports: == != > < >= <=
    if ($condition -match '^(.+?)\s*(==|!=|>=|<=|>|<)\s*(.+)$') {
        $propName  = $matches[1].Trim()
        $operator  = $matches[2].Trim()
        $rawRight  = $matches[3].Trim()
        
        # Resolve left side (property value)
        $leftValue = Resolve-PropertyValue -PropertyName $propName -Item $Item -Thresholds $Thresholds
        
        # Resolve right side (literal, threshold, or null)
        $rightValue = Resolve-ConditionValue -Value $rawRight -Item $Item -Thresholds $Thresholds
        
        return (Compare-Values -Left $leftValue -Operator $operator -Right $rightValue)
    }
    
    # Boolean shorthand: just a property name = check if truthy
    if ($condition -match '^(\w+)$') {
        $val = Resolve-PropertyValue -PropertyName $condition -Item $Item -Thresholds $Thresholds
        return [bool]$val
    }
    
    return $false
}

# =============================================================================
# FUNCTION: Resolve-PropertyValue
# Purpose: Get property value from data item or thresholds
# =============================================================================
function Resolve-PropertyValue {
    param(
        [string]$PropertyName,
        $Item,
        $Thresholds
    )
    
    # Check thresholds first
    $thresholdValue = Resolve-ConditionValue -Value $PropertyName -Item $Item -Thresholds $Thresholds -ThresholdOnly
    if ($null -ne $thresholdValue) { return $thresholdValue }
    
    # Check item properties
    if ($null -ne $Item) {
        try {
            $propValue = $Item.$PropertyName
            if ($null -ne $propValue) { return $propValue }
        }
        catch { }
        
        # Try PSObject.Properties for safety
        if ($Item.PSObject.Properties[$PropertyName]) {
            return $Item.PSObject.Properties[$PropertyName].Value
        }
    }
    
    return $null
}

# =============================================================================
# FUNCTION: Resolve-ConditionValue
# Purpose: Resolve a value string to actual typed value
# =============================================================================
function Resolve-ConditionValue {
    param(
        [string]$Value,
        $Item,
        $Thresholds,
        [switch]$ThresholdOnly
    )
    
    $v = $Value.Trim()
    
    # Threshold references
    if ($v -eq 'CriticalThreshold' -and $Thresholds) {
        $t = $Thresholds.backup.backupAgeCriticalDays
        if ($null -ne $t) { return $t }
        return 30
    }
    if ($v -eq 'WarningThreshold' -and $Thresholds) {
        $t = $Thresholds.backup.backupAgeWarningDays
        if ($null -ne $t) { return $t }
        return 14
    }
    
    if ($ThresholdOnly) { return $null }
    
    # null literal
    if ($v -eq 'null') { return $null }
    
    # Boolean literals
    if ($v -eq 'true')  { return $true }
    if ($v -eq 'false') { return $false }
    
    # Quoted string: 'value' or "value"
    if ($v -match "^'(.+)'$" -or $v -match '^"(.+)"$') {
        return $matches[1]
    }
    
    # Numeric
    $num = $null
    if ([double]::TryParse($v, [ref]$num)) { return $num }
    
    # Math expression like (DatabaseSizeGB * 1.25)
    if ($v -match '^\((.+)\)$') {
        $inner = $matches[1]
        if ($inner -match '^(.+?)\s*\*\s*(.+)$') {
            $left  = Resolve-ConditionValue -Value $matches[1].Trim() -Item $Item -Thresholds $Thresholds
            $right = Resolve-ConditionValue -Value $matches[2].Trim() -Item $Item -Thresholds $Thresholds
            if ($null -ne $left -and $null -ne $right) {
                return ([double]$left * [double]$right)
            }
        }
    }
    
    # Property reference — look up on item
    if ($null -ne $Item -and $v -match '^\w+$') {
        try {
            $pval = $Item.$v
            if ($null -ne $pval) { return $pval }
        }
        catch { }
    }
    
    # Return as string fallback
    return $v
}

# =============================================================================
# FUNCTION: Compare-Values
# Purpose: Compare two values with an operator
# =============================================================================
function Compare-Values {
    param(
        $Left,
        [string]$Operator,
        $Right
    )
    
    # Handle null comparisons
    if ($Operator -eq '==' -and $null -eq $Right) { return ($null -eq $Left) }
    if ($Operator -eq '!=' -and $null -eq $Right) { return ($null -ne $Left) }
    if ($null -eq $Left) { return $false }
    
    # Try numeric comparison
    $leftNum  = $null
    $rightNum = $null
    $isNumeric = ([double]::TryParse([string]$Left,  [ref]$leftNum) -and
                  [double]::TryParse([string]$Right, [ref]$rightNum))
    
    switch ($Operator) {
        '==' {
            if ($isNumeric) { return ($leftNum -eq $rightNum) }
            # Boolean comparison
            if ($Right -is [bool] -or $Left -is [bool]) {
                return ([bool]$Left -eq [bool]$Right)
            }
            return ([string]$Left -eq [string]$Right)
        }
        '!=' {
            if ($isNumeric) { return ($leftNum -ne $rightNum) }
            if ($Right -is [bool] -or $Left -is [bool]) {
                return ([bool]$Left -ne [bool]$Right)
            }
            return ([string]$Left -ne [string]$Right)
        }
        '>'  { if ($isNumeric) { return ($leftNum -gt $rightNum) }; return $false }
        '<'  { if ($isNumeric) { return ($leftNum -lt $rightNum) }; return $false }
        '>=' { if ($isNumeric) { return ($leftNum -ge $rightNum) }; return $false }
        '<=' { if ($isNumeric) { return ($leftNum -le $rightNum) }; return $false }
    }
    
    return $false
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
    
    $possibleProperties = @('Name', 'HostName', 'ComputerName', 'ServerName', 
                            'DomainController', 'PDC', 'DC', 'Domain',
                            'DN', 'DistinguishedName', 'SamAccountName')
    
    # If collection, check first item then return count summary
    if ($Data -is [System.Collections.IEnumerable] -and $Data -isnot [string]) {
        $collection = @($Data)
        if ($collection.Count -eq 0) { return "N/A" }
        
        # Try to get name from first item
        $firstItem = $collection[0]
        foreach ($prop in $possibleProperties) {
            try {
                $val = $firstItem.$prop
                if ($val) {
                    if ($collection.Count -gt 1) {
                        return "$val (+$($collection.Count - 1) more)"
                    }
                    return "$val"
                }
            }
            catch { }
        }
        
        return "$($collection.Count) objects"
    }
    
    # Single object
    foreach ($prop in $possibleProperties) {
        try {
            $val = $Data.$prop
            if ($val) { return "$val" }
        }
        catch { }
    }
    
    return "N/A"
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================



