
-- ====================================================
-- PROCEDURE: dbo.usp_LoadFactDispute
-- Full Snapshot + Upsert + Essential Validations
-- ====================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactDispute
    @ExpectedDisputeCount BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @InitialRows BIGINT = 0,
        @TargetRows BIGINT = 0,
        @InsertedRows BIGINT = 0,
        @UpdatedRows BIGINT = 0,
        @LockResult INT;

    BEGIN TRY

        -- 1. Verify required tables
        IF OBJECT_ID(N'stg.fact_dispute', N'U') IS NULL
            THROW 56001, 'Staging fact_dispute is missing.', 1;

        IF OBJECT_ID(N'main.fact_dispute', N'U') IS NULL
            THROW 56002, 'Destination fact_dispute is missing.', 1;

        IF OBJECT_ID(N'main.fact_payment_attempt', N'U') IS NULL
            THROW 56003, 'Load fact_payment_attempt first.', 1;

        IF OBJECT_ID(N'main.fact_refund', N'U') IS NULL
            THROW 56004, 'Load fact_refund first.', 1;

        IF @ExpectedDisputeCount IS NOT NULL
           AND @ExpectedDisputeCount < 0
            THROW 56005, 'Invalid expected dispute count.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent ETL executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_dispute',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 56006, 'Could not acquire ETL lock.', 1;

        -- 3. Capture full staging snapshot
        SELECT
            dispute_id,
            intent_id,
            opened_at,
            resolved_at,
            minutes_to_resolve,
            [status],
            reason,
            currency_code,
            disputed_amount_major,
            settlement_debit_major,
            disputed_amount_major_usd,
            settlement_debit_major_usd
        INTO #Raw
        FROM stg.fact_dispute WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #Raw;

        IF @ExpectedDisputeCount IS NOT NULL
           AND @SourceRows <> @ExpectedDisputeCount
            THROW 56007, 'Unexpected dispute count.', 1;

        -- 4. Reject invalid optional values and long text
        IF EXISTS (
            SELECT 1
            FROM #Raw AS r
            WHERE
                LEN(TRIM(CONVERT(
                    VARCHAR(MAX), r.[status]
                ))) > 20

                OR LEN(TRIM(CONVERT(
                    NVARCHAR(MAX), r.reason
                ))) > 200

                OR LEN(TRIM(CONVERT(
                    VARCHAR(MAX), r.currency_code
                ))) > 3

                OR (
                    NULLIF(TRIM(CONVERT(
                        NVARCHAR(100), r.resolved_at
                    )), N'') IS NOT NULL
                    AND TRY_CONVERT(
                        DATETIME2(6), r.resolved_at
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.minutes_to_resolve
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(20,3), r.minutes_to_resolve
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.settlement_debit_major
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(19,4), r.settlement_debit_major
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.disputed_amount_major_usd
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(28,8), r.disputed_amount_major_usd
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.settlement_debit_major_usd
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(28,8), r.settlement_debit_major_usd
                    ) IS NULL
                )
        )
            THROW 56008, 'Invalid source values.', 1;

        -- 5. Normalize staging data
        SELECT
            TRY_CONVERT(BIGINT, r.dispute_id)
                AS dispute_id,

            TRY_CONVERT(BIGINT, r.intent_id)
                AS intent_id,

            TRY_CONVERT(DATETIME2(6), r.opened_at)
                AS opened_at,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), r.resolved_at
                )), N'')
            ) AS resolved_at,

            TRY_CONVERT(
                DECIMAL(20,3),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.minutes_to_resolve
                )), '')
            ) AS minutes_to_resolve,

            CAST(LOWER(TRIM(CONVERT(
                VARCHAR(MAX), r.[status]
            ))) AS VARCHAR(20)) AS [status],

            CAST(NULLIF(TRIM(CONVERT(
                NVARCHAR(MAX), r.reason
            )), N'') AS NVARCHAR(200)) AS reason,

            CAST(UPPER(TRIM(CONVERT(
                VARCHAR(MAX), r.currency_code
            ))) AS VARCHAR(3)) AS currency_code,

            TRY_CONVERT(
                DECIMAL(19,4), r.disputed_amount_major
            ) AS disputed_amount_major,

            TRY_CONVERT(
                DECIMAL(19,4),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.settlement_debit_major
                )), '')
            ) AS settlement_debit_major,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.disputed_amount_major_usd
                )), '')
            ) AS disputed_amount_major_usd,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.settlement_debit_major_usd
                )), '')
            ) AS settlement_debit_major_usd

        INTO #Source
        FROM #Raw AS r;

        -- 7. Enforce one dispute per case and intent
        IF EXISTS (
            SELECT dispute_id
            FROM #Source
            GROUP BY dispute_id
            HAVING COUNT_BIG(*) > 1
        )
        OR EXISTS (
            SELECT intent_id
            FROM #Source
            GROUP BY intent_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 56010, 'Duplicate dispute or intent.', 1;

        -- Add analytical date key
        SELECT
            s.*,
            YEAR(s.opened_at) * 10000
                + MONTH(s.opened_at) * 100
                + DAY(s.opened_at)
                AS opened_date_key
        INTO #Resolved
        FROM #Source AS s;

        CREATE UNIQUE CLUSTERED INDEX IX_ResolvedDispute
            ON #Resolved(dispute_id);

        -- 9. Prevent disputes on successfully refunded payments
        IF EXISTS (
            SELECT 1
            FROM #Resolved AS s
            JOIN main.fact_refund AS r
                ON r.intent_id = s.intent_id
            WHERE r.[status] IN ('succeeded', 'completed')
        )
            THROW 56012, 'Dispute conflicts with successful refund.', 1;

        -- 10. Check calendar and currency references
        IF EXISTS (
            SELECT 1
            FROM #Resolved AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_date AS d
                WHERE d.date_key = s.opened_date_key
            )
            OR NOT EXISTS (
                SELECT 1
                FROM main.dim_currency AS c
                WHERE c.currency_code = s.currency_code
            )
        )
            THROW 56013, 'Invalid date or currency reference.', 1;

        -- 11. Lock target and protect existing cases
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_dispute WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.fact_dispute AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #Resolved AS s
                WHERE s.dispute_id = d.dispute_id
            )
        )
            THROW 56014, 'Existing dispute missing from snapshot.', 1;

        -- 12. Protect immutable case attributes
        -- Finalized outcomes cannot be silently changed.
        IF EXISTS (
            SELECT 1
            FROM main.fact_dispute AS d
            JOIN #Resolved AS s
                ON s.dispute_id = d.dispute_id
            WHERE d.intent_id <> s.intent_id
               OR d.opened_at <> s.opened_at
               OR d.currency_code <> s.currency_code
               OR d.disputed_amount_major <> s.disputed_amount_major

               OR (
                    d.[status] IN ('won', 'lost')
                    AND EXISTS (
                        SELECT
                            d.[status],
                            d.resolved_at,
                            d.minutes_to_resolve,
                            d.settlement_debit_major
                        EXCEPT
                        SELECT
                            s.[status],
                            s.resolved_at,
                            s.minutes_to_resolve,
                            s.settlement_debit_major
                    )
               )
        )
            THROW 56015, 'Immutable dispute data changed.', 1;

        -- 13. Update changed records only
        UPDATE d
        SET
            d.resolved_at = s.resolved_at,
            d.minutes_to_resolve = s.minutes_to_resolve,
            d.[status] = s.[status],
            d.reason = s.reason,
            d.settlement_debit_major = s.settlement_debit_major,
            d.disputed_amount_major_usd =
                s.disputed_amount_major_usd,
            d.settlement_debit_major_usd =
                s.settlement_debit_major_usd
        FROM main.fact_dispute AS d
        JOIN #Resolved AS s
            ON s.dispute_id = d.dispute_id
        WHERE EXISTS (
            SELECT
                d.resolved_at,
                d.minutes_to_resolve,
                d.[status] COLLATE Latin1_General_100_BIN2,
                d.reason COLLATE Latin1_General_100_BIN2,
                d.settlement_debit_major,
                d.disputed_amount_major_usd,
                d.settlement_debit_major_usd
            EXCEPT
            SELECT
                s.resolved_at,
                s.minutes_to_resolve,
                s.[status] COLLATE Latin1_General_100_BIN2,
                s.reason COLLATE Latin1_General_100_BIN2,
                s.settlement_debit_major,
                s.disputed_amount_major_usd,
                s.settlement_debit_major_usd
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 14. Insert new disputes
        INSERT INTO main.fact_dispute (
            dispute_id,
            intent_id,
            opened_at,
            resolved_at,
            opened_date_key,
            minutes_to_resolve,
            [status],
            reason,
            currency_code,
            disputed_amount_major,
            settlement_debit_major,
            disputed_amount_major_usd,
            settlement_debit_major_usd
        )
        SELECT
            s.dispute_id,
            s.intent_id,
            s.opened_at,
            s.resolved_at,
            s.opened_date_key,
            s.minutes_to_resolve,
            s.[status],
            s.reason,
            s.currency_code,
            s.disputed_amount_major,
            s.settlement_debit_major,
            s.disputed_amount_major_usd,
            s.settlement_debit_major_usd
        FROM #Resolved AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_dispute AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.dispute_id = s.dispute_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 15. Essential post-load reconciliation
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.fact_dispute;

        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @InsertedRows
            THROW 56016, 'Dispute row count mismatch.', 1;

        IF EXISTS (
            SELECT
                dispute_id, intent_id, opened_at, resolved_at,
                opened_date_key, minutes_to_resolve,
                [status] COLLATE Latin1_General_100_BIN2,
                reason COLLATE Latin1_General_100_BIN2,
                currency_code, disputed_amount_major,
                settlement_debit_major,
                disputed_amount_major_usd,
                settlement_debit_major_usd
            FROM #Resolved

            EXCEPT

            SELECT
                dispute_id, intent_id, opened_at, resolved_at,
                opened_date_key, CAST(minutes_to_resolve AS INT),
                [status] COLLATE Latin1_General_100_BIN2,
                reason COLLATE Latin1_General_100_BIN2,
                currency_code, disputed_amount_major,
                settlement_debit_major,
                disputed_amount_major_usd,
                settlement_debit_major_usd
            FROM main.fact_dispute
        )
            THROW 56017, 'Dispute reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 16. Execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @TargetRows AS target_rows,
            @InsertedRows AS inserted_rows,
            @UpdatedRows AS updated_rows,
            @SourceRows - @InsertedRows - @UpdatedRows
                AS unchanged_rows,
            SYSUTCDATETIME() AS completed_at_utc;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
GO

-- Strengthen the lost-dispute NOT NULL constraint
-- (SQL Server CHECK constraints otherwise permit UNKNOWN).
IF NOT EXISTS (
    SELECT 1
    FROM sys.check_constraints
    WHERE parent_object_id = OBJECT_ID(N'main.fact_dispute')
      AND name = N'CK_fact_dispute_lost_debit_required'
)
BEGIN
    ALTER TABLE main.fact_dispute WITH CHECK
    ADD CONSTRAINT CK_fact_dispute_lost_debit_required
    CHECK (
        [status] <> 'lost'
        OR settlement_debit_major IS NOT NULL
    );
END;

-- Execute the procedure
EXEC dbo.usp_LoadFactDispute;

-- Complete the deferred fact_fee -> fact_dispute relationship.
IF OBJECT_ID(N'main.fact_fee', N'U') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1
       FROM sys.foreign_keys
       WHERE parent_object_id = OBJECT_ID(N'main.fact_fee')
         AND name = N'FK_fact_fee_dispute'
   )
BEGIN
    ALTER TABLE main.fact_fee WITH CHECK
    ADD CONSTRAINT FK_fact_fee_dispute
        FOREIGN KEY (dispute_id)
        REFERENCES main.fact_dispute(dispute_id);
END;
