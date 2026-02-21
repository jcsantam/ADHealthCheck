<#
.SYNOPSIS
    Centralized logging system for AD Health Check

.DESCRIPTION
    Provides comprehensive logging capabilities including:
    - Multiple log levels (Verbose, Information, Warning, Error)
    - Console and file output
    - Structured log entries with timestamps
    - Automatic log rotation
    - Log filtering by level

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    All functions are thread-safe for parallel execution
#>

# =============================================================================
# MODULE VARIABLES
# =============================================================================

# Global log configuration (initialized by Initialize-Logger)
$script:LogConfig = @{
    LogLevel = 'Information'
    LogToConsole = $true
    LogToFile = $true
    LogFilePath = $null
    MaxLogSizeMB = 50
    MaxLogFiles = 10
    IsInitialized = $false
}

# Log level hierarchy (lower number = higher priority)
$script:LogLevels = @{
    'Verbose' = 0
    'Information' = 1
    'Warning' = 2
    'Error' = 3
}

# Thread-safe mutex for file writing
$script:LogMutex = $null

# =============================================================================
# FUNCTION: Initialize-Logger
# Purpose: Initialize the logging system with configuration
# =============================================================================
function Initialize-Logger {
    <#
    .SYNOPSIS
        Initializes the logging system
    
    .PARAMETER LogLevel
        Minimum log level to capture (Verbose, Information, Warning, Error)
    
    .PARAMETER LogToConsole
        Enable console output
    
    .PARAMETER LogToFile
        Enable file output
    
    .PARAMETER LogFilePath
        Path to log file. If not specified, uses default location.
    
    .PARAMETER MaxLogSizeMB
        Maximum size of log file in MB before rotation
    
    .PARAMETER MaxLogFiles
        Maximum number of rotated log files to keep
    
    .EXAMPLE
        Initialize-Logger -LogLevel Information -LogFilePath "C:\Logs\healthcheck.log"
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
        [string]$LogLevel = 'Information',
        
        [Parameter(Mandatory = $false)]
        [bool]$LogToConsole = $true,
        
        [Parameter(Mandatory = $false)]
        [bool]$LogToFile = $true,
        
        [Parameter(Mandatory = $false)]
        [string]$LogFilePath = $null,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxLogSizeMB = 50,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxLogFiles = 10
    )
    
    # Set default log file path if not specified
    if ([string]::IsNullOrEmpty($LogFilePath)) {
        $outputDir = Join-Path $PSScriptRoot "..\Output\logs"
        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        $LogFilePath = Join-Path $outputDir "healthcheck_$(Get-Date -Format 'yyyyMMdd').log"
    }
    
    # Update configuration
    $script:LogConfig.LogLevel = $LogLevel
    $script:LogConfig.LogToConsole = $LogToConsole
    $script:LogConfig.LogToFile = $LogToFile
    $script:LogConfig.LogFilePath = $LogFilePath
    $script:LogConfig.MaxLogSizeMB = $MaxLogSizeMB
    $script:LogConfig.MaxLogFiles = $MaxLogFiles
    $script:LogConfig.IsInitialized = $true
    
    # Create mutex for thread-safe file writing
    $script:LogMutex = New-Object System.Threading.Mutex($false, "ADHealthCheckLogMutex")
    
    # Create log file directory if it doesn't exist
    $logDir = Split-Path $LogFilePath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    
    # Write initialization message
    Write-Log -Message "Logger initialized - Level: $LogLevel, File: $LogFilePath" -Level Information
}

