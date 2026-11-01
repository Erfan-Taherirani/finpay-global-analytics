---
name: sqlserver-warehouse-etl
description: Create production-oriented SQL Server data warehouse tables from staged CSV data, returning exactly two SQL scripts per table—a main schema DDL script and a transactional upsert stored procedure with embedded validations and reconciliation. Use for FinPay tables in stg and main, dimension or fact loads, SQL Server BI/Power BI models, and repeatable ETL builds.
---

# SQL Server Data Warehouse: DDL + Validated Upsert

## Purpose and output contract

Given a table name, its columns, and any source/business rules, produce **exactly two SQL code blocks** in this order:

1. **DDL code**: a deployable SQL Server script that creates `main.<table>` if it does not exist, specifying column types, nullability, key(s), verified foreign keys, check constraints, and justified indexes.
2. **ETL procedure code**: a deployable `CREATE OR ALTER PROCEDURE dbo.usp_Load<Table>` script that validates and loads `stg.<table>` into `main.<table>` by transactionally updating changed rows and inserting missing rows, with **all data-quality checks, post-load validations, error handling, and success metrics inside this second code block**. The same second block can end with an `EXEC dbo.usp_Load<Table>;` invocation if useful.

No third code block for validation, verification, or examples. Keep accompanying prose concise: assumptions, important business/engineering decisions, and up to one material clarification question if needed. Answer in the user's language, with SQL Server T-SQL (not PostgreSQL syntax). Treat source/target table names as fixed by the current project unless user overrides them.

The user may ask to create a reusable skill rather than to generate a particular table; in that case, return the skill file, explain the two-script contract, and do not invent a table specification.

## Input discovery and interpretation

- Use the current message, prior project data dictionary, dataset spec, schema definitions, actual CSV headers and user-provided rules to infer grain, primary key, nullable fields, relationships, allowed values, and expected counts. Never fabricate columns, enum values, foreign keys, dates, or counts.
- Default schemas: `stg` (already imported/normalized CSV source), `main` (Power BI-facing warehouse destination); procedure schema `dbo`. Source and target tables have the same base name unless explicitly changed.
- Respect supplied column names exactly except for explicitly clarified normalization (e.g., `pricing tier` -> `pricing_tier`); report such changes.
- Differentiate a **complete snapshot** from an **incremental/new-and-changed batch**. Unless explicitly requested otherwise, implement an upsert that works for both, **never delete target rows missing from staging**, and do not assert full-source counts when batches may be partial.
- Dimension defaults: SCD Type 1 (latest attribute values). Warn if history of pricing, tier, status or geographic attribution matters; propose SCD Type 2 only when needed. Fact defaults: immutable source keys and upsert of corrected facts; never recalculate/rewrite canonical finance history without explicit contract.
- If grain/primary key is genuinely unknown, ask one essential question. Otherwise state assumptions and proceed. Prefer one precise question rather than a form.
- Use web/official Microsoft Learn docs only when verification materially improves correctness; prefer retrieved project files for project-specific definitions.

## Script 1 — DDL requirements

- Use `IF OBJECT_ID(N'main.<table>', N'U') IS NULL BEGIN CREATE TABLE ... END; GO` for first-time deployment; never drop/recreate user tables as part of an ordinary upsert. If the target already exists with an incompatible schema, clearly say a separate migration is needed. Do not imply `CREATE IF NOT EXISTS` validates existing layouts.
- Explicit column list and data types; never `SELECT * INTO` as a production warehouse table-definition substitute.
- Use data types based on confirmed source semantics: `BIGINT` for sufficiently large integer source IDs, `INT` for bounded smaller integer keys, `NVARCHAR` for human-language text, `VARCHAR(n)` for known ASCII codes, `DATETIME2(3)` for UTC timestamps (unless source precision requires otherwise), `DATE` for calendar dates, `DECIMAL(p,s)` for measured/converted money. **Never `FLOAT`/`REAL` for financial amounts**. Prefer original integer minor units as canonical financial storage when present, and label reporting conversion columns accurately.
- Respect NULL semantics; `NULL` for genuinely absent dispute links, missing FX conversions, etc. Missing FX != zero. Make key columns `NOT NULL`. Avoid `IDENTITY` when source supplies stable IDs and existing facts use those IDs.
- Set `PRIMARY KEY` on validated grain; `UNIQUE` on verified natural keys; `CHECK` constraints for verified invariants; foreign keys only where the referenced table and compatible key are confirmed/loaded, else name the intended FK in prose as a later migration. Avoid CHECK enum lists based only on guesses.
- Add justified nonclustered indexes for common join keys and filtering, especially FKs not covered by the PK. Avoid redundant/overly numerous indexes on large fact tables. Note SQL Server does not automatically index FK columns.
- Check for deployment prerequisites (`main` schema, referenced parent tables) and communicate them. Prefer fail-fast preflight instead of silently omitting intended constraints.

