<#
.SYNOPSIS
    Health scoring algorithm

.DESCRIPTION
    Calculates health scores based on check results:
    - Overall health score (0-100)
    - Category-specific scores
    - Weighted scoring based on severity
    - Trending support

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Scoring formula: Base score minus weighted deductions for issues
#>

# Import logger if available
if (Test-Path "$PSScriptRoot\Logger.ps1") {
    . "$PSScriptRoot\Logger.ps1"
}

# =============================================================================
# FUNCTION: Invoke-HealthScoring
# Purpose: Calculate health scores from evaluated results
# =============================================================================
function Invoke-HealthScoring {
    <#
    .SYNOPSIS
        Calculates health scores from evaluation results
    
    .PARAMETER EvaluatedResults
        Array of evaluated check results
    
    .PARAMETER SeverityWeights
        Hashtable of severity weights (Critical, High, Medium, Low)
    
    .PARAMETER CategoryWeights
        Hashtable of category weights for overall score
    
    .EXAMPLE
        $scores = Invoke-HealthScoring -EvaluatedResults $results -SeverityWeights $weights -CategoryWeights $catWeights
    
    .OUTPUTS
        PSCustomObject with overall and category scores
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$EvaluatedResults,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$SeverityWeights = @{
            'Critical' = 10
            'High' = 5
            'Medium' = 2
            'Low' = 1
            'Informational' = 0
        },
        
        [Parameter(Mandatory = $false)]
        [hashtable]$CategoryWeights = @{
            'Replication' = 25
            'DCHealth' = 20
            'DNS' = 15
            'GPO' = 10
            'Time' = 10
            'Backup' = 10
            'Security' = 5
            'Database' = 3
            'Operational' = 2
        }
    )
    
    Write-LogInfo "Starting health scoring calculation" -Category "Scorer"
    
    try {
        # Group results by category
        $categorizedResults = $EvaluatedResults | Group-Object -Property CategoryId
        
        # Calculate score for each category
        $categoryScores = @()
        
        foreach ($category in $categorizedResults) {
            $categoryId = $category.Name
            $categoryResults = $category.Group
            
            Write-LogVerbose "Calculating score for category: $categoryId" -Category "Scorer"
            
            $categoryScore = Get-CategoryScore `
                -CategoryId $categoryId `
                -Results $categoryResults `
                -SeverityWeights $SeverityWeights
            
            $categoryScores += $categoryScore
        }
        
        # Calculate overall score
        $overallScore = Get-OverallScore `
            -CategoryScores $categoryScores `
            -CategoryWeights $CategoryWeights
        
        # Build final score object
        $scores = [PSCustomObject]@{
            OverallScore = $overallScore.Score
            MaxPossibleScore = 100
            CalculationMethod = "Weighted category scores"
            CategoryScores = $categoryScores
            ScoreBreakdown = $overallScore.Breakdown
            Timestamp = Get-Date
        }
        
        Write-LogInfo "Health scoring completed" -Category "Scorer"
        Write-LogInfo "  Overall Score: $($scores.OverallScore)/100" -Category "Scorer"
        
        foreach ($catScore in $categoryScores) {
            Write-LogVerbose "  $($catScore.CategoryId): $($catScore.ScoreValue)/100" -Category "Scorer"
        }
        
        return $scores
    }
    catch {
        Write-LogError "Health scoring failed: $($_.Exception.Message)" -Category "Scorer" -Exception $_.Exception
        throw
    }
}

# =============================================================================
# FUNCTION: Get-CategoryScore
# Purpose: Calculate score for a specific category
# =============================================================================
function Get-CategoryScore {
    <#
    .SYNOPSIS
        Calculates health score for a category
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$CategoryId,
        
        [Parameter(Mandatory = $true)]
        [array]$Results,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$SeverityWeights
    )
    
    # Base score starts at 100
    $baseScore = 100
    $deductions = 0
    
    # Count checks by status
    $totalChecks = $Results.Count
    $passedChecks = ($Results | Where-Object { $_.EvaluationStatus -eq 'Pass' }).Count
    $warningChecks = ($Results | Where-Object { $_.EvaluationStatus -eq 'Warning' }).Count
    $failedChecks = ($Results | Where-Object { $_.EvaluationStatus -eq 'Fail' }).Count
    
    # Count issues by severity
    $allIssues = $Results | ForEach-Object { $_.Issues } | Where-Object { $_ }
    $issuesBySeverity = $allIssues | Group-Object -Property Severity
    
    $criticalCount = ($issuesBySeverity | Where-Object { $_.Name -eq 'Critical' } | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue) ?? 0
    $highCount = ($issuesBySeverity | Where-Object { $_.Name -eq 'High' } | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue) ?? 0
    $mediumCount = ($issuesBySeverity | Where-Object { $_.Name -eq 'Medium' } | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue) ?? 0
    $lowCount = ($issuesBySeverity | Where-Object { $_.Name -eq 'Low' } | Select-Object -ExpandProperty Count -ErrorAction SilentlyContinue) ?? 0
    
    # Calculate deductions based on severity weights
    $deductions += $criticalCount * $SeverityWeights['Critical']
    $deductions += $highCount * $SeverityWeights['High']
    $deductions += $mediumCount * $SeverityWeights['Medium']
    $deductions += $lowCount * $SeverityWeights['Low']
    
    # Calculate final score (cannot go below 0)
    $finalScore = [Math]::Max(0, $baseScore - $deductions)
    
    # Create category score object
    $categoryScore = [PSCustomObject]@{
        CategoryId = $CategoryId
        ScoreValue = $finalScore
        MaxPossible = 100
        ChecksExecuted = $totalChecks
        ChecksPassed = $passedChecks
        ChecksWarning = $warningChecks
        ChecksFailed = $failedChecks
        IssueBreakdown = [PSCustomObject]@{
            Critical = $criticalCount
            High = $highCount
            Medium = $mediumCount
            Low = $lowCount
        }
        Deductions = $deductions
        Details = "Base: $baseScore, Deductions: $deductions, Final: $finalScore"
    }
    
    return $categoryScore
}

# =============================================================================
# FUNCTION: Get-OverallScore
# Purpose: Calculate weighted overall score from category scores
# =============================================================================
function Get-OverallScore {
    <#
    .SYNOPSIS
        Calculates weighted overall health score
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [array]$CategoryScores,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$CategoryWeights
    )
    
    # Calculate weighted average
    $weightedSum = 0
    $totalWeight = 0
    $breakdown = @()
    
    foreach ($catScore in $CategoryScores) {
        $categoryId = $catScore.CategoryId
        $weight = $CategoryWeights[$categoryId]
        
        if (-not $weight) {
            Write-LogWarning "No weight defined for category: $categoryId, using 1" -Category "Scorer"
            $weight = 1
        }
        
        $contribution = $catScore.ScoreValue * ($weight / 100)
        $weightedSum += $contribution
        $totalWeight += $weight
        
        $breakdown += [PSCustomObject]@{
            Category = $categoryId
            Score = $catScore.ScoreValue
            Weight = $weight
            Contribution = $contribution
        }
    }
    
    # Normalize to 0-100 scale
    $overallScore = if ($totalWeight -gt 0) {
        [Math]::Round(($weightedSum / $totalWeight) * 100, 0)
    } else {
        0
    }
    
    return [PSCustomObject]@{
        Score = $overallScore
        Breakdown = $breakdown
    }
}

# =============================================================================
# FUNCTION: Get-ScoreRating
# Purpose: Convert numeric score to text rating
# =============================================================================
function Get-ScoreRating {
    <#
    .SYNOPSIS
        Converts numeric score to text rating
    
    .PARAMETER Score
        Numeric score (0-100)
    
    .EXAMPLE
        Get-ScoreRating -Score 85  # Returns "Excellent"
    
    .OUTPUTS
        String rating
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [int]$Score
    )
    
    if ($Score -ge 95) { return "Excellent" }
    elseif ($Score -ge 85) { return "Very Good" }
    elseif ($Score -ge 75) { return "Good" }
    elseif ($Score -ge 65) { return "Fair" }
    elseif ($Score -ge 50) { return "Poor" }
    else { return "Critical" }
}

# =============================================================================
# FUNCTION: Compare-Scores
# Purpose: Compare scores between two runs for trending
# =============================================================================
function Compare-Scores {
    <#
    .SYNOPSIS
        Compares scores between two health check runs
    
    .PARAMETER CurrentScores
        Current run scores
    
    .PARAMETER PreviousScores
        Previous run scores
    
    .EXAMPLE
        $comparison = Compare-Scores -CurrentScores $current -PreviousScores $previous
    
    .OUTPUTS
        Comparison object with trends
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$CurrentScores,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$PreviousScores
    )
    
    $comparison = [PSCustomObject]@{
        OverallChange = $CurrentScores.OverallScore - $PreviousScores.OverallScore
        OverallTrend = Get-TrendIndicator -Current $CurrentScores.OverallScore -Previous $PreviousScores.OverallScore
        CategoryChanges = @()
    }
    
    foreach ($currentCat in $CurrentScores.CategoryScores) {
        $prevCat = $PreviousScores.CategoryScores | Where-Object { $_.CategoryId -eq $currentCat.CategoryId } | Select-Object -First 1
        
        if ($prevCat) {
            $change = $currentCat.ScoreValue - $prevCat.ScoreValue
            
            $comparison.CategoryChanges += [PSCustomObject]@{
                CategoryId = $currentCat.CategoryId
                CurrentScore = $currentCat.ScoreValue
                PreviousScore = $prevCat.ScoreValue
                Change = $change
                Trend = Get-TrendIndicator -Current $currentCat.ScoreValue -Previous $prevCat.ScoreValue
            }
        }
    }
    
    return $comparison
}

# =============================================================================
# FUNCTION: Get-TrendIndicator
# Purpose: Determine trend direction
# =============================================================================
function Get-TrendIndicator {
    param(
        [int]$Current,
        [int]$Previous
    )
    
    $diff = $Current - $Previous
    
    if ($diff -gt 5) { return "Improving" }
    elseif ($diff -lt -5) { return "Degrading" }
    else { return "Stable" }
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================

Export-ModuleMember -Function @(
    'Invoke-HealthScoring',
    'Get-ScoreRating',
    'Compare-Scores'
)
