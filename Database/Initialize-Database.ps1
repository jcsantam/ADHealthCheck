<#
.SYNOPSIS
    Initializes the SQLite database for AD Health Check

.DESCRIPTION
    Creates and initializes the SQLite database with schema, tables, indexes,
    views, triggers, and initial data. This script can be run multiple times
    safely (idempotent operations).

.PARAMETER DatabasePath
    Path where the SQLite database file will be created.
    Default: ../Output/healthcheck.db

.PARAMETER ForceRecreate
    If specified, drops and recreates the entire database.
    WARNING: This will delete all existing data!

.EXAMPLE
    .\Initialize-Database.ps1
    Creates/updates database at default location

.EXAMPLE
    .\Initialize-Database.ps1 -DatabasePath "C:\Data\healthcheck.db" -ForceRecreate
    Recreates database at specified location

.NOTES
    Author: AD Health Check Team
    Version: 1.0
    Requires: PowerShell 5.1+ and System.Data.SQLite
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DatabasePath = "$PSScriptRoot\..\Output\healthcheck.db",
    
    [Parameter(Mandatory = $false)]
    [switch]$ForceRecreate
)

# =============================================================================
# SCRIPT VARIABLES
# =============================================================================

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

# Path to schema SQL file
$SchemaPath = Join-Path $PSScriptRoot "Schema.sql"

# =============================================================================
# FUNCTION: Write-Log
# Purpose: Standardized logging output
# =============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info'    { 'White' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }
    
    Write-Host "[$timestamp] [$Level] $Message" -ForegroundColor $color
}

# =============================================================================
# FUNCTION: Test-SQLiteModule
# Purpose: Check if System.Data.SQLite is available, install if needed
# =============================================================================
function Test-SQLiteModule {
    Write-Log "Checking for System.Data.SQLite module..." -Level Info
    
    try {
        # Try to load the assembly
        Add-Type -AssemblyName System.Data.SQLite -ErrorAction Stop
        Write-Log "System.Data.SQLite is already loaded" -Level Success
        return $true
    }
    catch {
        Write-Log "System.Data.SQLite not found, attempting to install..." -Level Warning
        
        # Try to install via NuGet
        try {
            # Install NuGet provider if needed
            if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
                Write-Log "Installing NuGet package provider..." -Level Info
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
            }
            
            # Install System.Data.SQLite
            Write-Log "Installing System.Data.SQLite package..." -Level Info
            Install-Package -Name System.Data.SQLite.Core -ProviderName NuGet -Force -Scope CurrentUser | Out-Null
            
            # Get the installed package path
            $package = Get-Package -Name System.Data.SQLite.Core
            $packagePath = Split-Path $package.Source
            
            # Find the appropriate DLL (x64 or x86)
            $dllPath = if ([Environment]::Is64BitProcess) {
                Get-ChildItem -Path $packagePath -Recurse -Filter "System.Data.SQLite.dll" | 
                    Where-Object { $_.DirectoryName -like "*\net*" -and $_.DirectoryName -like "*\x64*" } | 
                    Select-Object -First 1 -ExpandProperty FullName
            } else {
                Get-ChildItem -Path $packagePath -Recurse -Filter "System.Data.SQLite.dll" | 
                    Where-Object { $_.DirectoryName -like "*\net*" -and $_.DirectoryName -like "*\x86*" } | 
                    Select-Object -First 1 -ExpandProperty FullName
            }
            
            if ($dllPath -and (Test-Path $dllPath)) {
                Add-Type -Path $dllPath
                Write-Log "System.Data.SQLite installed and loaded successfully" -Level Success
                return $true
            }
            else {
                throw "Could not find System.Data.SQLite.dll after installation"
            }
        }
        catch {
            Write-Log "Failed to install System.Data.SQLite: $($_.Exception.Message)" -Level Error
            Write-Log "Please install System.Data.SQLite manually from https://system.data.sqlite.org/" -Level Error
            return $false
        }
    }
}

# =============================================================================
# FUNCTION: New-SQLiteConnection
# Purpose: Create and open SQLite database connection
# =============================================================================
function New-SQLiteConnection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DatabasePath
    )
    
    try {
        # Create connection string
        $connectionString = "Data Source=$DatabasePath;Version=3;New=True;Compress=True;"
        
        # Create connection object
        $connection = New-Object System.Data.SQLite.SQLiteConnection($connectionString)
        
        # Open connection
        $connection.Open()
        
        Write-Log "Database connection opened: $DatabasePath" -Level Success
        return $connection
    }
    catch {
        Write-Log "Failed to create database connection: $($_.Exception.Message)" -Level Error
        throw
    }
}

# =============================================================================
# FUNCTION: Invoke-SQLiteCommand
# Purpose: Execute SQL command against database
# =============================================================================
function Invoke-SQLiteCommand {
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SQLite.SQLiteConnection]$Connection,
        
        [Parameter(Mandatory = $true)]
        [string]$CommandText
    )
    
    try {
        $command = $Connection.CreateCommand()
        $command.CommandText = $CommandText
        $result = $command.ExecuteNonQuery()
        return $result
    }
    catch {
        Write-Log "SQL execution error: $($_.Exception.Message)" -Level Error
        Write-Log "Command: $CommandText" -Level Error
        throw
    }
    finally {
        if ($command) {
            $command.Dispose()
        }
    }
}

