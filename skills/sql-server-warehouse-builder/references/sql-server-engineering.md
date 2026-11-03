# SQL Server engineering patterns

Use for DDL, stored procedure authoring, optimizations, execution and code review.

## Batches, schemas, safety

- Qualify object names: `main.fact_order`, `stg.fact_order`, `dbo.usp_LoadFactOrder`.
- `CREATE OR ALTER PROCEDURE` begins its own SQL Server batch. In SSMS/sqlcmd, use `GO` immediately before the procedure when other statements precede it, and between its `END` and `EXEC`. `GO` is a client separator, **not** a SQL Server T-SQL command; don't send a complete `GO`-containing script to an API that doesn't parse batches.
- Existing non-conforming tables: stop and report schema mismatch or propose an explicit migration. `IF OBJECT_ID(...) IS NULL CREATE` alone does not validate a deployed table's structure.
- Use `DATETIME2(n)` consistently; use `SYSUTCDATETIME()` for ETL observation timestamps. `DATE` for calendar-only fields. Avoid local-time assumptions or implicit string date parsing when ingesting text.
- Default to `DECIMAL` for financial values; never use `FLOAT`, `REAL`, or SQL Server `MONEY` casually. Prefer source integer minor units for financial postings and exact reconciliations.
- Use `NOT NULL` when required. SQL Server `CHECK` lets UNKNOWN pass; cross-table rules belong in ETL/test queries, not CHECK.
- Add only workload-justified indexes. Favor a filtered unique index on the current SCD2 row; avoid redundant secondary indexes on large facts without measured benefit.

## Procedure skeleton (conceptual)

```sql
CREATE OR ALTER PROCEDURE dbo.usp_LoadSomeTable
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @LockResult INT;
    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.some_table',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;
        IF @LockResult IS NULL OR @LockResult < 0
            THROW 50001, 'Cannot acquire ETL lock', 1;

        -- Stage stable source, validate, UPDATE only permitted changes,
        -- INSERT missing keys, reconcile, then COMMIT.
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
EXEC dbo.usp_LoadSomeTable;
```

`sp_getapplock` coordinates cooperative loaders in the *same database*, not arbitrary source producers. It cannot replace sufficient transaction isolation and locks on staging or target tables. A robust snapshot read is required under concurrent source rewrites; choose suitable locking or snapshot isolation deliberately. If source snapshot is built outside the transaction, preserve a load/version ID and ensure nobody mutates it.

## Source normalization must fail loudly

- When staging is text, validate `TRY_CONVERT(type, raw)` before the insert; preserve data precision and enforce max lengths *before* casting narrower strings. With nullable columns, distinguish source `NULL`/blank (allowed) from malformed non-empty data (error).
- Never truncate an identifier or silently transform source business keys by trimming and case-folding without explicit rules. For integer IDs that arrive as decimal strings, `TRY_CONVERT(BIGINT,'1.5')` should not be treated as a valid `1`; enforce canonical format or numeric integrality.
- Validate two-dimensional currency format and FK coverage, but do not hardcode legal country/currency combinations unless the project actually specifies them.
- Prefer explicit SQL binary collation for case-sensitive change detection if the business contract requires character/case distinctions. Use `EXCEPT` on aligned types for NULL-safe row comparisons; beware collation conflicts.
- `TRY_CONVERT` can return `NULL` for unparseable data. It is not a substitute for rejecting corrupt rows. Decimal conversions can round if source scale is larger; check accepted tolerance/precision.

## Full snapshot vs incremental logic

**Full snapshot:** One source row per business key. Validate duplicates, complete snapshot (expected count if contractual), parent FK validity. Reject missing target keys unless source explicitly records deletes/deactivations. Compare changed rows null-safely; `UPDATE` changed rows; `INSERT` absent ones. Post-compare at least row count and source-minus-target; for high-stakes immutable finance use bidirectional `EXCEPT`/hash with a deterministic canonical projection.

**Incremental:** Incoming rows contain only new/changed keys. Never compare full target row count to incoming batch. Track watermark, change ID, or CDC LSN. Idempotent de-duplication and late arrivals require explicit policies. Preserve checkpoint movement only after committing the target changes.

**SCD Type 2:** Choose tracked attributes and use a single timestamp. Find new/changed members. Close only genuinely changed current rows (`valid_to = @EffectiveUTC`, `is_current=0`); insert version_number +1 current. No-op on identical rerun. Ensure no invalid current-row overlap, one current row per entity, complete version sequence where required. A change in a nontracked Type 1 attribute may be overwritten across history only if that is the specified policy.

**Financial posting:** Treat immutable local amount and event ID as immutable; corrections via explicit reversal-and-repost or a permissioned adjustment procedure, never regular refresh.

## FX and amount math

- Base/quote direction: `usd_per_major_unit` = USD for ONE unit of the source currency in major units. Formula: `amount_major * usd_per_major_unit`; don't invert without checking the data dictionary.
- Apply the **event-specific rate date**: checkout created date, fee assessed date, ledger posted date, etc., as defined in the project. Avoid one generic timestamp for every fact.
- `NULL` FX represents missing/unavailable; don't fabricate weekend rates or mislabel carry-forward observations. Store `observation_date`, `provider`, and `rate_status` if used. USD identity is exactly 1 where valid.
- Local currency minor-unit arithmetic should use the currency dimension's `minor_units` count, or better the original integer minor units. Major amounts may lose information if scaled to insufficient decimal precision; never infer minor unit amount after rounded conversion if the original minor units exist.
- Reconcile USD using a documented rounding tolerance/scale and a verified historical rate, never a guessed constant.

## Performance, locking and operations

- Minimize transaction length *without weakening consistency*. A snapshot copied into a load-ID staging table can allow validation before the target write transaction if that immutable snapshot is guaranteed.
- For millions of rows, confirm `tempdb`, log size, memory, useful key indexes, and plan/cardinality. Consider partitioned staging or incremental loads only with matching source guarantees.
- `MERGE` requires careful testing and concurrency guarantees; default to separate `UPDATE` and `INSERT` with keyed lookups and target locking.
- Provide load summary: source rows, inserted, updated, unchanged, deleted/rejected (if intentionally enabled), quality-failure count, completion UTC. Add audit logs/run IDs in production if the project has them.
- Never execute or enable schema changes in production without permission; explicit scripts first, execution separately.
