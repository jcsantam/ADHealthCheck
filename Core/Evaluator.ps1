<#
.SYNOPSIS
    AD Health Check - Evaluator Module

.DESCRIPTION
    Evaluates check execution results against JSON rule conditions.
    Uses a DSL condition parser that supports collection queries, math expressions,
    threshold references, and all comparison operators.

.NOTES
    Version: 1.1.0-beta1
    Compatibility: PowerShell 5.1+

    Beta 1.1 Changes:
        - Removed double ConvertFrom-Json (EvaluationRules already PSCustomObject)
        - Fixed Get-AffectedObject null safety for collection results
        - Added property alias mapping: normalizes check output property names
          to the canonical names used in JSON rule conditions
        - Improved DSL parser: handles Count(Collection) syntax
        - Added debug tracing for condition evaluation failures
#>

# =============================================================================
# PROPERTY ALIAS MAP
# Normalizes property names from check script output to the names used
# in Definitions JSON condition expressions.
# Format: 'ActualPropertyName' = 'CanonicalConditionName'
# =============================================================================

$script:PropertyAliasMap = @{
    # Replication
    'ReplicationStatus'    = 'Status'
    'PartnerStatus'        = 'Status'
    'ConsecutiveFailures'  = 'FailureCount'
    'LastError'            = 'ErrorCode'
    'QueuedObjects'        = 'QueueLength'

    # DC Health - Services (DC-001)
    'ServiceState'         = 'ServiceStatus'
    'State'                = 'ServiceStatus'
    'Status'               = 'ServiceStatus'   # Catch-all for service objects

    # DC Health - Disk (DC-002)
    'FreeSpacePercent'     = 'FreeSpacePct'
    'FreeMB'               = 'FreeSpaceMB'
    'FreeGB'               = 'FreeSpaceGB'
    'PercentFree'          = 'FreeSpacePct'

    # DC Health - Reachability (DC-003)
    'IsReachable'          = 'Reachable'
    'PingSuccess'          = 'Reachable'

    # DNS
    'ZoneStatus'           = 'Status'
    'RecordExists'         = 'Exists'
    'SRVExists'            = 'Exists'

    # Time
    'TimeDifferenceSec'    = 'OffsetSeconds'
    'TimeDifferenceMs'     = 'OffsetMilliseconds'
    'NTPSource'            = 'TimeSource'
    'NtpServer'            = 'TimeSource'

    # Security - Privileged Accounts (SEC-002)
    'AdminSDHolderMissing' = 'MissingAdminSDHolder'
    'ProtectedUsers'       = 'InProtectedUsersGroup'
}

# =============================================================================
# MAIN EVALUATION FUNCTION
# =============================================================================

function Invoke-ResultEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $ExecutionResults
    )

    $safeResults = @($ExecutionResults)
    $evaluated   = @()

    foreach ($result in $safeResults) {
        try {
            $evalResult = Invoke-SingleEvaluation -Result $result
            $evaluated += $evalResult
        }
        catch {
            Write-Warning "[Evaluator] Failed to evaluate $($result.CheckId): $($_.Exception.Message)"
            Write-Log -Level Warning -Message "Evaluation failed for $($result.CheckId): $($_.Exception.Message)"

            # Return safe default on evaluation error
            $evaluated += [PSCustomObject]@{
                CheckId          = $result.CheckId
                CheckName        = $result.CheckName
                Category         = $result.Category
                EvaluationStatus = 'Warning'
                Severity         = 'medium'
                Message          = "Evaluation error: $($_.Exception.Message)"
                AffectedObjects  = @()
                RawResult        = $result
            }
        }
    }

    $passCount = @($evaluated | Where-Object { $_.EvaluationStatus -eq 'Pass'    }).Count
    $warnCount = @($evaluated | Where-Object { $_.EvaluationStatus -eq 'Warning' }).Count
    $failCount = @($evaluated | Where-Object { $_.EvaluationStatus -eq 'Fail'    }).Count

    Write-Log -Level Information -Message "Evaluation complete: Pass=$passCount Warning=$warnCount Fail=$failCount"

    return $evaluated
}

