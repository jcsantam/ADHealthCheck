<#
.SYNOPSIS
    AD Health Check - Scorer Module

.DESCRIPTION
    Calculates overall health score (0-100), per-category scores, and letter grade
    based on evaluated check results and configurable severity weights.

.NOTES
    Version: 1.1.0-beta1
    Compatibility: PowerShell 5.1+

    Beta 1.1 Changes:
        - Removed [hashtable] type constraints on all parameters (PS 5.1 fix)
        - Score calibration: 5 Critical issues now drops score ~50 points (was ~4)
        - Added letter Grade: A(90+) B(80+) C(70+) D(60+) F(<60)
        - Added per-category score breakdown in result object
        - All .Count calls protected with @() wrapper
        - Replaced ?? operators with explicit if ($null -eq ...) checks
#>

function Invoke-HealthScoring {
    <#
    .SYNOPSIS
        Calculate the health score from evaluated check results.

    .PARAMETER EvaluatedResults
        Array of result objects from Invoke-ResultEvaluation.

    .PARAMETER SeverityWeights
        Hashtable mapping severity level to penalty point value.
        Keys: critical, high, medium, low, informational
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $EvaluatedResults,          # No [object[]] - let PS coerce safely

        [Parameter(Mandatory = $false)]
        $SeverityWeights            # No [hashtable] - handles PSCustomObject from JSON (Beta 1.0 fix)
    )

    # -----------------------------------------------------------------------
    # NORMALIZE INPUTS
    # -----------------------------------------------------------------------

    $safeResults = @($EvaluatedResults)

    # Ensure SeverityWeights is a proper hashtable with all required keys
    if ($null -eq $SeverityWeights) {
        $SeverityWeights = @{}
    }

    # If it arrived as PSCustomObject (from ConvertFrom-Json), convert it
    if ($SeverityWeights -is [System.Management.Automation.PSCustomObject]) {
        $ht = @{}
        foreach ($prop in $SeverityWeights.PSObject.Properties) {
            $ht[$prop.Name] = $prop.Value
        }
        $SeverityWeights = $ht
    }

    # Fill in any missing keys with calibrated defaults
    # Beta 1.1 calibration: Critical=15 (was 10), High=7 (was 5)
    # Rationale: 5 Critical issues should bring score to ~25 range, not 96
    $defaults = @{ critical = 15; high = 7; medium = 3; low = 1; informational = 0 }

    foreach ($key in $defaults.Keys) {
        if (-not $SeverityWeights.ContainsKey($key)) {
            $SeverityWeights[$key] = $defaults[$key]
        }
        else {
            # Ensure value is numeric
            $intVal = 0
            if (-not [int]::TryParse("$($SeverityWeights[$key])", [ref]$intVal)) {
                $intVal = $defaults[$key]
            }
            $SeverityWeights[$key] = $intVal
        }
    }

    # -----------------------------------------------------------------------
    # HANDLE EMPTY RESULTS
    # -----------------------------------------------------------------------

    if ($safeResults.Count -eq 0) {
        Write-Warning "[Scorer] No evaluated results - returning default score"
        return [PSCustomObject]@{
            OverallScore        = 100
            Grade               = 'A'
            TotalPenalty        = 0
            CriticalCount       = 0
            HighCount           = 0
            MediumCount         = 0
            LowCount            = 0
            InformationalCount  = 0
            CategoryBreakdown   = @{}
            SeverityWeights     = $SeverityWeights
        }
    }

    # -----------------------------------------------------------------------
    # COUNT ISSUES BY SEVERITY
    # Only 'Fail' and 'Warning' results contribute to score penalty
    # -----------------------------------------------------------------------

    $issueResults = @($safeResults | Where-Object {
        $_.EvaluationStatus -eq 'Fail' -or $_.EvaluationStatus -eq 'Warning'
    })

    $criticalCount      = 0
    $highCount          = 0
    $mediumCount        = 0
    $lowCount           = 0
    $informationalCount = 0

    foreach ($r in $issueResults) {
        $sev = $r.Severity
        if ($null -eq $sev) { $sev = 'low' }
        $sev = "$sev".ToLower().Trim()

        switch ($sev) {
            'critical'      { $criticalCount++      }
            'high'          { $highCount++           }
            'medium'        { $mediumCount++         }
            'low'           { $lowCount++            }
            'informational' { $informationalCount++  }
            default         { $lowCount++            }
        }
    }

    # -----------------------------------------------------------------------
    # CALCULATE TOTAL PENALTY
    # -----------------------------------------------------------------------

    $totalPenalty  = 0
    $totalPenalty += $criticalCount      * $SeverityWeights['critical']
    $totalPenalty += $highCount          * $SeverityWeights['high']
    $totalPenalty += $mediumCount        * $SeverityWeights['medium']
    $totalPenalty += $lowCount           * $SeverityWeights['low']
    $totalPenalty += $informationalCount * $SeverityWeights['informational']

    # Cap penalty at 100 (score floor is 0)
    if ($totalPenalty -gt 100) { $totalPenalty = 100 }

    $overallScore = 100 - $totalPenalty
    if ($overallScore -lt 0)   { $overallScore = 0   }
    if ($overallScore -gt 100) { $overallScore = 100 }

    # -----------------------------------------------------------------------
    # LETTER GRADE
    # -----------------------------------------------------------------------

    $grade = switch ($true) {
        ($overallScore -ge 90) { 'A' }
        ($overallScore -ge 80) { 'B' }
        ($overallScore -ge 70) { 'C' }
        ($overallScore -ge 60) { 'D' }
        default                { 'F' }
    }

    # -----------------------------------------------------------------------
    # PER-CATEGORY BREAKDOWN
    # -----------------------------------------------------------------------

    $categoryBreakdown = @{}

    $categoryGroups = @($safeResults | Group-Object -Property { $_.Category })

    foreach ($group in $categoryGroups) {
        $catName    = $group.Name
        if ($null -eq $catName) { $catName = 'Unknown' }

        $catAll     = @($group.Group)
        $catIssues  = @($catAll | Where-Object { $_.EvaluationStatus -eq 'Fail' -or $_.EvaluationStatus -eq 'Warning' })
        $catPassed  = @($catAll | Where-Object { $_.EvaluationStatus -eq 'Pass' }).Count

        $catPenalty = 0
        $catCrit = 0; $catHigh = 0; $catMed = 0; $catLow = 0

        foreach ($r in $catIssues) {
            $sev = $r.Severity
            if ($null -eq $sev) { $sev = 'low' }
            $sev = "$sev".ToLower().Trim()

            $w = $SeverityWeights['low']
            if ($SeverityWeights.ContainsKey($sev)) { $w = $SeverityWeights[$sev] }
            $catPenalty += $w

            switch ($sev) {
                'critical' { $catCrit++ }
                'high'     { $catHigh++ }
                'medium'   { $catMed++  }
                default    { $catLow++  }
            }
        }

        $catScore = 100 - $catPenalty
        if ($catScore -lt 0)   { $catScore = 0   }
        if ($catScore -gt 100) { $catScore = 100 }

        $catGrade = switch ($true) {
            ($catScore -ge 90) { 'A' }
            ($catScore -ge 80) { 'B' }
            ($catScore -ge 70) { 'C' }
            ($catScore -ge 60) { 'D' }
            default            { 'F' }
        }

        $categoryBreakdown[$catName] = [PSCustomObject]@{
            Category       = $catName
            Score          = $catScore
            Grade          = $catGrade
            TotalChecks    = $catAll.Count
            PassedChecks   = $catPassed
            IssueChecks    = $catIssues.Count
            CriticalCount  = $catCrit
            HighCount      = $catHigh
            MediumCount    = $catMed
            LowCount       = $catLow
        }
    }

    # -----------------------------------------------------------------------
    # RETURN RESULT
    # -----------------------------------------------------------------------

    return [PSCustomObject]@{
        OverallScore        = $overallScore
        Grade               = $grade
        TotalPenalty        = $totalPenalty
        CriticalCount       = $criticalCount
        HighCount           = $highCount
        MediumCount         = $mediumCount
        LowCount            = $lowCount
        InformationalCount  = $informationalCount
        CategoryBreakdown   = $categoryBreakdown
        SeverityWeights     = $SeverityWeights
    }
}
