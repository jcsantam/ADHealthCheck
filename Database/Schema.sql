-- ============================================================================
-- AD Health Check - Database Schema
-- SQLite 3 Database
-- Purpose: Store health check runs, issues, and tracking information
-- ============================================================================

-- ============================================================================
-- TABLE: Runs
-- Purpose: Store metadata about each health check execution
-- ============================================================================
CREATE TABLE IF NOT EXISTS Runs (
    RunId TEXT PRIMARY KEY,                    -- Unique identifier (GUID)
    StartTime TEXT NOT NULL,                   -- ISO 8601 format (e.g., 2026-02-13T10:30:00)
    EndTime TEXT,                              -- ISO 8601 format
    ForestName TEXT NOT NULL,                  -- AD Forest name
    DomainName TEXT NOT NULL,                  -- Primary domain name
    ExecutedBy TEXT NOT NULL,                  -- User who executed the check
    ExecutionHost TEXT NOT NULL,               -- Computer where check was run
    Status TEXT NOT NULL,                      -- Running/Completed/Failed
    OverallScore INTEGER,                      -- 0-100 overall health score
    TotalChecks INTEGER DEFAULT 0,             -- Total checks executed
    PassedChecks INTEGER DEFAULT 0,            -- Checks that passed
    WarningChecks INTEGER DEFAULT 0,           -- Checks with warnings
    FailedChecks INTEGER DEFAULT 0,            -- Checks that failed
    CriticalIssues INTEGER DEFAULT 0,          -- Count of critical issues
    HighIssues INTEGER DEFAULT 0,              -- Count of high severity issues
    MediumIssues INTEGER DEFAULT 0,            -- Count of medium severity issues
    LowIssues INTEGER DEFAULT 0,               -- Count of low severity issues
    Configuration TEXT,                        -- JSON: configuration used for this run
    Notes TEXT,                                -- Optional notes about this run
    Created TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================================
-- TABLE: Categories
-- Purpose: Define health check categories
-- ============================================================================
CREATE TABLE IF NOT EXISTS Categories (
    CategoryId TEXT PRIMARY KEY,               -- Unique category identifier (e.g., "Replication")
    CategoryName TEXT NOT NULL,                -- Display name
    Description TEXT,                          -- Category description
    DisplayOrder INTEGER DEFAULT 0,            -- Order to display categories
    IsActive INTEGER DEFAULT 1,                -- 1 = active, 0 = inactive
    Created TEXT NOT NULL DEFAULT (datetime('now'))
);

-- ============================================================================
-- TABLE: CheckDefinitions
-- Purpose: Store metadata about each check
-- ============================================================================
CREATE TABLE IF NOT EXISTS CheckDefinitions (
    CheckId TEXT PRIMARY KEY,                  -- Unique check identifier (e.g., "REP-001")
    CheckName TEXT NOT NULL,                   -- Display name
    CategoryId TEXT NOT NULL,                  -- Foreign key to Categories
    Description TEXT NOT NULL,                 -- What this check validates
    Severity TEXT NOT NULL,                    -- Critical/High/Medium/Low
    Impact TEXT,                               -- Impact description
    Probability TEXT,                          -- Probability description
    Effort TEXT,                               -- Effort to remediate
    ScriptPath TEXT NOT NULL,                  -- Path to PowerShell script
    EvaluationRules TEXT,                      -- JSON: evaluation rules
    RemediationSteps TEXT,                     -- Markdown: how to fix issues
    KBArticles TEXT,                           -- JSON array: knowledge base URLs
    Tags TEXT,                                 -- JSON array: searchable tags
    IsEnabled INTEGER DEFAULT 1,               -- 1 = enabled, 0 = disabled
    Version TEXT DEFAULT '1.0',                -- Check version
    Created TEXT NOT NULL DEFAULT (datetime('now')),
    Modified TEXT,
    FOREIGN KEY (CategoryId) REFERENCES Categories(CategoryId)
);

-- ============================================================================
-- TABLE: CheckResults
-- Purpose: Store individual check execution results
-- ============================================================================
CREATE TABLE IF NOT EXISTS CheckResults (
    ResultId TEXT PRIMARY KEY,                 -- Unique result identifier (GUID)
    RunId TEXT NOT NULL,                       -- Foreign key to Runs
    CheckId TEXT NOT NULL,                     -- Foreign key to CheckDefinitions
    StartTime TEXT NOT NULL,                   -- Check execution start time
    EndTime TEXT,                              -- Check execution end time
    DurationMs INTEGER,                        -- Execution duration in milliseconds
    Status TEXT NOT NULL,                      -- Pass/Warning/Fail/Error/Skipped
    ExitCode INTEGER DEFAULT 0,                -- Exit code from script
    RawOutput TEXT,                            -- JSON: raw output from check script
    ProcessedOutput TEXT,                      -- JSON: processed/evaluated output
    ErrorMessage TEXT,                         -- Error message if check failed
    IssuesDetected INTEGER DEFAULT 0,          -- Count of issues found
    Created TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (RunId) REFERENCES Runs(RunId) ON DELETE CASCADE,
    FOREIGN KEY (CheckId) REFERENCES CheckDefinitions(CheckId)
);

-- ============================================================================
-- TABLE: Issues
-- Purpose: Store individual issues detected by checks
-- ============================================================================
CREATE TABLE IF NOT EXISTS Issues (
    IssueId TEXT PRIMARY KEY,                  -- Unique issue identifier (GUID)
    RunId TEXT NOT NULL,                       -- Foreign key to Runs
    ResultId TEXT NOT NULL,                    -- Foreign key to CheckResults
    CheckId TEXT NOT NULL,                     -- Foreign key to CheckDefinitions
    Severity TEXT NOT NULL,                    -- Critical/High/Medium/Low/Info
    Status TEXT NOT NULL DEFAULT 'Open',       -- Open/InProgress/Resolved/FalsePositive/Ignored
    Title TEXT NOT NULL,                       -- Issue title
    Description TEXT NOT NULL,                 -- Detailed description
    AffectedObject TEXT,                       -- Object that has the issue (DC name, GPO, etc.)
    Evidence TEXT,                             -- JSON: evidence data
    Impact TEXT,                               -- Business impact description
    Recommendation TEXT,                       -- How to resolve
    AssignedTo TEXT,                           -- User assigned to resolve
    DueDate TEXT,                              -- Target resolution date
    ResolvedDate TEXT,                         -- Actual resolution date
    ResolutionNotes TEXT,                      -- Notes about resolution
    FirstDetected TEXT NOT NULL,               -- When first detected
    LastDetected TEXT NOT NULL,                -- When last seen
    DetectionCount INTEGER DEFAULT 1,          -- How many times detected
    Created TEXT NOT NULL DEFAULT (datetime('now')),
    Modified TEXT,
    FOREIGN KEY (RunId) REFERENCES Runs(RunId) ON DELETE CASCADE,
    FOREIGN KEY (ResultId) REFERENCES CheckResults(ResultId) ON DELETE CASCADE,
    FOREIGN KEY (CheckId) REFERENCES CheckDefinitions(CheckId)
);

-- ============================================================================
-- TABLE: IssueHistory
-- Purpose: Track issue state changes over time
-- ============================================================================
CREATE TABLE IF NOT EXISTS IssueHistory (
    HistoryId INTEGER PRIMARY KEY AUTOINCREMENT,
    IssueId TEXT NOT NULL,                     -- Foreign key to Issues
    ChangedBy TEXT NOT NULL,                   -- User who made the change
    ChangeType TEXT NOT NULL,                  -- StatusChange/Assignment/Comment/Resolution
    OldValue TEXT,                             -- Previous value
    NewValue TEXT,                             -- New value
    Comment TEXT,                              -- Optional comment
    Timestamp TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (IssueId) REFERENCES Issues(IssueId) ON DELETE CASCADE
);

-- ============================================================================
-- TABLE: Inventory
-- Purpose: Store discovered AD infrastructure (DCs, Sites, etc.)
-- ============================================================================
CREATE TABLE IF NOT EXISTS Inventory (
    InventoryId INTEGER PRIMARY KEY AUTOINCREMENT,
    RunId TEXT NOT NULL,                       -- Foreign key to Runs
    ItemType TEXT NOT NULL,                    -- DomainController/Site/Subnet/Domain/Forest
    ItemName TEXT NOT NULL,                    -- Name of the item
    ParentItem TEXT,                           -- Parent container (e.g., Site for DC)
    Properties TEXT,                           -- JSON: additional properties
    IsActive INTEGER DEFAULT 1,                -- 1 = active, 0 = inactive
    Discovered TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (RunId) REFERENCES Runs(RunId) ON DELETE CASCADE
);

-- ============================================================================
-- TABLE: Scores
-- Purpose: Store scoring details per category and overall
-- ============================================================================
CREATE TABLE IF NOT EXISTS Scores (
    ScoreId INTEGER PRIMARY KEY AUTOINCREMENT,
    RunId TEXT NOT NULL,                       -- Foreign key to Runs
    CategoryId TEXT,                           -- NULL for overall score, CategoryId for category score
    ScoreValue INTEGER NOT NULL,               -- 0-100 score
    MaxPossible INTEGER NOT NULL DEFAULT 100,  -- Maximum possible score
    ChecksExecuted INTEGER DEFAULT 0,          -- Checks executed in this category
    ChecksPassed INTEGER DEFAULT 0,            -- Checks passed in this category
    WeightedScore REAL,                        -- Weighted contribution to overall score
    CalculationMethod TEXT,                    -- Description of how score was calculated
    Details TEXT,                              -- JSON: detailed scoring breakdown
    Created TEXT NOT NULL DEFAULT (datetime('now')),
    FOREIGN KEY (RunId) REFERENCES Runs(RunId) ON DELETE CASCADE,
    FOREIGN KEY (CategoryId) REFERENCES Categories(CategoryId)
);

-- ============================================================================
-- TABLE: Configuration
-- Purpose: Store application configuration settings
-- ============================================================================
CREATE TABLE IF NOT EXISTS Configuration (
    ConfigKey TEXT PRIMARY KEY,                -- Configuration key
    ConfigValue TEXT NOT NULL,                 -- Configuration value (can be JSON)
    Description TEXT,                          -- What this setting controls
    DataType TEXT DEFAULT 'string',            -- string/integer/boolean/json
    IsSystem INTEGER DEFAULT 0,                -- 1 = system setting, 0 = user setting
    Created TEXT NOT NULL DEFAULT (datetime('now')),
    Modified TEXT
);

-- ============================================================================
-- TABLE: KnowledgeBase
-- Purpose: Store documentation and remediation guides
-- ============================================================================
CREATE TABLE IF NOT EXISTS KnowledgeBase (
    ArticleId TEXT PRIMARY KEY,                -- Unique article identifier
    CheckId TEXT,                              -- Optional: associated check
    Title TEXT NOT NULL,                       -- Article title
    Category TEXT,                             -- Category for organization
    Content TEXT NOT NULL,                     -- Markdown content
    Tags TEXT,                                 -- JSON array: searchable tags
    ExternalLinks TEXT,                        -- JSON array: KB articles, TechNet, etc.
    Author TEXT,                               -- Article author
    Version TEXT DEFAULT '1.0',                -- Article version
    Created TEXT NOT NULL DEFAULT (datetime('now')),
    Modified TEXT,
    FOREIGN KEY (CheckId) REFERENCES CheckDefinitions(CheckId)
);

-- ============================================================================
-- INDEXES for performance
-- ============================================================================

-- Runs indexes
CREATE INDEX IF NOT EXISTS idx_runs_starttime ON Runs(StartTime);
CREATE INDEX IF NOT EXISTS idx_runs_forest ON Runs(ForestName);
CREATE INDEX IF NOT EXISTS idx_runs_status ON Runs(Status);

-- CheckResults indexes
CREATE INDEX IF NOT EXISTS idx_checkresults_runid ON CheckResults(RunId);
CREATE INDEX IF NOT EXISTS idx_checkresults_checkid ON CheckResults(CheckId);
CREATE INDEX IF NOT EXISTS idx_checkresults_status ON CheckResults(Status);

-- Issues indexes
CREATE INDEX IF NOT EXISTS idx_issues_runid ON Issues(RunId);
CREATE INDEX IF NOT EXISTS idx_issues_checkid ON Issues(CheckId);
CREATE INDEX IF NOT EXISTS idx_issues_severity ON Issues(Severity);
CREATE INDEX IF NOT EXISTS idx_issues_status ON Issues(Status);
CREATE INDEX IF NOT EXISTS idx_issues_affectedobject ON Issues(AffectedObject);
CREATE INDEX IF NOT EXISTS idx_issues_assignedto ON Issues(AssignedTo);

-- IssueHistory indexes
CREATE INDEX IF NOT EXISTS idx_issuehistory_issueid ON IssueHistory(IssueId);
CREATE INDEX IF NOT EXISTS idx_issuehistory_timestamp ON IssueHistory(Timestamp);

-- Inventory indexes
CREATE INDEX IF NOT EXISTS idx_inventory_runid ON Inventory(RunId);
CREATE INDEX IF NOT EXISTS idx_inventory_itemtype ON Inventory(ItemType);
CREATE INDEX IF NOT EXISTS idx_inventory_itemname ON Inventory(ItemName);

-- Scores indexes
CREATE INDEX IF NOT EXISTS idx_scores_runid ON Scores(RunId);
CREATE INDEX IF NOT EXISTS idx_scores_categoryid ON Scores(CategoryId);

-- KnowledgeBase indexes
CREATE INDEX IF NOT EXISTS idx_kb_checkid ON KnowledgeBase(CheckId);
CREATE INDEX IF NOT EXISTS idx_kb_category ON KnowledgeBase(Category);

-- ============================================================================
-- VIEWS for common queries
-- ============================================================================

-- View: Latest issues across all runs
CREATE VIEW IF NOT EXISTS vw_LatestIssues AS
SELECT 
    i.IssueId,
    i.CheckId,
    cd.CheckName,
    cd.CategoryId,
    i.Severity,
    i.Status,
    i.Title,
    i.AffectedObject,
    i.FirstDetected,
    i.LastDetected,
    i.DetectionCount,
    i.AssignedTo,
    r.ForestName,
    r.StartTime as LastRunTime
FROM Issues i
INNER JOIN CheckDefinitions cd ON i.CheckId = cd.CheckId
INNER JOIN Runs r ON i.RunId = r.RunId
WHERE i.Status NOT IN ('Resolved', 'FalsePositive', 'Ignored')
ORDER BY 
    CASE i.Severity 
        WHEN 'Critical' THEN 1
        WHEN 'High' THEN 2
        WHEN 'Medium' THEN 3
        WHEN 'Low' THEN 4
        ELSE 5
    END,
    i.FirstDetected DESC;

-- View: Run summary with scores
CREATE VIEW IF NOT EXISTS vw_RunSummary AS
SELECT 
    r.RunId,
    r.StartTime,
    r.EndTime,
    r.ForestName,
    r.Status,
    r.OverallScore,
    r.TotalChecks,
    r.PassedChecks,
    r.WarningChecks,
    r.FailedChecks,
    r.CriticalIssues,
    r.HighIssues,
    r.MediumIssues,
    r.LowIssues,
    CAST((julianday(r.EndTime) - julianday(r.StartTime)) * 24 * 60 AS INTEGER) as DurationMinutes
FROM Runs r
ORDER BY r.StartTime DESC;

-- View: Category scores for latest run
CREATE VIEW IF NOT EXISTS vw_LatestCategoryScores AS
SELECT 
    s.CategoryId,
    c.CategoryName,
    s.ScoreValue,
    s.ChecksExecuted,
    s.ChecksPassed,
    s.WeightedScore
FROM Scores s
INNER JOIN Categories c ON s.CategoryId = c.CategoryId
INNER JOIN (
    SELECT RunId, MAX(StartTime) as LatestRun
    FROM Runs
    WHERE Status = 'Completed'
) latest ON s.RunId = latest.RunId
WHERE s.CategoryId IS NOT NULL
ORDER BY c.DisplayOrder;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Trigger: Update Runs.TotalChecks when CheckResults are inserted
CREATE TRIGGER IF NOT EXISTS trg_UpdateRunStats_Insert
AFTER INSERT ON CheckResults
BEGIN
    UPDATE Runs
    SET TotalChecks = TotalChecks + 1,
        PassedChecks = CASE WHEN NEW.Status = 'Pass' THEN PassedChecks + 1 ELSE PassedChecks END,
        WarningChecks = CASE WHEN NEW.Status = 'Warning' THEN WarningChecks + 1 ELSE WarningChecks END,
        FailedChecks = CASE WHEN NEW.Status = 'Fail' THEN FailedChecks + 1 ELSE FailedChecks END
    WHERE RunId = NEW.RunId;
END;

-- Trigger: Update issue counts when Issues are inserted
CREATE TRIGGER IF NOT EXISTS trg_UpdateIssueStats_Insert
AFTER INSERT ON Issues
BEGIN
    UPDATE Runs
    SET CriticalIssues = CASE WHEN NEW.Severity = 'Critical' THEN CriticalIssues + 1 ELSE CriticalIssues END,
        HighIssues = CASE WHEN NEW.Severity = 'High' THEN HighIssues + 1 ELSE HighIssues END,
        MediumIssues = CASE WHEN NEW.Severity = 'Medium' THEN MediumIssues + 1 ELSE MediumIssues END,
        LowIssues = CASE WHEN NEW.Severity = 'Low' THEN LowIssues + 1 ELSE LowIssues END
    WHERE RunId = NEW.RunId;
END;

-- Trigger: Log issue status changes to history
CREATE TRIGGER IF NOT EXISTS trg_LogIssueStatusChange
AFTER UPDATE OF Status ON Issues
WHEN OLD.Status != NEW.Status
BEGIN
    INSERT INTO IssueHistory (IssueId, ChangedBy, ChangeType, OldValue, NewValue, Comment)
    VALUES (NEW.IssueId, 'System', 'StatusChange', OLD.Status, NEW.Status, 'Status changed');
    
    UPDATE Issues
    SET Modified = datetime('now')
    WHERE IssueId = NEW.IssueId;
END;

-- ============================================================================
-- Initial Data Population
-- ============================================================================

-- Insert default categories
INSERT OR IGNORE INTO Categories (CategoryId, CategoryName, Description, DisplayOrder) VALUES
('Replication', 'AD Replication', 'Active Directory replication health and topology', 1),
('DCHealth', 'DC Health', 'Domain Controller health, services, and performance', 2),
('DNS', 'DNS', 'DNS configuration and name resolution', 3),
('GPO', 'Group Policy', 'GPO and SYSVOL health', 4),
('Time', 'Time Synchronization', 'Time service configuration and sync status', 5),
('Backup', 'Backup & Recovery', 'Backup status and disaster recovery readiness', 6),
('Security', 'Security', 'Security baseline and compliance', 7),
('Database', 'AD Database', 'Active Directory database health', 8),
('Operational', 'Operational Excellence', 'Operational practices and processes', 9);

-- Insert default configuration
INSERT OR IGNORE INTO Configuration (ConfigKey, ConfigValue, Description, DataType, IsSystem) VALUES
('MaxParallelJobs', '10', 'Maximum number of parallel check executions', 'integer', 1),
('ExecutionTimeout', '300', 'Default timeout for check execution in seconds', 'integer', 1),
('RetentionDays', '90', 'Number of days to retain run history', 'integer', 1),
('EnableAutoCleanup', 'true', 'Automatically cleanup old run data', 'boolean', 1),
('LogLevel', 'Information', 'Logging level: Verbose/Information/Warning/Error', 'string', 1),
('DatabaseVersion', '1.0', 'Current database schema version', 'string', 1);

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================