# =============================================================================
# FUNCTION: Initialize-DatabaseSchema
# Purpose: Load and execute schema SQL file
# =============================================================================
function Initialize-DatabaseSchema {
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SQLite.SQLiteConnection]$Connection
    )
    
    Write-Log "Loading schema from: $SchemaPath" -Level Info
    
    # Verify schema file exists
    if (-not (Test-Path $SchemaPath)) {
        throw "Schema file not found: $SchemaPath"
    }
    
    # Read schema file
    $schemaSQL = Get-Content -Path $SchemaPath -Raw
    
    # Split into individual commands (separated by semicolons)
    # SQLite doesn't support batches, so we need to execute one at a time
    $commands = $schemaSQL -split ';' | Where-Object { $_.Trim() -ne '' }
    
    Write-Log "Executing $($commands.Count) schema commands..." -Level Info
    
    $executedCount = 0
    foreach ($command in $commands) {
        $trimmedCommand = $command.Trim()
        if ($trimmedCommand -ne '') {
            try {
                Invoke-SQLiteCommand -Connection $Connection -CommandText $trimmedCommand
                $executedCount++
            }
            catch {
                # Some commands may fail if already exists (which is OK for idempotent script)
                # We'll log but continue
                Write-Verbose "Command execution note: $($_.Exception.Message)"
            }
        }
    }
    
    Write-Log "Schema initialized successfully ($executedCount commands executed)" -Level Success
}

# =============================================================================
# FUNCTION: Test-DatabaseSchema
# Purpose: Verify database schema is correct
# =============================================================================
function Test-DatabaseSchema {
    param(
        [Parameter(Mandatory = $true)]
        [System.Data.SQLite.SQLiteConnection]$Connection
    )
    
    Write-Log "Verifying database schema..." -Level Info
    
    # Expected tables
    $expectedTables = @(
        'Runs',
        'Categories',
        'CheckDefinitions',
        'CheckResults',
        'Issues',
        'IssueHistory',
        'Inventory',
        'Scores',
        'Configuration',
        'KnowledgeBase'
    )
    
    # Query for existing tables
    $query = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
    $command = $Connection.CreateCommand()
    $command.CommandText = $query
    $reader = $command.ExecuteReader()
    
    $actualTables = @()
    while ($reader.Read()) {
        $actualTables += $reader['name']
    }
    $reader.Close()
    $command.Dispose()
    
    # Verify all expected tables exist
    $missingTables = $expectedTables | Where-Object { $actualTables -notcontains $_ }
    
    if ($missingTables.Count -eq 0) {
        Write-Log "All expected tables found (${expectedTables.Count})" -Level Success
        return $true
    }
    else {
        Write-Log "Missing tables: $($missingTables -join ', ')" -Level Error
        return $false
    }
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

try {
    Write-Log "===== AD Health Check Database Initialization =====" -Level Info
    Write-Log "Database Path: $DatabasePath" -Level Info
    
    # Step 1: Check SQLite availability
    if (-not (Test-SQLiteModule)) {
        throw "System.Data.SQLite is required but could not be loaded or installed"
    }
    
    # Step 2: Handle existing database
    if (Test-Path $DatabasePath) {
        if ($ForceRecreate) {
            Write-Log "Removing existing database (ForceRecreate specified)..." -Level Warning
            Remove-Item -Path $DatabasePath -Force
        }
        else {
            Write-Log "Database already exists, will update/verify schema" -Level Info
        }
    }
    else {
        # Create output directory if it doesn't exist
        $dbDirectory = Split-Path $DatabasePath -Parent
        if (-not (Test-Path $dbDirectory)) {
            Write-Log "Creating database directory: $dbDirectory" -Level Info
            New-Item -ItemType Directory -Path $dbDirectory -Force | Out-Null
        }
    }
    
    # Step 3: Create/open database connection
    $connection = New-SQLiteConnection -DatabasePath $DatabasePath
    
    try {
        # Step 4: Initialize schema
        Initialize-DatabaseSchema -Connection $connection
        
        # Step 5: Verify schema
        $schemaValid = Test-DatabaseSchema -Connection $connection
        
        if ($schemaValid) {
            Write-Log "===== Database initialization completed successfully =====" -Level Success
            Write-Log "Database ready at: $DatabasePath" -Level Success
        }
        else {
            throw "Database schema verification failed"
        }
    }
    finally {
        # Always close connection
        if ($connection) {
            $connection.Close()
            $connection.Dispose()
            Write-Log "Database connection closed" -Level Info
        }
    }
}
catch {
    Write-Log "Database initialization failed: $($_.Exception.Message)" -Level Error
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level Error
    exit 1
}

Write-Log "Script completed" -Level Success
