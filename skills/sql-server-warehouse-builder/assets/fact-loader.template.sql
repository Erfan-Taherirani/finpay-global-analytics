-- REFERENCE TEMPLATE ONLY. Adapt names/types/source contracts before running.
-- Assumes PRE-TYPED staging stg.fact_event with these columns:
-- event_id BIGINT, entity_id BIGINT, occurred_at DATETIME2(6),
-- amount_minor BIGINT, amount_usd DECIMAL(28,8) NULL.
-- FULL SNAPSHOT, IMMUTABLE FINANCIAL EVENTS; amount_usd may change.
-- For CDC or mutable facts, change the missing-key/mutation policy.

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactEvent
    @ExpectedRows BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SourceRows BIGINT, @InitialRows BIGINT,
            @TargetRows BIGINT, @Inserted BIGINT = 0,
            @Updated BIGINT = 0, @LockResult INT;

    BEGIN TRY
        IF OBJECT_ID(N'stg.fact_event', N'U') IS NULL
            THROW 52001, 'Missing staging fact_event.', 1;
        IF OBJECT_ID(N'main.fact_event', N'U') IS NULL
            THROW 52002, 'Missing target fact_event.', 1;
        IF @ExpectedRows IS NOT NULL AND @ExpectedRows < 0
            THROW 52003, 'Expected count cannot be negative.', 1;

        BEGIN TRANSACTION;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_event',
            @LockMode = 'Exclusive', @LockOwner = 'Transaction',
            @LockTimeout = 30000;
        IF @LockResult IS NULL OR @LockResult < 0
            THROW 52004, 'Failed to acquire ETL lock.', 1;

        SELECT event_id, entity_id, occurred_at, amount_minor, amount_usd
        INTO #Source
        FROM stg.fact_event WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*) FROM #Source;
        IF @ExpectedRows IS NOT NULL AND @SourceRows <> @ExpectedRows
            THROW 52005, 'Incomplete/incorrect snapshot.', 1;

        IF EXISTS (
            SELECT 1 FROM #Source
            WHERE event_id IS NULL OR event_id <= 0
               OR entity_id IS NULL OR entity_id <= 0
               OR occurred_at IS NULL OR amount_minor IS NULL
               OR amount_minor = 0
        )
            THROW 52006, 'Invalid required source fields.', 1;

        IF EXISTS (
            SELECT event_id FROM #Source
            GROUP BY event_id HAVING COUNT_BIG(*) > 1
        )
            THROW 52007, 'Duplicate event_id.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_Source
            ON #Source(event_id);

        -- This is a full snapshot, so missing historical target events
        -- are a source-completeness error, not a delete request.
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_event WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1 FROM main.fact_event AS d
            WHERE NOT EXISTS (
                SELECT 1 FROM #Source AS s WHERE s.event_id = d.event_id
            )
        )
            THROW 52008, 'Existing event absent from full snapshot.', 1;

        -- Financial events are immutable except reporting USD.
        IF EXISTS (
            SELECT 1 FROM main.fact_event AS d
            JOIN #Source AS s ON s.event_id = d.event_id
            WHERE d.entity_id <> s.entity_id
               OR d.occurred_at <> s.occurred_at
               OR d.amount_minor <> s.amount_minor
        )
            THROW 52009, 'Immutable source event changed.', 1;

        UPDATE d SET amount_usd = s.amount_usd
        FROM main.fact_event AS d
        JOIN #Source AS s ON s.event_id = d.event_id
        WHERE EXISTS (
            SELECT d.amount_usd EXCEPT SELECT s.amount_usd
        );
        SET @Updated = @@ROWCOUNT;

        INSERT INTO main.fact_event (
            event_id, entity_id, occurred_at, amount_minor, amount_usd
        )
        SELECT s.event_id, s.entity_id, s.occurred_at,
               s.amount_minor, s.amount_usd
        FROM #Source AS s
        WHERE NOT EXISTS (
            SELECT 1 FROM main.fact_event AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.event_id = s.event_id
        );
        SET @Inserted = @@ROWCOUNT;

        SELECT @TargetRows = COUNT_BIG(*) FROM main.fact_event;
        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @Inserted
            THROW 52010, 'Snapshot count reconciliation failed.', 1;

        IF EXISTS (
            SELECT event_id, entity_id, occurred_at, amount_minor, amount_usd
            FROM #Source
            EXCEPT
            SELECT event_id, entity_id, occurred_at, amount_minor, amount_usd
            FROM main.fact_event
        )
            THROW 52011, 'Source-to-target reconciliation failed.', 1;

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS load_status, @SourceRows AS source_rows,
               @TargetRows AS target_rows, @Inserted AS inserted_rows,
               @Updated AS updated_rows,
               @SourceRows - @Inserted - @Updated AS unchanged_rows,
               SYSUTCDATETIME() AS completed_at_utc;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- Same second script as CREATE PROCEDURE when delivering this to users.
EXEC dbo.usp_LoadFactEvent;
