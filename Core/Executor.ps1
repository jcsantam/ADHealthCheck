<#
.SYNOPSIS
    Parallel check execution engine

.DESCRIPTION
    Executes health checks in parallel using PowerShell Runspaces for optimal performance.
    Features:
    - Configurable parallel job limit
    - Timeout handling per check
    - Progress tracking
    - Error isolation (one check failure doesn't affect others)
    - Result aggregation

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Uses RunspacePool for efficient parallel execution
#>

# Import logger if available
if (Test-Path "$PSScriptRoot\Logger.ps1") {
    . "$PSScriptRoot\Logger.ps1"
}

# =============================================================================
# FUNCTION: Invoke-ParallelCheckExecution
# Purpose: Execute multiple checks in parallel using runspace pool
# =============================================================================
function Invoke-ParallelCheckExecution {
    <#
    .SYNOPSIS
        Executes health checks in parallel
    
    .PARAMETER CheckDefinitions
        Array of check definition objects to execute
    
    .PARAMETER Inventory
        Discovered AD inventory to pass to checks
    
    .PARAMETER MaxParallelJobs
        Maximum number of parallel jobs (default: 10)
    
    .PARAMETER ExecutionTimeout
        Timeout in seconds for each check (default: 300)
    
    .EXAMPLE
        $results = Invoke-ParallelCheckExecution -CheckDefinitions $checks -Inventory $inventory
    
    .OUTPUTS
        Array of check execution results
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$CheckDefinitions,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Inventory,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxParallelJobs = 10,
        
        [Parameter(Mandatory = $false)]
        [int]$ExecutionTimeout = 300
    )
    
    Write-LogInfo "Starting parallel check execution" -Category "Executor"
    Write-LogInfo "  Total checks: $($CheckDefinitions.Count)" -Category "Executor"
    Write-LogInfo "  Max parallel jobs: $MaxParallelJobs" -Category "Executor"
    Write-LogInfo "  Execution timeout: ${ExecutionTimeout}s" -Category "Executor"
    
    $executionStart = Get-Date
    
    try {
        # Create runspace pool
        Write-LogVerbose "Creating runspace pool..." -Category "Executor"
        $runspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxParallelJobs)
        $runspacePool.Open()
        
        # Array to track all jobs
        $jobs = @()
        
        # Submit all checks to runspace pool
        foreach ($check in $CheckDefinitions) {
            Write-LogVerbose "Submitting check: $($check.CheckId) - $($check.CheckName)" -Category "Executor"
            
            # Create PowerShell instance
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $runspacePool
            
            # Add script block to execute the check
            [void]$ps.AddScript({
                param($CheckDef, $InvData, $Timeout)
                
                $result = [PSCustomObject]@{
                    CheckId = $CheckDef.CheckId
                    CheckName = $CheckDef.CheckName
                    CategoryId = $CheckDef.CategoryId
                    StartTime = Get-Date
                    EndTime = $null
                    DurationMs = $null
                    Status = 'Unknown'
                    ExitCode = 0
                    RawOutput = $null
                    ErrorMessage = $null
                    TimedOut = $false
                }
                
                try {
                    # Verify script exists
                    if (-not (Test-Path $CheckDef.ScriptPath)) {
                        throw "Check script not found: $($CheckDef.ScriptPath)"
                    }
                    
                    # Execute check script with timeout
                    $job = Start-Job -ScriptBlock {
                        param($ScriptPath, $Inventory)
                        & $ScriptPath -Inventory $Inventory
                    } -ArgumentList $CheckDef.ScriptPath, $InvData
                    
                    # Wait for completion or timeout
                    $completed = Wait-Job -Job $job -Timeout $Timeout
                    
                    if ($completed) {
                        # Job completed within timeout
                        $result.RawOutput = Receive-Job -Job $job
                        $result.Status = 'Completed'
                        $result.ExitCode = 0
                    }
                    else {
                        # Job timed out
                        Stop-Job -Job $job
                        $result.Status = 'Error'
                        $result.ErrorMessage = "Check execution timed out after ${Timeout} seconds"
                        $result.TimedOut = $true
                        $result.ExitCode = -1
                    }
                    
                    Remove-Job -Job $job -Force
                }
                catch {
                    $result.Status = 'Error'
                    $result.ErrorMessage = $_.Exception.Message
                    $result.ExitCode = 1
                }
                finally {
                    $result.EndTime = Get-Date
                    $result.DurationMs = ($result.EndTime - $result.StartTime).TotalMilliseconds
                }
                
                return $result
            })
            
            # Add parameters
            [void]$ps.AddParameter('CheckDef', $check)
            [void]$ps.AddParameter('InvData', $Inventory)
            [void]$ps.AddParameter('Timeout', $ExecutionTimeout)
            
            # Start execution
            $handle = $ps.BeginInvoke()
            
            # Track job
            $jobs += [PSCustomObject]@{
                PowerShell = $ps
                Handle = $handle
                CheckId = $check.CheckId
                CheckName = $check.CheckName
                StartTime = Get-Date
            }
        }
        
        Write-LogInfo "All checks submitted to runspace pool" -Category "Executor"
        Write-LogInfo "Waiting for checks to complete..." -Category "Executor"
        
        # Collect results as they complete
        $results = @()
        $completedCount = 0
        $totalChecks = $jobs.Count
        
        foreach ($job in $jobs) {
            try {
                # Wait for this job to complete
                $result = $job.PowerShell.EndInvoke($job.Handle)
                
                # Add result to collection
                $results += $result
                
                $completedCount++
                $percentComplete = [math]::Round(($completedCount / $totalChecks) * 100, 0)
                
                # Log progress
                if ($result.Status -eq 'Completed') {
                    Write-LogVerbose "[$percentComplete%] Completed: $($result.CheckId) - Duration: $([math]::Round($result.DurationMs / 1000, 2))s" -Category "Executor"
                }
                elseif ($result.TimedOut) {
                    Write-LogWarning "[$percentComplete%] Timed out: $($result.CheckId)" -Category "Executor"
                }
                else {
                    Write-LogWarning "[$percentComplete%] Failed: $($result.CheckId) - Error: $($result.ErrorMessage)" -Category "Executor"
                }
            }
            catch {
                Write-LogError "Failed to collect result for check $($job.CheckId): $($_.Exception.Message)" -Category "Executor"
                
                # Create error result
                $results += [PSCustomObject]@{
                    CheckId = $job.CheckId
                    CheckName = $job.CheckName
                    StartTime = $job.StartTime
                    EndTime = Get-Date
                    DurationMs = ((Get-Date) - $job.StartTime).TotalMilliseconds
                    Status = 'Error'
                    ExitCode = 1
                    RawOutput = $null
                    ErrorMessage = $_.Exception.Message
                    TimedOut = $false
                }
            }
            finally {
                # Clean up PowerShell instance
                $job.PowerShell.Dispose()
            }
        }
        
        # Close runspace pool
        $runspacePool.Close()
        $runspacePool.Dispose()
        
        # Calculate execution summary
        $executionDuration = ((Get-Date) - $executionStart).TotalSeconds
        $successCount = @($results | Where-Object { $_.Status -eq 'Completed' }).Count
        $errorCount = @($results | Where-Object { $_.Status -eq 'Error' }).Count
        $timeoutCount = @($results | Where-Object { $_.TimedOut -eq $true }).Count
        
        Write-LogInfo "Parallel execution completed" -Category "Executor"
        Write-LogInfo "  Total checks: $totalChecks" -Category "Executor"
        Write-LogInfo "  Successful: $successCount" -Category "Executor"
        Write-LogInfo "  Errors: $errorCount" -Category "Executor"
        Write-LogInfo "  Timeouts: $timeoutCount" -Category "Executor"
        Write-LogInfo "  Total duration: $([math]::Round($executionDuration, 2))s" -Category "Executor"
        Write-LogInfo "  Average per check: $([math]::Round($executionDuration / $totalChecks, 2))s" -Category "Executor"
        
        return $results
    }
    catch {
        Write-LogError "Parallel execution failed: $($_.Exception.Message)" -Category "Executor" -Exception $_.Exception
        throw
    }
}