# =============================================================================
# SINGLE CHECK EVALUATION
# =============================================================================

function Invoke-SingleEvaluation {
    param($Result)

    $checkDef = $Result.CheckDefinition
    $rawData  = $Result.RawOutput

    # No definition - pass through
    if ($null -eq $checkDef) {
        return New-EvalResult -Result $Result -Status 'Pass' -Message 'No definition - assumed healthy'
    }

    # Execution error - mark as warning
    if ($Result.Status -eq 'Error') {
        return New-EvalResult -Result $Result -Status 'Warning' `
            -Message "Check execution failed: $($Result.ErrorMessage)" `
            -Severity 'medium'
    }

    # Null output - mark as warning
    if ($null -eq $rawData) {
        return New-EvalResult -Result $Result -Status 'Warning' `
            -Message 'Check returned null output' `
            -Severity 'low'
    }

    # No evaluation rules defined - use IsHealthy flag if available
    $evalRules = $checkDef.EvaluationRules
    if ($null -eq $evalRules -or @($evalRules).Count -eq 0) {
        if ($null -ne $rawData.IsHealthy) {
            $status = if ($rawData.IsHealthy) { 'Pass' } else { 'Fail' }
            return New-EvalResult -Result $Result -Status $status `
                -Message $rawData.Message `
                -Severity $checkDef.Severity
        }
        return New-EvalResult -Result $Result -Status 'Pass' -Message 'No rules defined'
    }

    # -----------------------------------------------------------------------
    # EVALUATE RULES
    # EvaluationRules is already PSCustomObject from definition loader.
    # DO NOT call ConvertFrom-Json again (Beta 1.0 bug - double parse).
    # -----------------------------------------------------------------------

    $triggeredRules = @()
    $affectedObjects = @()

    foreach ($rule in @($evalRules)) {
        try {
            $conditionMet = Test-RuleCondition -Data $rawData -Condition $rule.Condition -CheckDef $checkDef

            if ($conditionMet) {
                $triggeredRules  += $rule
                $affectedObjects += @(Get-AffectedObjects -Data $rawData -Rule $rule)
            }
        }
        catch {
            Write-Log -Level Verbose -Message "Condition eval error for $($Result.CheckId) '$($rule.Condition)': $($_.Exception.Message)"
        }
    }

    if ($triggeredRules.Count -eq 0) {
        return New-EvalResult -Result $Result -Status 'Pass' -Message 'All conditions within normal parameters'
    }

    # Use highest severity from triggered rules
    $worstRule = Get-HighestSeverityRule -Rules $triggeredRules -DefaultSeverity $checkDef.Severity
    $status    = if ($worstRule.Status) { $worstRule.Status } else { 'Fail' }

    return New-EvalResult -Result $Result `
        -Status          $status `
        -Message         $worstRule.Message `
        -Severity        $worstRule.Severity `
        -AffectedObjects $affectedObjects
}

# =============================================================================
# DSL CONDITION PARSER
# Supports: Any(Prop op val), All(Prop op val), None(Prop op val),
#           Count op val, Prop op val, math expressions, threshold refs
# =============================================================================

