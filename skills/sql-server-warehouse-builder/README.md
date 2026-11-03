# SQL Server Warehouse Builder — reusable Agent Skill

Reusable for **any SQL Server data warehouse / BI project**, not only payments. Provides a repeatable route from real source columns to designed dimensions and facts, staging loaders, historical semantics, reconciliation, reporting queries, and Power BI-ready keys.

## Install and use

### Codex project scope
Copy the entire `sql-server-warehouse-builder/` folder into:

`.agents/skills/sql-server-warehouse-builder/`

### Other Agent Skills-compatible agents
Import the directory or the ZIP through that agent's skill import mechanism. `SKILL.md` is the required entrypoint. Support for optional tooling varies across hosts. This archive does **not** automatically install anything into your account or connect to your SQL Server.

### Prompt
> Use the `sql-server-warehouse-builder` skill. I am starting an SQL Server BI warehouse. I will supply the source schema/table list and columns. Design one table at a time, choose SCD policy, and give me two T-SQL scripts: DDL and ETL procedure plus EXEC. Keep validations concise but strict on financial data.

## Package contents

- `SKILL.md`: triggers, workflow and nonnegotiable correctness rules.
- `references/`: model design, SQL Server implementation, reporting SQL patterns, validation/testing, pitfalls, quality gate.
- `assets/`: project-intake form and adaptable T-SQL patterns.
- `examples/`: example from an unrelated domain, demonstrating portability.
- `scripts/validate_skill.py`: offline package/file validation (**not** a SQL Server parser or execution test).
- `EVALUATION.md`: candidate designs, qualitative scoring and package checks.

## Development and validation

From the parent directory:

```bash
python sql-server-warehouse-builder/scripts/validate_skill.py sql-server-warehouse-builder
```

The validator checks required metadata, naming, bundled references and placeholder documentation. It does **not** connect to a database, parse all T-SQL semantics, or certify production readiness.

## Technology scope

Default SQL Server 2019+ and Azure SQL Database (where selected features exist). T-SQL, `CREATE OR ALTER PROCEDURE`, relational star schema, `stg` → reporting schema, full snapshots/incremental feeds. For Microsoft Fabric Warehouse, PostgreSQL, MySQL, Oracle or Spark, create an engine-specific variant: syntax and transactional capabilities differ.

## Design principles

1. Ground every column and rule in a source contract.
2. Keep SCD2 dimension history distinct from fact events.
3. Use small essential checks for ordinary tables and exact reconciliation for money.
4. Support idempotent reruns and safe rollback.
5. Produce one reviewable table at a time.
6. Never claim successful deployment or tests that weren't run.

## Sources for maintaining these patterns

- Agent Skills format: https://agentskills.io/specification
- OpenAI Skills guide: https://developers.openai.com/api/docs/guides/tools-skills
- `SET XACT_ABORT`: https://learn.microsoft.com/en-us/sql/t-sql/statements/set-xact-abort-transact-sql
- Application locks: https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-getapplock-transact-sql
- Filtered indexes: https://learn.microsoft.com/en-us/sql/relational-databases/indexes/create-filtered-indexes
- SCD modeling: https://learn.microsoft.com/en-us/fabric/data-warehouse/dimensional-modeling-dimension-tables