# =============================================================================
# FUNCTION: Invoke-SequentialCheckExecution
# Purpose: Execute checks sequentially (fallback if parallel fails)
# =============================================================================
function Invoke-SequentialCheckExecution {
    <#
    .SYNOPSIS
        Executes health checks sequentially (one at a time)
    
    .DESCRIPTION
        Fallback execution method if parallel execution is not available
        or fails. Slower but more reliable.
    
    .PARAMETER CheckDefinitions
        Array of check definition objects to execute
    
    .PARAMETER Inventory
        Discovered AD inventory to pass to checks
    
    .PARAMETER ExecutionTimeout
        Timeout in seconds for each check
    
    .EXAMPLE
        $results = Invoke-SequentialCheckExecution -CheckDefinitions $checks -Inventory $inventory
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$CheckDefinitions,
        
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$Inventory,
        
        [Parameter(Mandatory = $false)]
        [int]$ExecutionTimeout = 300
    )
    
    Write-LogInfo "Starting sequential check execution" -Category "Executor"
    Write-LogInfo "  Total checks: $($CheckDefinitions.Count)" -Category "Executor"
    
    $results = @()
    $completedCount = 0
    $totalChecks = $CheckDefinitions.Count
    
    foreach ($check in $CheckDefinitions) {
        $result = [PSCustomObject]@{
            CheckId = $check.CheckId
            CheckName = $check.CheckName
            CategoryId = $check.CategoryId
            StartTime = Get-Date
            EndTime = $null
            DurationMs = $null
            Status = 'Unknown'
            ExitCode = 0
            RawOutput = $null
            ErrorMessage = $null
            TimedOut = $false
        }
        
        try {
            Write-LogVerbose "Executing check: $($check.CheckId) - $($check.CheckName)" -Category "Executor"
            
            # Verify script exists
            if (-not (Test-Path $check.ScriptPath)) {
                throw "Check script not found: $($check.ScriptPath)"
            }
            
            # Execute check script with timeout
            $job = Start-Job -ScriptBlock {
                param($ScriptPath, $Inventory)
                & $ScriptPath -Inventory $Inventory
            } -ArgumentList $check.ScriptPath, $Inventory
            
            # Wait for completion or timeout
            $completed = Wait-Job -Job $job -Timeout $ExecutionTimeout
            
            if ($completed) {
                # Job completed within timeout
                $result.RawOutput = Receive-Job -Job $job
                $result.Status = 'Completed'
                $result.ExitCode = 0
            }
            else {
                # Job timed out
                Stop-Job -Job $job
                $result.Status = 'Error'
                $result.ErrorMessage = "Check execution timed out after ${ExecutionTimeout} seconds"
                $result.TimedOut = $true
                $result.ExitCode = -1
            }
            
            Remove-Job -Job $job -Force
        }
        catch {
            $result.Status = 'Error'
            $result.ErrorMessage = $_.Exception.Message
            $result.ExitCode = 1
            Write-LogWarning "Check failed: $($check.CheckId) - $($_.Exception.Message)" -Category "Executor"
        }
        finally {
            $result.EndTime = Get-Date
            $result.DurationMs = ($result.EndTime - $result.StartTime).TotalMilliseconds
        }
        
        $results += $result
        $completedCount++
        
        $percentComplete = [math]::Round(($completedCount / $totalChecks) * 100, 0)
        Write-LogInfo "[$percentComplete%] Completed check: $($check.CheckId)" -Category "Executor"
    }
    
    Write-LogInfo "Sequential execution completed" -Category "Executor"
    
    return $results
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================