function Test-RuleCondition {
    param(
        $Data,
        [string]$Condition,
        $CheckDef
    )

    if ([string]::IsNullOrWhiteSpace($Condition)) { return $false }

    $c = $Condition.Trim()

    # -----------------------------------------------------------------------
    # ANY(Property op Value) - true if ANY item in collection matches
    # -----------------------------------------------------------------------
    if ($c -match '^Any\((.+)\)$') {
        $innerCondition = $matches[1].Trim()
        $dataArray = Get-DataAsArray -Data $Data

        foreach ($item in $dataArray) {
            $normalizedItem = Add-PropertyAliases -Object $item
            if (Test-SimpleCondition -Object $normalizedItem -Condition $innerCondition -CheckDef $CheckDef) {
                return $true
            }
        }
        return $false
    }

    # -----------------------------------------------------------------------
    # ALL(Property op Value) - true if ALL items match
    # -----------------------------------------------------------------------
    if ($c -match '^All\((.+)\)$') {
        $innerCondition = $matches[1].Trim()
        $dataArray = Get-DataAsArray -Data $Data

        if ($dataArray.Count -eq 0) { return $false }

        foreach ($item in $dataArray) {
            $normalizedItem = Add-PropertyAliases -Object $item
            if (-not (Test-SimpleCondition -Object $normalizedItem -Condition $innerCondition -CheckDef $CheckDef)) {
                return $false
            }
        }
        return $true
    }

    # -----------------------------------------------------------------------
    # NONE(Property op Value) - true if NO items match
    # -----------------------------------------------------------------------
    if ($c -match '^None\((.+)\)$') {
        $innerCondition = $matches[1].Trim()
        $dataArray = Get-DataAsArray -Data $Data

        foreach ($item in $dataArray) {
            $normalizedItem = Add-PropertyAliases -Object $item
            if (Test-SimpleCondition -Object $normalizedItem -Condition $innerCondition -CheckDef $CheckDef) {
                return $false  # Found one match => None condition fails
            }
        }
        return $true
    }

    # -----------------------------------------------------------------------
    # COUNT op Value - compares count of items in collection
    # -----------------------------------------------------------------------
    if ($c -match '^Count\s*(==|!=|>|<|>=|<=)\s*(\d+)$') {
        $op       = $matches[1]
        $expected = [int]$matches[2]
        $actual   = (Get-DataAsArray -Data $Data).Count
        return Compare-Values -Left $actual -Operator $op -Right $expected
    }

    # -----------------------------------------------------------------------
    # COUNT(Property) op Value - count items where property is not null/empty
    # -----------------------------------------------------------------------
    if ($c -match '^Count\((\w+)\)\s*(==|!=|>|<|>=|<=)\s*(\d+)$') {
        $propName = $matches[1]
        $op       = $matches[2]
        $expected = [int]$matches[3]
        $dataArray = Get-DataAsArray -Data $Data
        $actual    = @($dataArray | Where-Object { $null -ne $_.$propName -and $_.$propName -ne '' }).Count
        return Compare-Values -Left $actual -Operator $op -Right $expected
    }

    # -----------------------------------------------------------------------
    # Direct property condition on root data object
    # -----------------------------------------------------------------------
    $normalizedData = Add-PropertyAliases -Object $Data
    return Test-SimpleCondition -Object $normalizedData -Condition $c -CheckDef $CheckDef
}

# =============================================================================
# SIMPLE CONDITION: "Property op Value"
# =============================================================================

function Test-SimpleCondition {
    param(
        $Object,
        [string]$Condition,
        $CheckDef
    )

    # Match: PropertyName operator value
    # Operators: ==, !=, >=, <=, >, <
    # Values: quoted strings, numbers, true, false, null
    if ($Condition -notmatch '^(\w+)\s*(==|!=|>=|<=|>|<)\s*(.+)$') {
        Write-Log -Level Verbose -Message "Unrecognized condition syntax: '$Condition'"
        return $false
    }

    $propName  = $matches[1].Trim()
    $operator  = $matches[2].Trim()
    $rawValue  = $matches[3].Trim()

    # Resolve right-hand side value
    $rhsValue = Resolve-ConditionValue -RawValue $rawValue -CheckDef $CheckDef

    # Resolve left-hand side from object
    $lhsValue = Get-PropertyValue -Object $Object -PropertyName $propName

    return Compare-Values -Left $lhsValue -Operator $operator -Right $rhsValue
}

# =============================================================================
# VALUE RESOLVER: handles literals, threshold references, math
# =============================================================================

function Resolve-ConditionValue {
    param(
        [string]$RawValue,
        $CheckDef
    )

    $v = $RawValue.Trim()

    # Quoted string: 'Stopped', "Failed"
    if ($v -match "^'(.*)' $") { return $matches[1] }
    if ($v -match '^"(.*)"$') { return $matches[1] }

    # Boolean literals
    if ($v -eq 'true')  { return $true  }
    if ($v -eq 'false') { return $false }

    # Null literal
    if ($v -eq 'null')  { return $null  }

    # Threshold references from CheckDefinition
    if ($v -eq 'CriticalThreshold' -and $null -ne $CheckDef) {
        $t = $CheckDef.CriticalThreshold
        if ($null -ne $t) { return $t }
    }
    if ($v -eq 'WarningThreshold' -and $null -ne $CheckDef) {
        $t = $CheckDef.WarningThreshold
        if ($null -ne $t) { return $t }
    }

    # Numeric (int or float)
    $numVal = 0.0
    if ([double]::TryParse($v, [ref]$numVal)) { return $numVal }

    # Fall back: return as string
    return $v
}

