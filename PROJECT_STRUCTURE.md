# AD Health Check - Project Structure

## Directory Layout

```
ADHealthCheck/
│
├── Config/                          # Configuration files
│   ├── settings.json                # Global settings
│   ├── thresholds.json              # Threshold values for checks
│   └── categories.json              # Category definitions
│
├── Core/                            # Core engine modules
│   ├── Engine.ps1                   # Main orchestration engine
│   ├── Discovery.ps1                # AD topology discovery
│   ├── Executor.ps1                 # Parallel check execution
│   ├── Evaluator.ps1                # Rule-based result evaluation
│   ├── Scorer.ps1                   # Scoring algorithm
│   └── Logger.ps1                   # Logging system
│
├── Database/                        # Database layer
│   ├── Initialize-Database.ps1      # DB initialization script
│   ├── Schema.sql                   # SQLite schema definition
│   └── Queries.ps1                  # Common DB queries
│
├── Checks/                          # Check implementation scripts
│   ├── Replication/                 # Replication checks (147)
│   ├── DCHealth/                    # DC health checks (155)
│   ├── DNS/                         # DNS checks (79)
│   ├── GPO/                         # GPO/SYSVOL checks (45)
│   ├── Time/                        # Time sync checks (12)
│   ├── Backup/                      # Backup checks (32)
│   ├── Security/                    # Security checks (32)
│   ├── Database/                    # AD database checks (19)
│   └── Operational/                 # Operational excellence (35)
│
├── Definitions/                     # JSON check definitions
│   ├── Replication.json
│   ├── DCHealth.json
│   ├── DNS.json
│   ├── GPO.json
│   ├── Time.json
│   ├── Backup.json
│   ├── Security.json
│   ├── Database.json
│   └── Operational.json
│
├── Documentation/                   # Knowledge base per check
│   ├── Replication/
│   ├── DCHealth/
│   ├── DNS/
│   └── ... (per category)
│
├── Frontend/                        # Web UI (Phase 4)
│   ├── public/
│   ├── src/
│   │   ├── components/
│   │   ├── pages/
│   │   └── services/
│   └── package.json
│
├── Output/                          # Generated reports
│   └── [timestamp]/
│       ├── report.html
│       ├── report.json
│       └── healthcheck.db
│
├── Tests/                           # Unit and integration tests
│   ├── Core/
│   ├── Checks/
│   └── Integration/
│
├── Invoke-ADHealthCheck.ps1         # Main entry point
└── README.md                        # Project documentation
```

## Phase 1 Focus (Current)

We are implementing:
- Config/
- Core/
- Database/
- First critical checks in Checks/
- Corresponding Definitions/

Frontend and full UI will come in Phase 4.
