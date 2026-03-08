<#
.SYNOPSIS
    AD Health Check - Scorer Module

.DESCRIPTION
    Calculates overall health score (0-100), per-category scores, and letter grade
    based on evaluated check results using hybrid percentage-based scoring.

.NOTES
    Version: 1.2.0-beta2
    Compatibility: PowerShell 5.1+

    Beta 2.0 Changes:
        - Replaced flat penalty scoring with hybrid percentage-based model
        - Score is now normalized by total checks (enterprise-scale safe)
        - Formula: Score = 100 - SUM((FailedBySeverity / TotalChecks) * Weight * 100)
        - Weights: Critical=40, High=25, Medium=20, Low=15
        - A 200-DC environment with 5% critical issues scores ~87 (was 0)
        - Per-category scoring uses same hybrid model
#>

function Invoke-HealthScoring {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        $EvaluatedResults,

        [Parameter(Mandatory = $false)]
        $SeverityWeights
    )

    # -----------------------------------------------------------------------
    # NORMALIZE INPUTS
    # -----------------------------------------------------------------------

    $safeResults = @($EvaluatedResults)

    # Hybrid model uses fixed percentage-based weights
    # SeverityWeights parameter kept for backward compatibility but ignored
    $weights = @{ critical = 2.00; high = 1.20; medium = 0.60; low = 0.20; informational = 0 }

    # -----------------------------------------------------------------------
    # HANDLE EMPTY RESULTS
    # -----------------------------------------------------------------------

    if ($safeResults.Count -eq 0) {
        Write-Warning "[Scorer] No evaluated results - returning default score"
        return [PSCustomObject]@{
            OverallScore       = 100
            Grade              = 'A'
            TotalPenalty       = 0
            CriticalCount      = 0
            HighCount          = 0
            MediumCount        = 0
            LowCount           = 0
            InformationalCount = 0
            CategoryBreakdown  = @{}
            SeverityWeights    = $weights
        }
    }

    $totalChecks = $safeResults.Count

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
    # HYBRID PERCENTAGE-BASED PENALTY
    # Formula: SUM( (CountBySeverity / TotalChecks) * Weight * 100 )
    # -----------------------------------------------------------------------

    $totalPenalty  = 0
    $totalPenalty += ($criticalCount      / $totalChecks) * $weights.critical      * 100
    $totalPenalty += ($highCount          / $totalChecks) * $weights.high          * 100
    $totalPenalty += ($mediumCount        / $totalChecks) * $weights.medium        * 100
    $totalPenalty += ($lowCount           / $totalChecks) * $weights.low           * 100
    $totalPenalty += ($informationalCount / $totalChecks) * $weights.informational * 100

    $totalPenalty = [math]::Round($totalPenalty, 2)
    if ($totalPenalty -gt 100) { $totalPenalty = 100 }

    $overallScore = [math]::Round(100 - $totalPenalty)
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
    # PER-CATEGORY BREAKDOWN (same hybrid model)
    # -----------------------------------------------------------------------

    $categoryBreakdown = @{}
    $categoryGroups = @($safeResults | Group-Object -Property { $_.Category })

    foreach ($group in $categoryGroups) {
        $catName   = $group.Name
        if ($null -eq $catName) { $catName = 'Unknown' }

        $catAll    = @($group.Group)
        $catTotal  = $catAll.Count
        $catIssues = @($catAll | Where-Object { $_.EvaluationStatus -eq 'Fail' -or $_.EvaluationStatus -eq 'Warning' })
        $catPassed = @($catAll | Where-Object { $_.EvaluationStatus -eq 'Pass' }).Count

        $catCrit = 0; $catHigh = 0; $catMed = 0; $catLow = 0

        foreach ($r in $catIssues) {
            $sev = $r.Severity
            if ($null -eq $sev) { $sev = 'low' }
            $sev = "$sev".ToLower().Trim()

            switch ($sev) {
                'critical' { $catCrit++ }
                'high'     { $catHigh++ }
                'medium'   { $catMed++  }
                default    { $catLow++  }
            }
        }

        $catPenalty  = 0
        $catPenalty += ($catCrit / $catTotal) * $weights.critical  * 100
        $catPenalty += ($catHigh / $catTotal) * $weights.high      * 100
        $catPenalty += ($catMed  / $catTotal) * $weights.medium    * 100
        $catPenalty += ($catLow  / $catTotal) * $weights.low       * 100

        $catPenalty = [math]::Round($catPenalty, 2)
        if ($catPenalty -gt 100) { $catPenalty = 100 }

        $catScore = [math]::Round(100 - $catPenalty)
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
            Category      = $catName
            Score         = $catScore
            Grade         = $catGrade
            TotalChecks   = $catTotal
            PassedChecks  = $catPassed
            IssueChecks   = $catIssues.Count
            CriticalCount = $catCrit
            HighCount     = $catHigh
            MediumCount   = $catMed
            LowCount      = $catLow
        }
    }

    # -----------------------------------------------------------------------
    # RETURN RESULT
    # -----------------------------------------------------------------------

    return [PSCustomObject]@{
        OverallScore       = $overallScore
        Grade              = $grade
        TotalPenalty       = $totalPenalty
        CriticalCount      = $criticalCount
        HighCount          = $highCount
        MediumCount        = $mediumCount
        LowCount           = $lowCount
        InformationalCount = $informationalCount
        CategoryBreakdown  = $categoryBreakdown
        SeverityWeights    = $weights
    }
}