# =============================================================================
# PROPERTY RESOLVER: gets value from object, with alias fallback
# =============================================================================

function Get-PropertyValue {
    param($Object, [string]$PropertyName)

    if ($null -eq $Object) { return $null }

    # Try direct property access
    try {
        $val = $Object.$PropertyName
        if ($null -ne $val) { return $val }
    }
    catch { }

    # Try via PSObject.Properties (handles dynamic properties)
    try {
        $prop = $Object.PSObject.Properties[$PropertyName]
        if ($null -ne $prop) { return $prop.Value }
    }
    catch { }

    return $null
}

# =============================================================================
# COMPARISON ENGINE
# =============================================================================

function Compare-Values {
    param($Left, [string]$Operator, $Right)

    # Null handling
    if ($null -eq $Left -and $null -eq $Right) {
        return ($Operator -eq '==' -or $Operator -eq '>=')
    }
    if ($null -eq $Left)  {
        if ($Operator -eq '==')  { return $false }
        if ($Operator -eq '!=')  { return $true  }
        return $false
    }
    if ($null -eq $Right) {
        if ($Operator -eq '!=')  { return $true  }
        return $false
    }

    # Boolean comparison
    if ($Left -is [bool] -or $Right -is [bool]) {
        $lb = [bool]$Left
        $rb = [bool]$Right
        switch ($Operator) {
            '==' { return $lb -eq $rb }
            '!=' { return $lb -ne $rb }
        }
        return $false
    }

    # String comparison (case-insensitive)
    if ($Left -is [string] -or $Right -is [string]) {
        $ls = "$Left"
        $rs = "$Right"
        switch ($Operator) {
            '==' { return $ls -ieq $rs }
            '!=' { return $ls -ine $rs }
            '>'  { return [string]::Compare($ls, $rs, $true) -gt 0 }
            '<'  { return [string]::Compare($ls, $rs, $true) -lt 0 }
        }
        return $false
    }

    # Numeric comparison
    try {
        $ln = [double]$Left
        $rn = [double]$Right
        switch ($Operator) {
            '==' { return $ln -eq $rn }
            '!=' { return $ln -ne $rn }
            '>'  { return $ln -gt $rn }
            '<'  { return $ln -lt $rn }
            '>=' { return $ln -ge $rn }
            '<=' { return $ln -le $rn }
        }
    }
    catch { }

    return $false
}

# =============================================================================
# PROPERTY ALIAS INJECTION
# Adds canonical property names to objects so JSON conditions work
# regardless of what the check script named its output properties
# =============================================================================

function Add-PropertyAliases {
    param($Object)

    if ($null -eq $Object) { return $Object }

    # Work on a copy to avoid mutating the original
    $copy = $Object | Select-Object *

    foreach ($alias in $script:PropertyAliasMap.Keys) {
        $canonical = $script:PropertyAliasMap[$alias]

        # If canonical property doesn't exist but alias does, add canonical
        $existingCanonical = $null
        try { $existingCanonical = $copy.$canonical } catch { }

        if ($null -eq $existingCanonical) {
            $existingAlias = $null
            try { $existingAlias = $copy.$alias } catch { }

            if ($null -ne $existingAlias) {
                try {
                    $copy | Add-Member -NotePropertyName $canonical -NotePropertyValue $existingAlias -Force -ErrorAction SilentlyContinue
                }
                catch { }
            }
        }
    }

    return $copy
}

# =============================================================================
# DATA NORMALIZATION: get data as array regardless of structure
# =============================================================================

