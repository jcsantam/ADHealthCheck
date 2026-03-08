<#
.SYNOPSIS
    AD Health Check - Executor Module

.DESCRIPTION
    Executes check scripts in parallel using RunspacePool.
    Each check runs in an isolated runspace with access to the AD Inventory.

.NOTES
    Version: 1.1.0-beta1
    Compatibility: PowerShell 5.1+

    Beta 1.1 Changes:
        - Confirmed: No nested Start-Job (root cause of null RawOutput in Beta 1.0)
        - Direct script invocation inside runspace: $result = & $ScriptPath -Inventory $inv
        - Added per-check timeout enforcement
        - @() protection on all collection .Count calls
        - Improved error capture per runspace
#>

function Invoke-CheckExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $CheckDefinitions,

        [Parameter(Mandatory = $true)]
        $Inventory,

        [Parameter(Mandatory = $true)]
        [string]$ChecksPath,

        [Parameter(Mandatory = $false)]
        [int]$MaxParallelJobs = 10,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 300
    )

    $safeChecks = @($CheckDefinitions)
    $results    = @()

    Write-Log -Level Information -Message "Executor: Starting $($safeChecks.Count) checks (MaxParallel=$MaxParallelJobs, Timeout=$TimeoutSeconds`s)"

    if ($safeChecks.Count -eq 0) {
        Write-Warning "[Executor] No checks to execute"
        return $results
    }

    # -----------------------------------------------------------------------
    # CREATE RUNSPACE POOL
    # -----------------------------------------------------------------------

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    # Import Active Directory module into each runspace
    $adModule = Get-Module -Name ActiveDirectory -ListAvailable | Select-Object -First 1
    if ($null -ne $adModule) {
        $sessionState.ImportPSModule('ActiveDirectory')
        $sessionState.ImportPSModule('DnsServer')
        $sessionState.ImportPSModule('GroupPolicy')
    }

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1,              # Min threads
        $MaxParallelJobs,
        $sessionState,
        $Host
    )
    $pool.Open()

    # -----------------------------------------------------------------------
    # SUBMIT ALL JOBS
    # -----------------------------------------------------------------------

    $jobs = @()

    foreach ($checkDef in $safeChecks) {
        $checkId   = $checkDef.CheckId
        $category  = $checkDef.Category
        $checkName = $checkDef.CheckName

        if ([string]::IsNullOrWhiteSpace($checkId)) {
            Write-Log -Level Warning -Message "Skipping check with missing CheckId"
            continue
        }

        # Resolve script path
        $scriptFileName = $checkDef.ScriptPath
        if ([string]::IsNullOrWhiteSpace($scriptFileName)) {
            $scriptFileName = "$($checkDef.CheckId).ps1"
        }

        $scriptPath = Join-Path $ChecksPath "$category\$scriptFileName"

        if (-not (Test-Path $scriptPath)) {
            Write-Log -Level Warning -Message "Script not found for $checkId`: $scriptPath"

            $results += [PSCustomObject]@{
                CheckId         = $checkId
                CheckName       = $checkName
                Category        = $category
                Status          = 'Error'
                ErrorMessage    = "Script not found: $scriptPath"
                RawOutput       = $null
                TimedOut        = $false
                DurationSeconds = 0
                CheckDefinition = $checkDef
            }
            continue
        }

        # -----------------------------------------------------------------------
        # SCRIPTBLOCK: Direct execution inside runspace - NO nested Start-Job
        # PSCustomObjects serialize correctly this way in PS 5.1
        # -----------------------------------------------------------------------

        $scriptBlock = {
            param($ScriptPath, $InvData, $CheckId, $TimeoutSec)

            $startTime = Get-Date
            $output    = $null
            $errMsg    = $null
            $timedOut  = $false

            try {
                # Direct invocation - passes Inventory by reference within same process
                $inv = $InvData | ConvertFrom-Json
                $output = & $ScriptPath -Inventory $inv
            }
            catch {
                $errMsg = $_.Exception.Message
            }

            $duration = ((Get-Date) - $startTime).TotalSeconds

            return [PSCustomObject]@{
                CheckId         = $CheckId
                RawOutput       = $output
                ErrorMessage    = $errMsg
                TimedOut        = $timedOut
                DurationSeconds = [math]::Round($duration, 2)
            }
        }

        # Create PowerShell instance in the pool
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = $pool
        $null = $ps.AddScript($scriptBlock)
        $null = $ps.AddArgument($scriptPath)
        $null = $ps.AddArgument(($Inventory | ConvertTo-Json -Depth 10 -Compress))
        $null = $ps.AddArgument($checkId)
        $null = $ps.AddArgument($TimeoutSeconds)

        $asyncResult = $ps.BeginInvoke()

        $jobs += [PSCustomObject]@{
            CheckId         = $checkId
            CheckName       = $checkName
            Category        = $category
            CheckDefinition = $checkDef
            PS              = $ps
            AsyncResult     = $asyncResult
            StartTime       = Get-Date
        }

        Write-Log -Level Verbose -Message "Submitted job: $checkId"
    }

    Write-Host "  Submitted $($jobs.Count) jobs to RunspacePool..." -ForegroundColor Gray

    # -----------------------------------------------------------------------
    # COLLECT RESULTS
    # -----------------------------------------------------------------------

    $collected = 0
    $total     = $jobs.Count

    foreach ($job in $jobs) {
        $elapsed = ((Get-Date) - $job.StartTime).TotalSeconds
        $remaining = $TimeoutSeconds - $elapsed
        if ($remaining -lt 1) { $remaining = 1 }

        $timedOut    = $false
        $rawOutput   = $null
        $errMessage  = $null
        $duration    = 0

        try {
            $completed = $job.AsyncResult.AsyncWaitHandle.WaitOne([int]($remaining * 1000))

            if (-not $completed) {
                $timedOut   = $true
                $errMessage = "Timed out after $TimeoutSeconds seconds"
                Write-Log -Level Warning -Message "Timeout: $($job.CheckId)"
                $job.PS.Stop()
            }
            else {
                $jobResult = $job.PS.EndInvoke($job.AsyncResult)

                if (@($jobResult).Count -gt 0 -and $null -ne $jobResult[0]) {
                    $r = $jobResult[0]
                    $rawOutput  = $r.RawOutput
                    $errMessage = $r.ErrorMessage
                    $duration   = $r.DurationSeconds
                }

                # Capture any stream errors
                if (@($job.PS.Streams.Error).Count -gt 0) {
                    $streamErrs = ($job.PS.Streams.Error | ForEach-Object { $_.ToString() }) -join '; '
                    if ([string]::IsNullOrWhiteSpace($errMessage)) {
                        $errMessage = "Stream errors: $streamErrs"
                    }
                    Write-Log -Level Verbose -Message "$($job.CheckId) stream errors: $streamErrs"
                }
            }
        }
        catch {
            $errMessage = $_.Exception.Message
            Write-Log -Level Warning -Message "Job collection error for $($job.CheckId): $errMessage"
        }
        finally {
            try { $job.PS.Dispose() } catch { }
        }

        $status = if ($timedOut -or $null -ne $errMessage) { 'Error' } else { 'Completed' }
        if ($null -ne $rawOutput) { $status = 'Completed' }

        $results += [PSCustomObject]@{
            CheckId         = $job.CheckId
            CheckName       = $job.CheckName
            Category        = $job.Category
            Status          = $status
            ErrorMessage    = $errMessage
            RawOutput       = $rawOutput
            TimedOut        = $timedOut
            DurationSeconds = $duration
            CheckDefinition = $job.CheckDefinition
        }

        $collected++
        $pct = [math]::Round(($collected / $total) * 100)
        Write-Progress -Activity "Executing checks" -Status "$collected/$total complete" -PercentComplete $pct
    }

    Write-Progress -Activity "Executing checks" -Completed

    # -----------------------------------------------------------------------
    # CLEANUP
    # -----------------------------------------------------------------------

    try { $pool.Close(); $pool.Dispose() } catch { }

    $successCount = @($results | Where-Object { $_.Status -eq 'Completed' }).Count
    $errorCount   = @($results | Where-Object { $_.Status -eq 'Error'     }).Count
    $timeoutCount = @($results | Where-Object { $_.TimedOut -eq $true     }).Count

    Write-Log -Level Information -Message "Executor complete: Completed=$successCount Errors=$errorCount Timeouts=$timeoutCount"

    return $results
}
