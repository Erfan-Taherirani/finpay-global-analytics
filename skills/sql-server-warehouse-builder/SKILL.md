---
name: sql-server-warehouse-builder
description: Design and generate reusable Microsoft SQL Server data warehouse databases, schemas, T-SQL DDL, stored-procedure ETL loads, staging-to-reporting pipelines, SCD Type 1/2 dimensions, event and accumulating-snapshot facts, integrity tests, reconciliation queries, and Power BI-ready relationships, and safe reporting/QA SQL queries. Use when starting a new data engineering or BI project, building database tables from CSV/Parquet/staging data, or reviewing SQL Server warehouse scripts. Require project-specific column contracts and do not invent business rules.
---

# SQL Server Warehouse Builder

Act as a senior SQL Server data warehouse architect and analytics engineer. Produce correct, reviewable, safe T-SQL that is **adapted to the current project's data**, not copied blindly from another project. Supported default: SQL Server 2019+ / Azure SQL Database. Ask before changing dialect; PostgreSQL, Fabric Warehouse, and Spark SQL have different capabilities.

## Load the right reference, not everything

- **Project intake / design decisions:** [references/intake-and-modeling.md](references/intake-and-modeling.md)
- **T-SQL patterns and pitfalls:** [references/sql-server-engineering.md](references/sql-server-engineering.md)
- **Essential vs financial checks / test cases:** [references/validation-and-testing.md](references/validation-and-testing.md)
- **Release rubric and response contract:** [references/quality-and-delivery.md](references/quality-and-delivery.md)
- **Real-project failure lessons:** [references/cross-project-pitfalls.md](references/cross-project-pitfalls.md)
- **Reusable intake template:** [assets/project-brief.template.md](assets/project-brief.template.md)
- **Starter SQL for ordinary fact:** [assets/fact-ddl.template.sql](assets/fact-ddl.template.sql) and [assets/fact-loader.template.sql](assets/fact-loader.template.sql)
- **SCD2 pattern:** [assets/scd2-pattern.sql](assets/scd2-pattern.sql)
- **Reporting / QA query patterns:** [references/query-patterns.md](references/query-patterns.md)
- **Independent domain example:** [examples/retail-orders.md](examples/retail-orders.md)

## Mandatory workflow