function Get-DataAsArray {
    param($Data)

    if ($null -eq $Data) { return @() }

    # Already an array
    if ($Data -is [System.Array]) { return @($Data) }

    # PSCustomObject with collection properties - find most likely array property
    if ($Data -is [System.Management.Automation.PSCustomObject]) {
        # Check common collection property names
        $collectionProps = @('Items', 'Results', 'DomainControllers', 'Services',
                             'Partitions', 'Errors', 'Issues', 'Accounts',
                             'Computers', 'Zones', 'Records', 'Forwarders', 'Partners')

        foreach ($propName in $collectionProps) {
            try {
                $val = $Data.$propName
                if ($null -ne $val -and $val -is [System.Array] -and $val.Count -gt 0) {
                    return @($val)
                }
            }
            catch { }
        }

        # Wrap single object as array
        return @($Data)
    }

    return @($Data)
}

# =============================================================================
# AFFECTED OBJECTS EXTRACTOR
# =============================================================================

function Get-AffectedObjects {
    param($Data, $Rule)

    $affected = @()

    try {
        $dataArray = Get-DataAsArray -Data $Data
        $limit = 10  # Don't return more than 10 affected objects

        foreach ($item in $dataArray) {
            if ($affected.Count -ge $limit) { break }

            # Try common identifier properties
            $identProps = @('Name', 'DCName', 'DomainController', 'ComputerName',
                            'SamAccountName', 'DistinguishedName', 'ZoneName',
                            'ServiceName', 'Drive', 'Partition')

            foreach ($prop in $identProps) {
                $val = $null
                try { $val = $item.$prop } catch { }

                if ($null -ne $val -and "$val" -ne '') {
                    $affected += "$val"
                    break
                }
            }
        }
    }
    catch {
        Write-Log -Level Verbose -Message "GetAffectedObjects error: $($_.Exception.Message)"
    }

    return $affected
}

# =============================================================================
# SEVERITY RANKING
# =============================================================================

function Get-HighestSeverityRule {
    param($Rules, $DefaultSeverity)

    $severityRank = @{ critical=4; high=3; medium=2; low=1; informational=0 }

    $best     = $null
    $bestRank = -1

    foreach ($rule in @($Rules)) {
        $sev  = if ($null -ne $rule.Severity) { "$($rule.Severity)".ToLower() } else { $DefaultSeverity }
        $rank = 0
        if ($severityRank.ContainsKey($sev)) { $rank = $severityRank[$sev] }

        if ($rank -gt $bestRank) {
            $bestRank = $rank
            $best     = $rule

            # Ensure severity is set on the rule object for return
            if ($null -eq $best.Severity) {
                $best | Add-Member -NotePropertyName 'Severity' -NotePropertyValue $sev -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if ($null -eq $best -and @($Rules).Count -gt 0) { $best = $Rules[0] }

    return $best
}

# =============================================================================
# RESULT BUILDER
# =============================================================================

function New-EvalResult {
    param(
        $Result,
        [string]$Status,
        [string]$Message     = '',
        [string]$Severity    = 'low',
        [array]$AffectedObjects = @()
    )

    $checkDef = $Result.CheckDefinition
    $sev = $Severity
    if ([string]::IsNullOrWhiteSpace($sev) -and $null -ne $checkDef) {
        $sev = $checkDef.Severity
    }
    if ([string]::IsNullOrWhiteSpace($sev)) { $sev = 'low' }

    $displayMsg = $Message
    if ([string]::IsNullOrWhiteSpace($displayMsg) -and $null -ne $checkDef) {
        if ($Status -eq 'Pass') {
            $displayMsg = if ($checkDef.PassMessage) { $checkDef.PassMessage } else { 'Check passed' }
        }
        else {
            $displayMsg = if ($checkDef.FailMessage) { $checkDef.FailMessage } else { 'Issue detected' }
        }
    }

    return [PSCustomObject]@{
        CheckId          = $Result.CheckId
        CheckName        = $Result.CheckName
        Category         = $Result.Category
        EvaluationStatus = $Status
        Severity         = $sev
        Message          = $displayMsg
        AffectedObjects  = $AffectedObjects
        RawResult        = $Result
    }
}
