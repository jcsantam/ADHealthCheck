<#
.SYNOPSIS
    Database operations module for AD Health Check

.DESCRIPTION
    Provides CRUD operations for SQLite database:
    - Connection management
    - Run management
    - Check results storage
    - Issue tracking
    - Score persistence
    - Query helpers

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Requires: System.Data.SQLite
#>

# =============================================================================
# MODULE VARIABLES
# =============================================================================

# Active database connection (module-scoped)
$script:ActiveConnection = $null

# =============================================================================
# FUNCTION: Initialize-DatabaseConnection
# Purpose: Create and open database connection
# =============================================================================
function Initialize-DatabaseConnection {
    <#
    .SYNOPSIS
        Opens a connection to the SQLite database
    
    .PARAMETER DatabasePath
        Path to the SQLite database file
    
    .EXAMPLE
        $conn = Initialize-DatabaseConnection -DatabasePath ".\healthcheck.db"
    
    .OUTPUTS
        SQLite connection object
    #>
    
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )
    
    try {
        # Load SQLite assembly if not already loaded
        try {
            Add-Type -AssemblyName System.Data.SQLite -ErrorAction Stop
        }
        catch {
            throw "System.Data.SQLite not found. Run Initialize-Database.ps1 first."
        }
        
        # Verify database file exists
        if (-not (Test-Path $DatabasePath)) {
            throw "Database file not found: $DatabasePath. Run Initialize-Database.ps1 first."
        }
        
        # Create connection string
        $connectionString = "Data Source=$DatabasePath;Version=3;"
        
        # Create and open connection
        $connection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
        $connection.Open()
        
        # Store in module variable
        $script:ActiveConnection = $connection
        
        Write-Verbose "Database connection opened: $DatabasePath"
        
        return $connection
    }
    catch {
        Write-Error "Failed to connect to database: $($_.Exception.Message)"
        throw
    }
}

# =============================================================================
# FUNCTION: Close-DatabaseConnection
# Purpose: Close database connection
# =============================================================================
function Close-DatabaseConnection {
    <#
    .SYNOPSIS
        Closes the database connection
    
    .PARAMETER Connection
        Connection object to close (uses module connection if not specified)
    #>
    
    param(
        [Parameter(Mandatory = $false)]
        $Connection = $null
    )
    
    $connToClose = if ($Connection) { $Connection } else { $script:ActiveConnection }
    
    if ($connToClose -and $connToClose.State -eq 'Open') {
        $connToClose.Close()
        $connToClose.Dispose()
        Write-Verbose "Database connection closed"
    }
    
    $script:ActiveConnection = $null
}

# =============================================================================
# FUNCTION: Invoke-DatabaseCommand
# Purpose: Execute SQL command against database
# =============================================================================
function Invoke-DatabaseCommand {
    <#
    .SYNOPSIS
        Executes a SQL command against the database
    
    .PARAMETER Connection
        Database connection
    
    .PARAMETER CommandText
        SQL command to execute
    
    .PARAMETER Parameters
        Hashtable of parameters for the command
    
    .EXAMPLE
        Invoke-DatabaseCommand -Connection $conn -CommandText "SELECT * FROM Runs WHERE RunId = @RunId" -Parameters @{ RunId = $runId }
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        
        [Parameter(Mandatory = $true)]
        [string]$CommandText,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{}
    )
    
    try {
        $command = $Connection.CreateCommand()
        $command.CommandText = $CommandText
        
        # Add parameters
        foreach ($key in $Parameters.Keys) {
            $paramValue = $Parameters[$key]
            # Handle null values
            if ($null -eq $paramValue) {
                $paramValue = [System.DBNull]::Value
            }
            [void]$command.Parameters.AddWithValue("@$key", $paramValue)
        }
        
        # Execute and return affected rows
        $rowsAffected = $command.ExecuteNonQuery()
        
        return $rowsAffected
    }
    catch {
        Write-Error "Database command failed: $($_.Exception.Message)"
        Write-Error "SQL: $CommandText"
        throw
    }
    finally {
        if ($command) {
            $command.Dispose()
        }
    }
}

# =============================================================================
# FUNCTION: Invoke-DatabaseQuery
# Purpose: Execute query and return results
# =============================================================================
function Invoke-DatabaseQuery {
    <#
    .SYNOPSIS
        Executes a query and returns results as objects
    
    .PARAMETER Connection
        Database connection
    
    .PARAMETER Query
        SQL query to execute
    
    .PARAMETER Parameters
        Hashtable of parameters
    
    .EXAMPLE
        $runs = Invoke-DatabaseQuery -Connection $conn -Query "SELECT * FROM Runs"
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        
        [Parameter(Mandatory = $true)]
        [string]$Query,
        
        [Parameter(Mandatory = $false)]
        [hashtable]$Parameters = @{}
    )
    
    try {
        $command = $Connection.CreateCommand()
        $command.CommandText = $Query
        
        # Add parameters
        foreach ($key in $Parameters.Keys) {
            $paramValue = $Parameters[$key]
            if ($null -eq $paramValue) {
                $paramValue = [System.DBNull]::Value
            }
            [void]$command.Parameters.AddWithValue("@$key", $paramValue)
        }
        
        $reader = $command.ExecuteReader()
        $results = @()
        
        while ($reader.Read()) {
            $row = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $columnName = $reader.GetName($i)
                $value = $reader.GetValue($i)
                
                # Convert DBNull to $null
                if ($value -is [System.DBNull]) {
                    $value = $null
                }
                
                $row[$columnName] = $value
            }
            $results += [PSCustomObject]$row
        }
        
        $reader.Close()
        
        return $results
    }
    catch {
        Write-Error "Database query failed: $($_.Exception.Message)"
        Write-Error "SQL: $Query"
        throw
    }
    finally {
        if ($command) {
            $command.Dispose()
        }
    }
}