## Script 2 — Stored procedure requirements

Use SQL Server `CREATE OR ALTER PROCEDURE dbo.usp_Load<Table> AS BEGIN ... END; GO`. Prefer `UPDATE` + `INSERT` over `MERGE` unless an exceptional reason is documented.

**Essential algorithm, in order:**

1. `SET NOCOUNT ON; SET XACT_ABORT ON;` and declare a small set of source/updated/inserted/unchanged/rejected/missing-FX counters as relevant.
2. Assert the source exists. Establish source batch consistency: stage a **single consistent version** of the source, preferably from a completed, published staging batch; coordinate the publisher (e.g., named batch/table swap, application lock also honored by publisher, or appropriate database snapshot/isolation strategy). A destination-only app lock does not protect against external staging writers.
3. For concurrency among cooperating loader executions, use a transaction-owned `sys.sp_getapplock` resource unique to the target table; ensure error handling and no leaked transaction. Protect insert anti-join with `UPDLOCK, HOLDLOCK`/appropriate isolation; ensure a PK/unique index is the final arbiter of uniqueness.
4. Materialize a limited, explicit-column staging snapshot to a temp table when appropriate. Validate **before any lossy cast**: required columns, type convertibility with `TRY_CONVERT`, string lengths before converting to shorter types, numeric range and decimal scale (no silent rounding), key positivity if contract states so, timestamp range, explicit NULL semantics, verified code/category domains, duplicate business/PK keys, and relevant business consistency rules. `TRY_CONVERT` only where supported; use culturally explicit date formats when staging uses character dates. Verify date/currency assumptions. Don't mix string and typed source values ambiguously.
5. Convert to typed rows only after validation; check parent keys and cross-table dependencies before writing. Validate cross-entity invariants only if required parent tables are available and the join keys/contracts are confirmed.
6. Reject a zero-row source by default unless zero rows are expected for the declared batch. Do not hardcode 2,000 merchants / 10 currencies etc. as a universal rule; only use project-authoritative counts for a **confirmed full snapshot**.
7. `BEGIN TRY` / `BEGIN TRANSACTION` / `COMMIT` and `BEGIN CATCH IF XACT_STATE() <> 0 ROLLBACK; THROW;`. Keep write locks/transactions as short as practical while guaranteeing the checked batch is the batch loaded. Use a temp table to avoid re-reading a changing staging table.
8. `UPDATE main.<table>` **only where data differs**, including NULL-aware comparisons using `EXCEPT` on matching row values (or explicit predicates). Do not update keys. Immediately capture `@@ROWCOUNT`.
9. `INSERT INTO main.<table>(explicit_columns) SELECT explicit_columns FROM #TypedSource WHERE NOT EXISTS (SELECT 1 FROM main.<table> WITH (UPDLOCK, HOLDLOCK) WHERE key matches)`. Immediately capture `@@ROWCOUNT`. Never delete missing target rows by default.
10. **Post-load validation INSIDE the procedure and before `COMMIT`**: all staged keys now exist; destination values match staged values for all supplied columns (NULL-aware); verify no unintended duplicate keys (PK), enforce row-count reconciliation using batch-appropriate logic, and check relevant monetary/FX integrity. SQL constraints are not a replacement for per-batch data-quality gates. Roll back on failure.
11. On success, return one compact result set, e.g., `load_status`, `source_rows`, `updated_rows`, `inserted_rows`, `unchanged_rows`, `completed_at_utc` and any relevant quality metrics (e.g., missing historical USD conversions); in case of error `THROW` after rollback. Do not claim successful load before commit. No hardcoded success counts.

