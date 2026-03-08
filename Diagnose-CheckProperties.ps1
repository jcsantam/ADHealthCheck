<#
.SYNOPSIS
    Beta 1.1 Diagnostic - Cross-reference check output properties vs JSON conditions
.NOTES
    Version: 1.1.1 (fixed array parsing)
#>

param(
    [Parameter(Mandatory = $true)]
    $Inventory,
    [string]$ADHealthCheckRoot = "C:\ADHealthCheck"
)

$checksPath = Join-Path $ADHealthCheckRoot 'Checks'
$defsPath   = Join-Path $ADHealthCheckRoot 'Definitions'

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  AD Health Check - Property Name Diagnostic (Beta 1.1)        " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Load all definitions - process each file separately to avoid array merge issues
$allDefs = @()
$defFiles = Get-ChildItem -Path $defsPath -Filter '*.json' -ErrorAction SilentlyContinue

foreach ($f in $defFiles) {
    $raw  = Get-Content -Path $f.FullName -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    $asArray = @($parsed)
    foreach ($item in $asArray) {
        $allDefs += $item
    }
}

Write-Host "Loaded $($allDefs.Count) check definitions from $($defFiles.Count) files" -ForegroundColor Gray
Write-Host ""

$report = @()

foreach ($checkDef in $allDefs) {
    $checkId    = "$($checkDef.CheckId)".Trim()
    $category   = "$($checkDef.Category)".Trim()
    $checkName  = "$($checkDef.CheckName)".Trim()
    $scriptName = "$($checkDef.ScriptPath)".Trim()

    # Skip if missing required fields
    if ([string]::IsNullOrWhiteSpace($checkId) -or [string]::IsNullOrWhiteSpace($category)) {
        Write-Host "  SKIP: Missing CheckId or Category" -ForegroundColor DarkGray
        continue
    }

    if ([string]::IsNullOrWhiteSpace($scriptName)) {
        $scriptName = "Test-$checkId.ps1"
    }

    $scriptPath = Join-Path $checksPath "$category\$scriptName"

    Write-Host "[$checkId] $checkName" -ForegroundColor White

    # Check script exists
    if (-not (Test-Path $scriptPath)) {
        Write-Host "  SKIP: Script not found: $scriptPath" -ForegroundColor DarkGray
        Write-Host ""
        $report += [PSCustomObject]@{
            CheckId          = $checkId
            CheckName        = $checkName
            ScriptFound      = $false
            ExecutionStatus  = 'Skipped'
            Mismatches       = ''
            HasMismatch      = $false
        }
        continue
    }

    # Run the check
    $checkOutput = $null
    $checkError  = $null

    try {
        $checkOutput = & $scriptPath -Inventory $Inventory
        Write-Host "  Executed OK" -ForegroundColor Green
    }
    catch {
        $checkError = $_.Exception.Message
        Write-Host "  Execution FAILED: $checkError" -ForegroundColor Red
    }

    # Get output property names
    $outputProps = @()
    if ($null -ne $checkOutput) {
        $rootProps = @($checkOutput.PSObject.Properties.Name)
        $outputProps += $rootProps

        # Also check inside collection properties
        foreach ($pName in $rootProps) {
            $val = $null
            try { $val = $checkOutput.$pName } catch { }
            if ($val -is [System.Array] -and @($val).Count -gt 0) {
                $first = $val[0]
                if ($null -ne $first -and $first -is [System.Management.Automation.PSCustomObject]) {
                    $nestedProps = @($first.PSObject.Properties.Name)
                    foreach ($np in $nestedProps) {
                        $outputProps += "$pName[].$np"
                    }
                }
            }
        }
    }

    Write-Host "  Output props : $($outputProps -join ', ')" -ForegroundColor Gray

    # Get condition property names from rules
    $conditionProps = @()
    $rules = @($checkDef.EvaluationRules)

    foreach ($rule in $rules) {
        $cond = "$($rule.Condition)".Trim()
        if ([string]::IsNullOrWhiteSpace($cond)) { continue }

        # Extract property name from condition patterns
        if ($cond -match '^(?:Any|All|None)\((\w+)\s*(==|!=|>|<|>=|<=)') {
            $p = $matches[1]
            if ($conditionProps -notcontains $p) { $conditionProps += $p }
        }
        elseif ($cond -match '^(\w+)\s*(==|!=|>|<|>=|<=)') {
            $p = $matches[1]
            if ($p -ne 'Count' -and $conditionProps -notcontains $p) { $conditionProps += $p }
        }
    }

    Write-Host "  Condition props: $($conditionProps -join ', ')" -ForegroundColor Gray

    # Find mismatches
    $mismatches = @()
    $flatOutputProps = @($outputProps | Where-Object { $_ -notmatch '\[\]' })

    foreach ($cp in $conditionProps) {
        $found = $false

        # Direct match on root
        if ($flatOutputProps -contains $cp) { $found = $true }

        # Match inside a collection
        if (-not $found) {
            $nested = @($outputProps | Where-Object { $_ -match "\[\]\.$cp$" })
            if ($nested.Count -gt 0) { $found = $true }
        }

        if (-not $found) { $mismatches += $cp }
    }

    if ($mismatches.Count -eq 0) {
        Write-Host "  STATUS: OK" -ForegroundColor Green
    }
    else {
        Write-Host "  STATUS: MISMATCH - properties not found in output:" -ForegroundColor Yellow
        foreach ($m in $mismatches) {
            Write-Host "    MISSING: '$m'" -ForegroundColor Red
        }
    }

    $report += [PSCustomObject]@{
        CheckId          = $checkId
        CheckName        = $checkName
        ScriptFound      = $true
        ExecutionStatus  = if ($null -ne $checkError) { 'Error' } else { 'OK' }
        OutputProps      = $outputProps -join ', '
        ConditionProps   = $conditionProps -join ', '
        Mismatches       = $mismatches -join ', '
        HasMismatch      = ($mismatches.Count -gt 0)
        ExecutionError   = $checkError
    }

    Write-Host ""
}

# Summary
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan

$ok         = @($report | Where-Object { $_.ScriptFound -and -not $_.HasMismatch -and $_.ExecutionStatus -eq 'OK' })
$mismatched = @($report | Where-Object { $_.HasMismatch })
$skipped    = @($report | Where-Object { -not $_.ScriptFound })
$errors     = @($report | Where-Object { $_.ExecutionStatus -eq 'Error' })

Write-Host "  OK           : $($ok.Count)" -ForegroundColor Green
Write-Host "  Mismatches   : $($mismatched.Count)" -ForegroundColor Yellow
Write-Host "  Skipped      : $($skipped.Count) (script not found)" -ForegroundColor DarkGray
Write-Host "  Exec errors  : $($errors.Count)" -ForegroundColor Red
Write-Host ""

if ($mismatched.Count -gt 0) {
    Write-Host "  Checks needing fixes:" -ForegroundColor Yellow
    foreach ($m in $mismatched) {
        Write-Host "    $($m.CheckId): missing '$($m.Mismatches)'" -ForegroundColor Yellow
    }
    Write-Host ""
}

return $report