# =============================================================================
# FUNCTION: New-RunRecord
# Purpose: Create a new run record
# =============================================================================
function New-RunRecord {
    <#
    .SYNOPSIS
        Creates a new run record in the database
    
    .PARAMETER Connection
        Database connection
    
    .PARAMETER RunId
        Unique run identifier
    
    .PARAMETER ForestName
        AD forest name
    
    .PARAMETER DomainName
        Domain name
    
    .EXAMPLE
        New-RunRecord -Connection $conn -RunId $runId -ForestName "contoso.com" -DomainName "contoso.com"
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        
        [Parameter(Mandatory = $true)]
        [string]$RunId,
        
        [Parameter(Mandatory = $true)]
        [string]$ForestName,
        
        [Parameter(Mandatory = $true)]
        [string]$DomainName
    )
    
    $sql = @"
INSERT INTO Runs (
    RunId, StartTime, ForestName, DomainName, 
    ExecutedBy, ExecutionHost, Status
) VALUES (
    @RunId, @StartTime, @ForestName, @DomainName,
    @ExecutedBy, @ExecutionHost, @Status
)
"@
    
    $params = @{
        RunId = $RunId
        StartTime = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        ForestName = $ForestName
        DomainName = $DomainName
        ExecutedBy = $env:USERNAME
        ExecutionHost = $env:COMPUTERNAME
        Status = 'Running'
    }
    
    Invoke-DatabaseCommand -Connection $Connection -CommandText $sql -Parameters $params
    
    Write-Verbose "Created run record: $RunId"
}

# =============================================================================
# FUNCTION: Update-RunRecord
# Purpose: Update run record with final status and stats
# =============================================================================
function Update-RunRecord {
    <#
    .SYNOPSIS
        Updates a run record with completion information
    
    .PARAMETER Connection
        Database connection
    
    .PARAMETER Summary
        Run summary object with statistics
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        
        [Parameter(Mandatory = $true)]
        $Summary
    )
    
    $sql = @"
UPDATE Runs SET
    EndTime = @EndTime,
    Status = @Status,
    OverallScore = @OverallScore,
    TotalChecks = @TotalChecks,
    PassedChecks = @PassedChecks,
    WarningChecks = @WarningChecks,
    FailedChecks = @FailedChecks,
    CriticalIssues = @CriticalIssues,
    HighIssues = @HighIssues,
    MediumIssues = @MediumIssues,
    LowIssues = @LowIssues
WHERE RunId = @RunId
"@
    
    $params = @{
        RunId = $Summary.RunId
        EndTime = $Summary.EndTime.ToString("yyyy-MM-ddTHH:mm:ss")
        Status = $Summary.Status
        OverallScore = $Summary.OverallScore
        TotalChecks = $Summary.TotalChecks
        PassedChecks = $Summary.PassedChecks
        WarningChecks = $Summary.WarningChecks
        FailedChecks = $Summary.FailedChecks
        CriticalIssues = $Summary.CriticalIssues
        HighIssues = $Summary.HighIssues
        MediumIssues = $Summary.MediumIssues
        LowIssues = $Summary.LowIssues
    }
    
    Invoke-DatabaseCommand -Connection $Connection -CommandText $sql -Parameters $params
    
    Write-Verbose "Updated run record: $($Summary.RunId)"
}

# =============================================================================
# FUNCTION: Save-CheckResult
# Purpose: Save individual check result
# =============================================================================
function Save-CheckResult {
    <#
    .SYNOPSIS
        Saves a check result to the database
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        
        [Parameter(Mandatory = $true)]
        [string]$RunId,
        
        [Parameter(Mandatory = $true)]
        $Result
    )
    
    $sql = @"