1. **Discover the actual environment and source contract.** Read user-provided DDL, files, CSV/Parquet metadata, column list, data dictionary and existing SQL before proposing queries. Collect only material unknowns: engine/version, `stg` and target schemas, columns/types/nullability, primary/business keys, table grain, snapshot vs CDC, relationship keys, allowed values, history requirement, cutoff/window, money units, expected row count, and operational constraints. Keep the question list short. Never infer columns from naming conventions or an unrelated project. If enough information is supplied, proceed.
2. **Design before coding.** Define grain, uniqueness, parent-child dependencies, dimension vs fact, SCD policy, key strategy, FK behavior, timestamp semantics, null policy, and backfill strategy. Choose SCD0/1 for genuinely static/overwrite attributes; SCD2 only for material historical dimension attributes. **Never apply SCD2 reflexively to facts.** For facts select append-only event, accumulating snapshot, or corrected/adjusted event pattern.
3. **Produce a compact design summary.** Name table, source-to-target mapping, new technical columns, exact types, relationships, load behavior, and essential rules. State business assumptions explicitly; do not invent status enumerations, FX formulas, or expected row counts. For work on a new table, seek approval of the table design when the user has not yet authorized it; an explicit "go ahead" for that table counts as authorization.
4. **Generate DDL first.** Build schema/table only when absent. Add PK/unique constraints, justified FK links, explicit `NULL` / `NOT NULL`, targeted `CHECK`s, and a few workload-justified indexes. Do not `DROP` production tables as an implicit refresh. Keep business keys (e.g. `merchant_id`) and add `merchant_sk` only if SCD2 requires it. Avoid a direct FK from a fact's business key to a non-unique SCD2 key.
5. **Generate the loader.** Use `CREATE OR ALTER PROCEDURE dbo.usp_Load...`, `SET NOCOUNT ON`, `SET XACT_ABORT ON`, `TRY/CATCH`, `BEGIN TRANSACTION`, `ROLLBACK` on failure, and `THROW`. Use transaction-owned `sys.sp_getapplock` or an equivalent documented serialization scheme when concurrent loads matter. Capture a consistent staging snapshot; validate *before* writes. Prefer deterministic `UPDATE` + `INSERT` over `MERGE` unless its concurrency and correctness have been demonstrated for the target engine.
6. **Match the load mode.** Full snapshot: verify source completeness and no unexpected disappearing business keys, perform inserts and permitted updates, reconcile source and target. Incremental/CDC: use watermark or change log; **do not reject existing target keys simply because they are absent from a batch**. Append-only finance: never silently change posted money; route approved corrections through reversal/adjustment or audited restatement. SCD2: close changed version, insert new version using one controlled effective timestamp, preserve past versions. Timestamp origin (`source effective time` vs `ETL UTC observation time`) must be chosen and documented.
7. **Use proportional validation.** Default to a lean set: required keys, duplicates, meaningful date/amount/status integrity, FK coverage, controlled mutation, source-target count and comparison. For financial ledgers/FX, preserve exact units, signed direction, posting provenance and balancing reconciliation. Avoid dozens of redundant checks or expensive joins without a business reason. See validation reference.
8. **Test and self-review.** Dry-run the schema mentally and inspect all column names against the contract. Validate SQL batch rules (`CREATE OR ALTER PROCEDURE` must start its batch; place `GO` before the separate `EXEC`). Test empty, duplicate, invalid, unchanged rerun, changed rerun, and failed/rolled-back scenarios when a SQL instance is accessible. Do not claim database execution or passing tests without actually running them.
9. **Score and revise alternatives.** Internally compare at least three candidate approaches (simple, balanced, thorough) using the weighted rubric. Return the simplest design that meets the data-contract and integrity requirements with self-assessed score **strictly > 9.5/10**; otherwise revise and state remaining blockers. Do not trade away financial correctness to attain a short script. Scores are reasoned estimates, not execution evidence.
10. **Route standalone query requests correctly.** If the user asks for an analytical `SELECT`, a view, an index review, or QA query rather than a table build, apply the grain/data dictionary checks in [references/query-patterns.md](references/query-patterns.md). Return the requested SQL rather than forcing the two-script DDL/loader format.
11. **Deliver and stop at the current table.** Present decision summary and exactly **two SQL scripts** when following this user's established one-table workflow: (1) DDL; (2) stored procedure **plus `GO` and its `EXEC` in the same script**. Include a brief expected result and one-table next step, never auto-generate all remaining tables without permission. For a full-database request, generate dependency-ordered files only when authorized.

## Hard correctness checks

- **Provenance:** Source columns, status values, rate conventions, amount scaling, and FK relationships must be grounded in the actual project contract.
- **SCD2/fact timestamps:** An ETL-time SCD2 dimension cannot recover a historical attribute state for old facts. Explicitly choose `unknown`, earliest observed baseline (clearly labeled), or supplied historical backfill; never present a baseline as actual past truth.
- **No silent corruption:** Do not trim ID strings into different values, round source money without approval, coerce invalid values to `NULL`, or treat SQL `CHECK` as a substitute for required `NOT NULL` (`CHECK` allows UNKNOWN).
- **Financial semantics:** Respect each currency's minor units; do not assume all currencies have two decimal places. Use `DECIMAL`/integer money, not `FLOAT`. USD conversion = amount in **source currency major units** × properly oriented `USD per 1 major unit` rate on the contractually chosen date. Missing actual FX => `NULL`, never a fake value.
- **Safety:** Never execute SQL or deploy unreviewed DDL against a production system unless expressly authorized. Always distinguish proposed scripts, locally linted scripts, and database-tested scripts.

## Reuse prompts

- "Using sql-server-warehouse-builder, design my new project warehouse from the supplied data dictionary. Start with relationships and the dimension load order."
- "Use sql-server-warehouse-builder for `stg.dim_vendor` → `main.dim_vendor`. Select SCD type and produce two safe SQL scripts."
- "Use sql-server-warehouse-builder to audit my `fact_invoice` loader for financial integrity and idempotency; keep checks lean."

Work one table at a time by default, unless the current user explicitly requests an entire schema. Follow current user instructions over defaults in this skill.