# =============================================================================
# FUNCTION: Write-Log
# Purpose: Main logging function - writes to console and/or file
# =============================================================================
function Write-Log {
    <#
    .SYNOPSIS
        Writes a log entry to console and/or file
    
    .PARAMETER Message
        The message to log
    
    .PARAMETER Level
        Log level (Verbose, Information, Warning, Error)
    
    .PARAMETER Category
        Optional category for the log entry (e.g., "Discovery", "Execution")
    
    .PARAMETER Exception
        Optional exception object to include details
    
    .EXAMPLE
        Write-Log -Message "Starting health check" -Level Information
    
    .EXAMPLE
        Write-Log -Message "Check failed" -Level Error -Category "Execution" -Exception $_.Exception
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
        [string]$Level = 'Information',
        
        [Parameter(Mandatory = $false)]
        [string]$Category = '',
        
        [Parameter(Mandatory = $false)]
        [System.Exception]$Exception = $null
    )
    
    # Initialize logger if not already done
    if (-not $script:LogConfig.IsInitialized) {
        Initialize-Logger
    }
    
    # Check if this message should be logged based on current log level
    $currentLevelValue = $script:LogLevels[$script:LogConfig.LogLevel]
    $messageLevelValue = $script:LogLevels[$Level]
    
    if ($messageLevelValue -lt $currentLevelValue) {
        # Message level is below minimum threshold, skip logging
        return
    }
    
    # Build log entry
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $threadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    
    # Format category if provided
    $categoryText = if ($Category) { "[$Category] " } else { "" }
    
    # Build main log message
    $logMessage = "[$timestamp] [$Level] [Thread:$threadId] $categoryText$Message"
    
    # Add exception details if provided
    if ($Exception) {
        $logMessage += "`n    Exception: $($Exception.GetType().Name)"
        $logMessage += "`n    Message: $($Exception.Message)"
        if ($Exception.InnerException) {
            $logMessage += "`n    Inner Exception: $($Exception.InnerException.Message)"
        }
    }
    
    # Write to console if enabled
    if ($script:LogConfig.LogToConsole) {
        Write-LogToConsole -Message $logMessage -Level $Level
    }
    
    # Write to file if enabled
    if ($script:LogConfig.LogToFile) {
        Write-LogToFile -Message $logMessage
    }
}

# =============================================================================
# FUNCTION: Write-LogToConsole
# Purpose: Write log entry to console with color coding
# =============================================================================
function Write-LogToConsole {
    <#
    .SYNOPSIS
        Internal function to write log to console with color coding
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $true)]
        [string]$Level
    )
    
    # Determine console color based on log level
    $color = switch ($Level) {
        'Verbose'     { 'Gray' }
        'Information' { 'White' }
        'Warning'     { 'Yellow' }
        'Error'       { 'Red' }
        default       { 'White' }
    }
    
    # Write to console
    Write-Host $Message -ForegroundColor $color
}