INSERT INTO CheckResults (
    ResultId, RunId, CheckId, StartTime, EndTime, DurationMs,
    Status, ExitCode, RawOutput, ProcessedOutput, ErrorMessage
) VALUES (
    @ResultId, @RunId, @CheckId, @StartTime, @EndTime, @DurationMs,
    @Status, @ExitCode, @RawOutput, @ProcessedOutput, @ErrorMessage
)
"@
    
    $params = @{
        ResultId = [Guid]::NewGuid().ToString()
        RunId = $RunId
        CheckId = $Result.CheckId
        StartTime = $Result.StartTime.ToString("yyyy-MM-ddTHH:mm:ss")
        EndTime = if ($Result.EndTime) { $Result.EndTime.ToString("yyyy-MM-ddTHH:mm:ss") } else { $null }
        DurationMs = $Result.DurationMs
        Status = $Result.EvaluationStatus
        ExitCode = if ($Result.ExitCode) { $Result.ExitCode } else { 0 }
        RawOutput = if ($Result.RawOutput) { ($Result.RawOutput | ConvertTo-Json -Compress -Depth 5) } else { $null }
        ProcessedOutput = if ($Result.ProcessedOutput) { ($Result.ProcessedOutput | ConvertTo-Json -Compress -Depth 5) } else { $null }
        ErrorMessage = $Result.ErrorMessage
    }
    
    Invoke-DatabaseCommand -Connection $Connection -CommandText $sql -Parameters $params
}

# =============================================================================
# FUNCTION: Save-Issue
# Purpose: Save detected issue
# =============================================================================
function Save-Issue {
    <#
    .SYNOPSIS
        Saves an issue to the database
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        
        [Parameter(Mandatory = $true)]
        [string]$RunId,
        
        [Parameter(Mandatory = $true)]
        [string]$ResultId,
        
        [Parameter(Mandatory = $true)]
        [string]$CheckId,
        
        [Parameter(Mandatory = $true)]
        $Issue
    )
    
    $sql = @"
INSERT INTO Issues (
    IssueId, RunId, ResultId, CheckId, Severity, Status,
    Title, Description, AffectedObject, Evidence, Recommendation,
    FirstDetected, LastDetected
) VALUES (
    @IssueId, @RunId, @ResultId, @CheckId, @Severity, @Status,
    @Title, @Description, @AffectedObject, @Evidence, @Recommendation,
    @FirstDetected, @LastDetected
)
"@
    
    $now = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    
    $params = @{
        IssueId = $Issue.IssueId
        RunId = $RunId
        ResultId = $ResultId
        CheckId = $CheckId
        Severity = $Issue.Severity
        Status = 'Open'
        Title = $Issue.Title
        Description = $Issue.Description
        AffectedObject = $Issue.AffectedObject
        Evidence = if ($Issue.Evidence) { ($Issue.Evidence | ConvertTo-Json -Compress -Depth 5) } else { $null }
        Recommendation = $Issue.Recommendation
        FirstDetected = $now
        LastDetected = $now
    }
    
    Invoke-DatabaseCommand -Connection $Connection -CommandText $sql -Parameters $params
}

# =============================================================================
# FUNCTION: Save-Score
# Purpose: Save health score
# =============================================================================
function Save-Score {
    <#
    .SYNOPSIS
        Saves a health score to the database
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        
        [Parameter(Mandatory = $true)]
        [string]$RunId,
        
        [Parameter(Mandatory = $false)]
        [string]$CategoryId = $null,
        
        [Parameter(Mandatory = $true)]
        [int]$ScoreValue,
        
        [Parameter(Mandatory = $false)]
        [int]$ChecksExecuted = 0,
        
        [Parameter(Mandatory = $false)]
        [int]$ChecksPassed = 0
    )
    
    $sql = @"
INSERT INTO Scores (
    RunId, CategoryId, ScoreValue, MaxPossible, ChecksExecuted, ChecksPassed
) VALUES (
    @RunId, @CategoryId, @ScoreValue, @MaxPossible, @ChecksExecuted, @ChecksPassed
)
"@
    
    $params = @{
        RunId = $RunId
        CategoryId = $CategoryId
        ScoreValue = $ScoreValue
        MaxPossible = 100
        ChecksExecuted = $ChecksExecuted
        ChecksPassed = $ChecksPassed
    }
    
    Invoke-DatabaseCommand -Connection $Connection -CommandText $sql -Parameters $params
}

# =============================================================================
# FUNCTION: Save-InventoryItem
# Purpose: Save discovered inventory item
# =============================================================================
function Save-InventoryItem {
    <#
    .SYNOPSIS
        Saves an inventory item to the database
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        
        [Parameter(Mandatory = $true)]
        [string]$RunId,
        
        [Parameter(Mandatory = $true)]
        [string]$ItemType,
        
        [Parameter(Mandatory = $true)]
        [string]$ItemName,
        
        [Parameter(Mandatory = $false)]
        [string]$ParentItem = $null,
        
        [Parameter(Mandatory = $false)]
        $Properties = $null
    )
    
    $sql = @"
INSERT INTO Inventory (
    RunId, ItemType, ItemName, ParentItem, Properties
) VALUES (
    @RunId, @ItemType, @ItemName, @ParentItem, @Properties
)
"@
    
    $params = @{
        RunId = $RunId
        ItemType = $ItemType
        ItemName = $ItemName
        ParentItem = $ParentItem
        Properties = if ($Properties) { ($Properties | ConvertTo-Json -Compress -Depth 5) } else { $null }
    }
    
    Invoke-DatabaseCommand -Connection $Connection -CommandText $sql -Parameters $params
}

# =============================================================================
# EXPORT MODULE MEMBERS
# =============================================================================



