<#
.SYNOPSIS
    Enhanced HTML Report Generator

.DESCRIPTION
    Generates professional, interactive HTML reports with:
    - Modern responsive design
    - Health score visualization
    - Interactive tables
    - Color-coded severity badges
    - Executive summary
    - Detailed check results

.PARAMETER Summary
    Run summary object

.PARAMETER Scores
    Health scores object

.PARAMETER Results
    Evaluated check results

.PARAMETER Path
    Output file path

.EXAMPLE
    Export-EnhancedHtmlReport -Summary $summary -Scores $scores -Results $results -Path "report.html"

.NOTES
    Author: AD Health Check Team
    Version: 1.0
#>

function Export-EnhancedHtmlReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Summary,
        
        [Parameter(Mandatory = $true)]
        $Scores,
        
        [Parameter(Mandatory = $true)]
        $Results,
        
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    # Generate timestamp
    $reportTime = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Calculate score rating and color
    $scoreRating = Get-ScoreRating -Score $Scores.OverallScore
    $scoreColor = switch ($Scores.OverallScore) {
        { $_ -ge 90 } { '#28a745' }  # Green
        { $_ -ge 75 } { '#5cb85c' }  # Light green
        { $_ -ge 60 } { '#ffc107' }  # Yellow
        { $_ -ge 40 } { '#fd7e14' }  # Orange
        default { '#dc3545' }         # Red
    }
    
    # Group issues by severity
    $allIssues = $Results | ForEach-Object { $_.Issues } | Where-Object { $_ }
    $criticalIssues = $allIssues | Where-Object { $_.Severity -eq 'Critical' }
    $highIssues = $allIssues | Where-Object { $_.Severity -eq 'High' }
    $mediumIssues = $allIssues | Where-Object { $_.Severity -eq 'Medium' }
    $lowIssues = $allIssues | Where-Object { $_.Severity -eq 'Low' }
    
    # Build HTML
    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>AD Health Check Report - $($Summary.ForestName)</title>
    <style>
        /* ===== GLOBAL STYLES ===== */
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            padding: 20px;
            color: #333;
        }
        
        .container {
            max-width: 1200px;
            margin: 0 auto;
            background: white;
            border-radius: 10px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.2);
            overflow: hidden;
        }
        
        /* ===== HEADER ===== */
        .header {
            background: linear-gradient(135deg, #2c3e50 0%, #3498db 100%);
            color: white;
            padding: 40px;
            text-align: center;
        }
        
        .header h1 {
            font-size: 2.5em;
            margin-bottom: 10px;
            text-shadow: 2px 2px 4px rgba(0,0,0,0.3);
        }
        
        .header .subtitle {
            font-size: 1.2em;
            opacity: 0.9;
        }
        
        .header .metadata {
            margin-top: 20px;
            font-size: 0.9em;
            opacity: 0.8;
        }
        
        /* ===== SCORE GAUGE ===== */
        .score-section {
            background: #f8f9fa;
            padding: 40px;
            text-align: center;
        }
        
        .score-gauge {
            display: inline-block;
            position: relative;
            width: 200px;
            height: 200px;
        }
        
        .score-circle {
            width: 200px;
            height: 200px;
            border-radius: 50%;
            background: conic-gradient(
                $scoreColor 0deg,
                $scoreColor calc($($Scores.OverallScore) * 3.6deg),
                #e9ecef calc($($Scores.OverallScore) * 3.6deg),
                #e9ecef 360deg
            );
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 4px 15px rgba(0,0,0,0.2);
        }
        
        .score-inner {
            width: 160px;
            height: 160px;
            background: white;
            border-radius: 50%;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
        }
        
        .score-value {
            font-size: 3em;
            font-weight: bold;
            color: $scoreColor;
        }
        
        .score-rating {
            font-size: 1.1em;
            color: #666;
            margin-top: 5px;
        }
        
        /* ===== SUMMARY CARDS ===== */
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            padding: 40px;
            background: white;
        }
        
        .card {
            background: #f8f9fa;
            border-radius: 8px;
            padding: 25px;
            border-left: 4px solid #007bff;
            transition: transform 0.2s, box-shadow 0.2s;
        }
        
        .card:hover {
            transform: translateY(-5px);
            box-shadow: 0 6px 20px rgba(0,0,0,0.15);
        }
        
        .card.critical { border-left-color: #dc3545; }
        .card.high { border-left-color: #fd7e14; }
        .card.medium { border-left-color: #ffc107; }
        .card.low { border-left-color: #28a745; }
        
        .card-title {
            font-size: 0.9em;
            color: #666;
            text-transform: uppercase;
            margin-bottom: 10px;
            letter-spacing: 0.5px;
        }
        
        .card-value {
            font-size: 2.5em;
            font-weight: bold;
            color: #2c3e50;
        }
        
        .card-label {
            font-size: 0.9em;
            color: #999;
            margin-top: 5px;
        }
        
        /* ===== CATEGORY SCORES ===== */
        .category-scores {
            padding: 40px;
            background: white;
        }
        
        .section-title {
            font-size: 1.8em;
            color: #2c3e50;
            margin-bottom: 25px;
            padding-bottom: 10px;
            border-bottom: 3px solid #3498db;
        }
        
        .category-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 20px;
        }
        
        .category-card {
            background: #f8f9fa;
            border-radius: 8px;
            padding: 20px;
            text-align: center;
        }
        
        .category-name {
            font-size: 1em;
            color: #666;
            margin-bottom: 10px;
        }
        
        .category-score {
            font-size: 2em;
            font-weight: bold;
            margin: 10px 0;
        }
        
        .category-bar {
            width: 100%;
            height: 8px;
            background: #e9ecef;
            border-radius: 4px;
            overflow: hidden;
            margin-top: 10px;
        }
        
        .category-bar-fill {
            height: 100%;
            border-radius: 4px;
            transition: width 0.3s ease;
        }
        
        /* ===== ISSUES TABLE ===== */
        .issues-section {
            padding: 40px;
            background: #f8f9fa;
        }
        
        .severity-badge {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 12px;
            font-size: 0.85em;
            font-weight: bold;
            text-transform: uppercase;
        }
        
        .severity-critical {
            background: #dc3545;
            color: white;
        }
        
        .severity-high {
            background: #fd7e14;
            color: white;
        }
        
        .severity-medium {
            background: #ffc107;
            color: #333;
        }
        
        .severity-low {
            background: #28a745;
            color: white;
        }
        
        table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 20px;
            background: white;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 8px rgba(0,0,0,0.1);
        }
        
        thead {
            background: #2c3e50;
            color: white;
        }
        
        th {
            padding: 15px;
            text-align: left;
            font-weight: 600;
            text-transform: uppercase;
            font-size: 0.85em;
            letter-spacing: 0.5px;
        }
        
        td {
            padding: 15px;
            border-bottom: 1px solid #e9ecef;
        }
        
        tr:hover {
            background: #f8f9fa;
        }
        
        .issue-title {
            font-weight: 600;
            color: #2c3e50;
            margin-bottom: 5px;
        }
        
        .issue-description {
            font-size: 0.9em;
            color: #666;
        }
        
        .affected-object {
            font-family: 'Courier New', monospace;
            background: #f8f9fa;
            padding: 2px 6px;
            border-radius: 3px;
            font-size: 0.9em;
        }
        
        /* ===== CHECK RESULTS ===== */
        .checks-section {
            padding: 40px;
            background: white;
        }
        
        .check-item {
            background: #f8f9fa;
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 15px;
            border-left: 4px solid #28a745;
        }
        
        .check-item.warning {
            border-left-color: #ffc107;
        }
        
        .check-item.fail {
            border-left-color: #dc3545;
        }
        
        .check-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 10px;
        }
        
        .check-name {
            font-weight: 600;
            color: #2c3e50;
            font-size: 1.1em;
        }
        
        .check-status {
            padding: 4px 12px;
            border-radius: 12px;
            font-size: 0.85em;
            font-weight: bold;
        }
        
        .status-pass {
            background: #28a745;
            color: white;
        }
        
        .status-warning {
            background: #ffc107;
            color: #333;
        }
        
        .status-fail {
            background: #dc3545;
            color: white;
        }
        
        .check-details {
            font-size: 0.9em;
            color: #666;
            margin-top: 10px;
        }
        
        /* ===== FOOTER ===== */
        .footer {
            background: #2c3e50;
            color: white;
            padding: 30px;
            text-align: center;
        }
        
        .footer a {
            color: #3498db;
            text-decoration: none;
        }
        
        .footer a:hover {
            text-decoration: underline;
        }
        
        /* ===== PRINT STYLES ===== */
        @media print {
            body {
                background: white;
                padding: 0;
            }
            
            .container {
                box-shadow: none;
            }
            
            .card:hover,
            tr:hover {
                transform: none;
                background: transparent;
            }
        }
        
        /* ===== RESPONSIVE ===== */
        @media (max-width: 768px) {
            .header h1 {
                font-size: 1.8em;
            }
            
            .summary-cards {
                grid-template-columns: 1fr;
            }
            
            .category-grid {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- HEADER -->
        <div class="header">
            <h1>ðŸ” Active Directory Health Check Report</h1>
            <div class="subtitle">$($Summary.ForestName)</div>
            <div class="metadata">
                Generated: $reportTime | Run ID: $($Summary.RunId.Substring(0,8))... | Executed by: $($Summary.ExecutedBy)@$($Summary.ExecutionHost)
            </div>
        </div>
        
        <!-- SCORE GAUGE -->
        <div class="score-section">
            <h2 style="margin-bottom: 30px; color: #2c3e50;">Overall Health Score</h2>
            <div class="score-gauge">
                <div class="score-circle">
                    <div class="score-inner">
                        <div class="score-value">$($Scores.OverallScore)</div>
                        <div class="score-rating">$scoreRating</div>
                    </div>
                </div>
            </div>
        </div>
        
        <!-- SUMMARY CARDS -->
        <div class="summary-cards">
            <div class="card">
                <div class="card-title">Total Checks</div>
                <div class="card-value">$($Summary.TotalChecks)</div>
                <div class="card-label">Executed</div>
            </div>
            
            <div class="card critical">
                <div class="card-title">Critical Issues</div>
                <div class="card-value">$($Summary.CriticalIssues)</div>
                <div class="card-label">Require Immediate Action</div>
            </div>
            
            <div class="card high">
                <div class="card-title">High Priority</div>
                <div class="card-value">$($Summary.HighIssues)</div>
                <div class="card-label">Address Soon</div>
            </div>
            
            <div class="card medium">
                <div class="card-title">Medium Priority</div>
                <div class="card-value">$($Summary.MediumIssues)</div>
                <div class="card-label">Plan Remediation</div>
            </div>
        </div>
        
        <!-- CATEGORY SCORES -->
        <div class="category-scores">
            <h2 class="section-title">Category Health Scores</h2>
            <div class="category-grid">
"@
    
    # Add category score cards
    foreach ($catScore in $Scores.CategoryScores) {
        $catColor = switch ($catScore.ScoreValue) {
            { $_ -ge 90 } { '#28a745' }
            { $_ -ge 75 } { '#5cb85c' }
            { $_ -ge 60 } { '#ffc107' }
            { $_ -ge 40 } { '#fd7e14' }
            default { '#dc3545' }
        }
        
        $html += @"
                <div class="category-card">
                    <div class="category-name">$($catScore.CategoryId)</div>
                    <div class="category-score" style="color: $catColor;">$($catScore.ScoreValue)</div>
                    <div class="category-bar">
                        <div class="category-bar-fill" style="width: $($catScore.ScoreValue)%; background: $catColor;"></div>
                    </div>
                    <div class="card-label">$($catScore.ChecksPassed)/$($catScore.ChecksExecuted) Passed</div>
                </div>
"@
    }
    
    $html += @"
            </div>
        </div>
"@
    
    # Issues table (if any issues exist)
    if ($allIssues.Count -gt 0) {
        $html += @"
        
        <!-- ISSUES TABLE -->
        <div class="issues-section">
            <h2 class="section-title">Detected Issues</h2>
            <table>
                <thead>
                    <tr>
                        <th>Severity</th>
                        <th>Issue</th>
                        <th>Affected Object</th>
                        <th>Check</th>
                    </tr>
                </thead>
                <tbody>
"@
        
        # Sort issues by severity
        $sortedIssues = $allIssues | Sort-Object {
            switch ($_.Severity) {
                'Critical' { 1 }
                'High' { 2 }
                'Medium' { 3 }
                'Low' { 4 }
                default { 5 }
            }
        }
        
        foreach ($issue in $sortedIssues) {
            $severityClass = $issue.Severity.ToLower()
            $checkResult = $Results | Where-Object { $_.Issues -contains $issue } | Select-Object -First 1
            
            $html += @"
                    <tr>
                        <td><span class="severity-badge severity-$severityClass">$($issue.Severity)</span></td>
                        <td>
                            <div class="issue-title">$($issue.Title)</div>
                            <div class="issue-description">$($issue.Description)</div>
                        </td>
                        <td><span class="affected-object">$($issue.AffectedObject)</span></td>
                        <td>$($checkResult.CheckName)</td>
                    </tr>
"@
        }
        
        $html += @"
                </tbody>
            </table>
        </div>
"@
    }
    
    # Check results section
    $html += @"
        
        <!-- CHECK RESULTS -->
        <div class="checks-section">
            <h2 class="section-title">Detailed Check Results</h2>
"@
    
    foreach ($result in $Results) {
        $statusClass = $result.EvaluationStatus.ToLower()
        $itemClass = if ($result.EvaluationStatus -eq 'Fail') { 'fail' } 
                     elseif ($result.EvaluationStatus -eq 'Warning') { 'warning' } 
                     else { '' }
        
        $html += @"
            <div class="check-item $itemClass">
                <div class="check-header">
                    <div class="check-name">$($result.CheckName) ($($result.CheckId))</div>
                    <span class="check-status status-$statusClass">$($result.EvaluationStatus)</span>
                </div>
                <div class="check-details">
                    <strong>Category:</strong> $($result.CategoryId) | 
                    <strong>Duration:</strong> $([math]::Round($result.DurationMs / 1000, 2))s | 
                    <strong>Issues:</strong> $($result.IssueCount)
                </div>
            </div>
"@
    }
    
    $html += @"
        </div>
        
        <!-- FOOTER -->
        <div class="footer">
            <p><strong>AD Health Check Tool</strong> - Enterprise Edition v1.0</p>
            <p style="margin-top: 10px; font-size: 0.9em; opacity: 0.8;">
                Generated by PowerShell | 
                <a href="https://github.com/jcsantam/ADHealthCheck" target="_blank">View on GitHub</a>
            </p>
        </div>
    </div>
</body>
</html>
"@
    
    # Write to file
    $html | Out-File -FilePath $Path -Encoding UTF8 -Force
    
    Write-Verbose "Enhanced HTML report exported to: $Path"
}

# Helper function for score rating
function Get-ScoreRating {
    param([int]$Score)
    
    if ($Score -ge 95) { return "Excellent" }
    elseif ($Score -ge 85) { return "Very Good" }
    elseif ($Score -ge 75) { return "Good" }
    elseif ($Score -ge 65) { return "Fair" }
    elseif ($Score -ge 50) { return "Poor" }
    else { return "Critical" }
}