# =============================================================================
# FUNCTION: Write-LogToFile
# Purpose: Write log entry to file (thread-safe)
# =============================================================================
function Write-LogToFile {
    <#
    .SYNOPSIS
        Internal function to write log to file (thread-safe)
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    
    try {
        # Check if log rotation is needed
        if (Test-Path $script:LogConfig.LogFilePath) {
            $logFileSize = (Get-Item $script:LogConfig.LogFilePath).Length / 1MB
            if ($logFileSize -ge $script:LogConfig.MaxLogSizeMB) {
                Invoke-LogRotation
            }
        }
        
        # Acquire mutex for thread-safe file writing
        $script:LogMutex.WaitOne() | Out-Null
        
        try {
            # Append to log file
            Add-Content -Path $script:LogConfig.LogFilePath -Value $Message -Encoding UTF8
        }
        finally {
            # Always release mutex
            $script:LogMutex.ReleaseMutex()
        }
    }
    catch {
        # If file logging fails, write to console as fallback
        Write-Host "Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# =============================================================================
# FUNCTION: Invoke-LogRotation
# Purpose: Rotate log files when max size is reached
# =============================================================================
function Invoke-LogRotation {
    <#
    .SYNOPSIS
        Internal function to rotate log files
    #>
    
    [CmdletBinding()]
    param()
    
    try {
        $logFile = $script:LogConfig.LogFilePath
        $logDir = Split-Path $logFile -Parent
        $logName = [System.IO.Path]::GetFileNameWithoutExtension($logFile)
        $logExt = [System.IO.Path]::GetExtension($logFile)
        
        # Get existing rotated logs
        $existingLogs = Get-ChildItem -Path $logDir -Filter "$logName*$logExt" |
            Where-Object { $_.Name -match "$logName\.(\d+)$logExt" } |
            Sort-Object Name -Descending
        
        # Delete oldest logs if exceeding max count
        if ($existingLogs.Count -ge $script:LogConfig.MaxLogFiles) {
            $logsToDelete = $existingLogs | Select-Object -Skip ($script:LogConfig.MaxLogFiles - 1)
            foreach ($log in $logsToDelete) {
                Remove-Item -Path $log.FullName -Force
            }
        }
        
        # Increment existing log numbers
        foreach ($log in $existingLogs) {
            if ($log.Name -match "$logName\.(\d+)$logExt") {
                $currentNum = [int]$matches[1]
                $newNum = $currentNum + 1
                $newName = "$logName.$newNum$logExt"
                $newPath = Join-Path $logDir $newName
                Move-Item -Path $log.FullName -Destination $newPath -Force
            }
        }
        
        # Rename current log to .1
        $rotatedPath = Join-Path $logDir "$logName.1$logExt"
        Move-Item -Path $logFile -Destination $rotatedPath -Force
        
        Write-LogToConsole -Message "Log file rotated: $rotatedPath" -Level Information
    }
    catch {
        Write-LogToConsole -Message "Log rotation failed: $($_.Exception.Message)" -Level Warning
    }
}

# =============================================================================
# FUNCTION: Get-LogConfiguration
# Purpose: Get current logger configuration
# =============================================================================
function Get-LogConfiguration {
    <#
    .SYNOPSIS
        Returns current logger configuration
    
    .EXAMPLE
        $config = Get-LogConfiguration
    #>
    
    return $script:LogConfig.Clone()
}

# =============================================================================
# FUNCTION: Set-LogLevel
# Purpose: Change log level at runtime
# =============================================================================
function Set-LogLevel {
    <#
    .SYNOPSIS
        Changes the minimum log level
    
    .PARAMETER Level
        New log level (Verbose, Information, Warning, Error)
    
    .EXAMPLE
        Set-LogLevel -Level Verbose
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Verbose', 'Information', 'Warning', 'Error')]
        [string]$Level
    )
    
    $oldLevel = $script:LogConfig.LogLevel
    $script:LogConfig.LogLevel = $Level
    
    Write-Log -Message "Log level changed from $oldLevel to $Level" -Level Information
}

# =============================================================================
# CONVENIENCE FUNCTIONS - Shortcuts for common logging operations
# =============================================================================

function Write-LogVerbose {
    <#
    .SYNOPSIS
        Writes a verbose log entry
    #>
    param([string]$Message, [string]$Category = '')
    Write-Log -Message $Message -Level Verbose -Category $Category
}

function Write-LogInfo {
    <#
    .SYNOPSIS
        Writes an informational log entry
    #>
    param([string]$Message, [string]$Category = '')
    Write-Log -Message $Message -Level Information -Category $Category
}

function Write-LogWarning {
    <#
    .SYNOPSIS
        Writes a warning log entry
    #>
    param([string]$Message, [string]$Category = '')
    Write-Log -Message $Message -Level Warning -Category $Category
}

function Write-LogError {
    <#
    .SYNOPSIS
        Writes an error log entry
    #>
    param([string]$Message, [string]$Category = '', [System.Exception]$Exception = $null)
    Write-Log -Message $Message -Level Error -Category $Category -Exception $Exception
}

# =============================================================================
# FUNCTION: Close-Logger
# Purpose: Cleanup logger resources
# =============================================================================
function Close-Logger {
    <#
    .SYNOPSIS
        Closes the logger and releases resources
    
    .EXAMPLE
        Close-Logger
    #>
    
    if ($script:LogMutex) {
        $script:LogMutex.Dispose()
        $script:LogMutex = $null
    }
    
    Write-LogToConsole -Message "Logger closed" -Level Information
    
    $script:LogConfig.IsInitialized = $false
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================

Export-ModuleMember -Function @(
    'Initialize-Logger',
    'Write-Log',
    'Get-LogConfiguration',
    'Set-LogLevel',
    'Write-LogVerbose',
    'Write-LogInfo',
    'Write-LogWarning',
    'Write-LogError',
    'Close-Logger'
)
