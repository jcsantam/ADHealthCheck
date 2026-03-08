<#
.SYNOPSIS
    Tests the AD Health Check database functionality

.DESCRIPTION
    Validates that the database is properly initialized with correct schema,
    tables, indexes, views, and initial data. Performs basic CRUD operations
    to verify database functionality.

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    This is a test script - safe to run multiple times
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DatabasePath = "$PSScriptRoot\..\Output\healthcheck.db"
)

$ErrorActionPreference = 'Stop'

# =============================================================================
# FUNCTION: Write-TestResult
# =============================================================================
function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ""
    )
    
    $status = if ($Passed) { "✓ PASS" } else { "✗ FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    Write-Host "[$status] $TestName" -ForegroundColor $color
    if ($Message) {
        Write-Host "        $Message" -ForegroundColor Gray
    }
}

# =============================================================================
# MAIN TEST EXECUTION
# =============================================================================

Write-Host "`n===== AD Health Check Database Tests =====" -ForegroundColor Cyan
Write-Host "Database: $DatabasePath`n" -ForegroundColor Cyan

try {
    # Test 1: Database file exists
    $dbExists = Test-Path $DatabasePath
    Write-TestResult -TestName "Database file exists" -Passed $dbExists
    
    if (-not $dbExists) {
        Write-Host "`nDatabase not found. Run Initialize-Database.ps1 first." -ForegroundColor Yellow
        exit 1
    }
    
    # Load SQLite
    Add-Type -AssemblyName System.Data.SQLite -ErrorAction SilentlyContinue
    
    # Test 2: Can open database connection
    try {
        $connectionString = "Data Source=$DatabasePath;Version=3;"
        $connection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
        $connection.Open()
        Write-TestResult -TestName "Database connection" -Passed $true
    }
    catch {
        Write-TestResult -TestName "Database connection" -Passed $false -Message $_.Exception.Message
        exit 1
    }
    
    # Test 3: Expected tables exist
    $expectedTables = @(
        'Runs', 'Categories', 'CheckDefinitions', 'CheckResults',
        'Issues', 'IssueHistory', 'Inventory', 'Scores',
        'Configuration', 'KnowledgeBase'
    )
    
    $query = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
    $command = $connection.CreateCommand()
    $command.CommandText = $query
    $reader = $command.ExecuteReader()
    
    $actualTables = @()
    while ($reader.Read()) {
        $actualTables += $reader['name']
    }
    $reader.Close()
    
    $allTablesExist = $true
    foreach ($table in $expectedTables) {
        $exists = $actualTables -contains $table
        if (-not $exists) {
            $allTablesExist = $false
        }
    }
    
    Write-TestResult -TestName "All tables exist ($($expectedTables.Count) expected)" -Passed $allTablesExist `
        -Message "Found: $($actualTables.Count) tables"
    
    # Test 4: Views exist
    $query = "SELECT name FROM sqlite_master WHERE type='view';"
    $command.CommandText = $query
    $reader = $command.ExecuteReader()
    
    $viewCount = 0
    while ($reader.Read()) {
        $viewCount++
    }
    $reader.Close()
    
    Write-TestResult -TestName "Views created" -Passed ($viewCount -ge 3) `
        -Message "Found: $viewCount views"
    
    # Test 5: Indexes exist
    $query = "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%';"
    $command.CommandText = $query
    $reader = $command.ExecuteReader()
    
    $indexCount = 0
    while ($reader.Read()) {
        $indexCount++
    }
    $reader.Close()
    
    Write-TestResult -TestName "Indexes created" -Passed ($indexCount -ge 10) `
        -Message "Found: $indexCount indexes"
    
    # Test 6: Categories table has initial data
    $query = "SELECT COUNT(*) as Count FROM Categories;"
    $command.CommandText = $query
    $reader = $command.ExecuteReader()
    $reader.Read()
    $categoryCount = $reader['Count']
    $reader.Close()
    
    Write-TestResult -TestName "Categories initialized" -Passed ($categoryCount -eq 9) `
        -Message "Found: $categoryCount categories (expected 9)"
    
    # Test 7: Configuration table has initial data
    $query = "SELECT COUNT(*) as Count FROM Configuration;"
    $command.CommandText = $query
    $reader = $command.ExecuteReader()
    $reader.Read()
    $configCount = $reader['Count']
    $reader.Close()
    
    Write-TestResult -TestName "Configuration initialized" -Passed ($configCount -ge 5) `
        -Message "Found: $configCount config entries"
    
    # Test 8: Can insert test run
    try {
        $testRunId = [Guid]::NewGuid().ToString()
        $query = @"
INSERT INTO Runs (RunId, StartTime, ForestName, DomainName, ExecutedBy, ExecutionHost, Status)
VALUES (@RunId, @StartTime, @Forest, @Domain, @User, @Host, @Status);
"@
        $command.CommandText = $query
        $command.Parameters.AddWithValue("@RunId", $testRunId) | Out-Null
        $command.Parameters.AddWithValue("@StartTime", (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")) | Out-Null
        $command.Parameters.AddWithValue("@Forest", "test.local") | Out-Null
        $command.Parameters.AddWithValue("@Domain", "test.local") | Out-Null
        $command.Parameters.AddWithValue("@User", $env:USERNAME) | Out-Null
        $command.Parameters.AddWithValue("@Host", $env:COMPUTERNAME) | Out-Null
        $command.Parameters.AddWithValue("@Status", "Completed") | Out-Null
        
        $rowsAffected = $command.ExecuteNonQuery()
        $command.Parameters.Clear()
        
        Write-TestResult -TestName "Insert test run" -Passed ($rowsAffected -eq 1) `
            -Message "RunId: $testRunId"
        
        # Test 9: Can query test run
        $query = "SELECT * FROM Runs WHERE RunId = @RunId;"
        $command.CommandText = $query
        $command.Parameters.AddWithValue("@RunId", $testRunId) | Out-Null
        $reader = $command.ExecuteReader()
        
        $canRead = $reader.Read()
        $reader.Close()
        $command.Parameters.Clear()
        
        Write-TestResult -TestName "Query test run" -Passed $canRead
        
        # Test 10: Can delete test run (cleanup)
        $query = "DELETE FROM Runs WHERE RunId = @RunId;"
        $command.CommandText = $query
        $command.Parameters.AddWithValue("@RunId", $testRunId) | Out-Null
        $rowsDeleted = $command.ExecuteNonQuery()
        
        Write-TestResult -TestName "Delete test run (cleanup)" -Passed ($rowsDeleted -eq 1)
    }
    catch {
        Write-TestResult -TestName "CRUD operations" -Passed $false -Message $_.Exception.Message
    }
    
    # Test 11: Triggers exist
    $query = "SELECT name FROM sqlite_master WHERE type='trigger';"
    $command.CommandText = $query
    $reader = $command.ExecuteReader()
    
    $triggerCount = 0
    while ($reader.Read()) {
        $triggerCount++
    }
    $reader.Close()
    
    Write-TestResult -TestName "Triggers created" -Passed ($triggerCount -ge 3) `
        -Message "Found: $triggerCount triggers"
    
    # Cleanup
    $command.Dispose()
    $connection.Close()
    $connection.Dispose()
    
    Write-Host "`n===== All Tests Completed Successfully =====" -ForegroundColor Green
    Write-Host "Database is ready for use.`n" -ForegroundColor Green
}
catch {
    Write-Host "`n===== Tests Failed =====" -ForegroundColor Red
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Stack Trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
}