**Strong guarantees and cautions:**

- Idempotency: second run of an unchanged complete staging batch yields zero updates/inserts.
- No `SELECT *` in loader; no truncate, drop, or destructive synchronization unless explicitly requested and proven safe.
- NULL-aware comparison must not accidentally equate missing FX to `0`.
- Avoid `NOLOCK` for audit/reconciliation. Lock handling must work under the database's isolation mode.
- `sp_getapplock` coordinates only sessions using the same resource. It cannot replace staging batch publishing discipline.
- If the source has sensitive/financial metrics, validate precision/scale before casting to destination; distinguish valid missing USD FX from a value of zero; do not introduce fabricated rates.
- For highly active/very large facts, mention that incremental watermark/change tracking, partitioned batches, indexes, and lock scope must be tuned rather than applying a dimension-scale full-snapshot procedure blindly.
- If the requested schema lacks necessary columns for safe versioning/auditing or constraints, avoid inventing them without permission; identify the limitation briefly.

## Validation selection guide

Include checks that are materially relevant and supportable from the source/business contract, not gratuitous generic tests:

- **Dimensions:** unique stable identifiers, nonempty names, valid ISO codes/currency keys, required attributes, valid onboarding/calendar ranges, allowed business statuses *if provided*, and post-load key/attribute reconciliation.
- **Payment/fee facts:** unique transaction/event IDs, foreign keys to intents/merchants/currencies where available, event timestamps, fee/dispute consistency, nonnegative fee amounts if that is the accounting convention, decimal scale, missing-FX counters, USD conversion logic when verified, and post-load reconciliation.
- **FX facts:** unique `(rate_date,currency_code)`, positive finite rates, valid effective dates and rate sources, explicit handling of weekends/unavailable FX—not fabricated zeros.
- **Merchant ledger:** stable entry ID, signed amounts and event types, payment chronology, and reconciliation with financial events; do not incorrectly turn processor costs into merchant debits.

## Response quality gate (self-check before answering)

Score the candidate on this 100-point rubric and revise until **at least 96/100** (~9.6/10). Scores are internal editorial checks rather than measured guarantees:

- Correct SQL Server syntax, runnable ordering, appropriate types: 25
- Correct constraints, keys, FK/load dependency management: 15
- Idempotent safe upsert and concurrency: 20
- Embedded pre-load validations and atomic post-load reconciliation: 20
- Robust error handling and useful audit output: 10
- Brevity, exactly two SQL code blocks, clear assumptions: 10

Deliver in the following short form:

**DDL — `main.<table>`**
(SQL code block #1)

**Load + validation — `dbo.usp_Load<Table>`**
(SQL code block #2)

**Notes:** two to five short sentences on prerequisites, load semantics, what was assumed, and the single most important unresolved question (only if needed). Do not include extra executable code blocks for invocation, validation, scoring, or other work.

## Authoritative references (verify versions if necessary)

- Microsoft Learn: `https://learn.microsoft.com/en-us/sql/t-sql/statements/create-procedure-transact-sql`
- Microsoft Learn: `https://learn.microsoft.com/en-us/sql/t-sql/statements/merge-transact-sql`
- Microsoft Learn: `https://learn.microsoft.com/en-us/sql/t-sql/language-elements/try-catch-transact-sql`
- Microsoft Learn: `https://learn.microsoft.com/en-us/sql/relational-databases/tables/primary-and-foreign-key-constraints`
- Microsoft Learn: `https://learn.microsoft.com/en-us/sql/relational-databases/tables/unique-constraints-and-check-constraints`
