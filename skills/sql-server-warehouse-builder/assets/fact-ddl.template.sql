-- REFERENCE TEMPLATE ONLY. Adapt ALL table/column names and constraints
-- to the actual source contract before executing.
-- Example assumes source: stg.fact_event(event_id BIGINT, entity_id BIGINT,
-- occurred_at DATETIME2(6), amount_minor BIGINT, amount_usd DECIMAL(28,8)).
-- Example policy: one immutable financial event per event_id;
-- USD reporting may be backfilled. Do not copy financial immutability
-- into mutable order/payment workflows without reviewing the policy.

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

IF OBJECT_ID(N'main.fact_event', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_event (
        event_id BIGINT NOT NULL,
        entity_id BIGINT NOT NULL,
        occurred_at DATETIME2(6) NOT NULL,
        amount_minor BIGINT NOT NULL,
        amount_usd DECIMAL(28,8) NULL,

        CONSTRAINT PK_fact_event PRIMARY KEY CLUSTERED (event_id),
        CONSTRAINT CK_fact_event_ids CHECK (event_id > 0 AND entity_id > 0),
        CONSTRAINT CK_fact_event_amount CHECK (amount_minor <> 0)
        -- Add FK constraints to actual dimension keys ONLY when available.
        -- A business ID in an SCD2 dimension is NOT a unique FK target.
    );

    -- Add workload-driven indexes after checking query plans.
    CREATE NONCLUSTERED INDEX IX_fact_event_entity_date
        ON main.fact_event (entity_id, occurred_at)
        INCLUDE (amount_minor);
END;

-- A pre-existing table must be checked against the intended DDL.
-- This IF-guard does not provide schema migration.
