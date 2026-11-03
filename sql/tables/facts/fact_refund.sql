
-- ==============================================
-- PROCEDURE: dbo.usp_LoadFactRefund
-- Full Snapshot + Upsert + Essential Checks
-- ==============================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactRefund
    @ExpectedRefundCount BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT,
        @InitialRows BIGINT,
        @TargetRows BIGINT,
        @InsertedRows BIGINT = 0,
        @UpdatedRows BIGINT = 0,
        @LockResult INT;

    BEGIN TRY

        IF OBJECT_ID(N'stg.fact_refund', N'U') IS NULL
            THROW 55001, 'Staging fact_refund is missing.', 1;

        IF OBJECT_ID(N'main.fact_refund', N'U') IS NULL
            THROW 55002, 'Destination fact_refund is missing.', 1;

        IF @ExpectedRefundCount IS NOT NULL
           AND @ExpectedRefundCount <= 0
            THROW 55003, 'Invalid expected row count.', 1;

        BEGIN TRANSACTION;

        -- 1. Prevent concurrent executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_refund',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;

        IF @LockResult < 0 OR @LockResult IS NULL
            THROW 55004, 'Could not acquire ETL lock.', 1;

        -- 2. Capture the complete staging snapshot
        SELECT
            refund_id,
            intent_id,
            requested_at,
            completed_at,
            minutes_to_refund,
            [status],
            reason,
            currency_code,
            amount_major,
            settlement_debit_major,
            amount_major_usd,
            settlement_debit_major_usd
        INTO #Raw
        FROM stg.fact_refund WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #Raw;

        IF @SourceRows = 0
           OR (
                @ExpectedRefundCount IS NOT NULL
                AND @SourceRows <> @ExpectedRefundCount
           )
            THROW 55005, 'Invalid refund snapshot size.', 1;

        -- 3. Validate conversions and source lengths
        IF EXISTS (
            SELECT 1
            FROM #Raw
            WHERE TRY_CONVERT(BIGINT, refund_id) IS NULL
               OR TRY_CONVERT(BIGINT, intent_id) IS NULL
               OR TRY_CONVERT(DATETIME2(6), requested_at) IS NULL
               OR TRY_CONVERT(DECIMAL(19,4), amount_major) IS NULL

               OR LEN(TRIM(CONVERT(VARCHAR(MAX), [status]))) > 30
               OR LEN(TRIM(CONVERT(VARCHAR(MAX), currency_code))) > 3
               OR LEN(TRIM(CONVERT(NVARCHAR(MAX), reason))) > 200

               OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), settlement_debit_major
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(19,4), settlement_debit_major
                    ) IS NULL
               )

               OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), amount_major_usd
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(28,8), amount_major_usd
                    ) IS NULL
               )

               OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), settlement_debit_major_usd
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(28,8), settlement_debit_major_usd
                    ) IS NULL
               )
        )
            THROW 55006, 'Invalid refund source values.', 1;

        -- 4. Normalize source data
        SELECT
            CONVERT(BIGINT, refund_id) AS refund_id,
            CONVERT(BIGINT, intent_id) AS intent_id,

            CONVERT(DATETIME2(6), requested_at)
                AS requested_at,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), completed_at
                )), N'')
            ) AS completed_at,

            YEAR(CONVERT(DATETIME2(6), requested_at)) * 10000
                + MONTH(CONVERT(DATETIME2(6), requested_at)) * 100
                + DAY(CONVERT(DATETIME2(6), requested_at))
                AS requested_date_key,

            TRY_CONVERT(
                DECIMAL(20,3),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), minutes_to_refund
                )), '')
            ) AS minutes_to_refund,

            CAST(LOWER(TRIM(CONVERT(
                VARCHAR(100), [status]
            ))) AS VARCHAR(30)) AS [status],

            CAST(NULLIF(TRIM(CONVERT(
                NVARCHAR(MAX), reason
            )), N'') AS NVARCHAR(200)) AS reason,

            CAST(UPPER(TRIM(CONVERT(
                VARCHAR(100), currency_code
            ))) AS VARCHAR(3)) AS currency_code,

            CONVERT(DECIMAL(19,4), amount_major)
                AS amount_major,

            TRY_CONVERT(
                DECIMAL(19,4),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), settlement_debit_major
                )), '')
            ) AS settlement_debit_major,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), amount_major_usd
                )), '')
            ) AS amount_major_usd,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), settlement_debit_major_usd
                )), '')
            ) AS settlement_debit_major_usd

        INTO #Source
        FROM #Raw;

        -- 6. Ensure refund IDs are unique
        IF EXISTS (
            SELECT refund_id
            FROM #Source
            GROUP BY refund_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 55008, 'Duplicate refund IDs.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_SourceRefund
            ON #Source(refund_id);

        CREATE NONCLUSTERED INDEX IX_SourceRefundIntent
            ON #Source(intent_id);

        -- 8. Prevent successful refunds exceeding capture
        IF EXISTS (
            SELECT 1
            FROM #Source AS s
            JOIN main.fact_payment_intent AS p
                ON p.intent_id = s.intent_id
            GROUP BY
                s.intent_id,
                p.captured_settlement_major
            HAVING SUM(
                CASE
                    WHEN s.[status] IN ('succeeded', 'completed')
                    THEN COALESCE(s.settlement_debit_major, 0)
                    ELSE 0
                END
            ) > p.captured_settlement_major
        )
            THROW 55010, 'Refunds exceed captured principal.', 1;

        -- 9. Lock destination and prevent missing events
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_refund WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.fact_refund AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #Source AS s
                WHERE s.refund_id = d.refund_id
            )
        )
            THROW 55011, 'Existing refund missing from snapshot.', 1;

        -- 10. Protect immutable financial attributes
        -- Finalized refunds may only refresh their
        -- descriptive reason and USD reporting values.
        IF EXISTS (
            SELECT 1
            FROM main.fact_refund AS d
            JOIN #Source AS s
                ON s.refund_id = d.refund_id
            WHERE d.intent_id <> s.intent_id
               OR d.requested_at <> s.requested_at
               OR d.currency_code <> s.currency_code
               OR d.amount_major <> s.amount_major

               OR (
                    d.[status] <> 'pending'
                    AND EXISTS (
                        SELECT
                            d.[status],
                            d.completed_at,
                            d.minutes_to_refund,
                            d.settlement_debit_major
                        EXCEPT
                        SELECT
                            s.[status],
                            s.completed_at,
                            s.minutes_to_refund,
                            s.settlement_debit_major
                    )
               )
        )
            THROW 55012, 'Immutable refund data changed.', 1;

        -- 11. Update only changed records
        UPDATE d
        SET
            d.completed_at = s.completed_at,
            d.minutes_to_refund = s.minutes_to_refund,
            d.[status] = s.[status],
            d.reason = s.reason,
            d.settlement_debit_major = s.settlement_debit_major,
            d.amount_major_usd = s.amount_major_usd,
            d.settlement_debit_major_usd =
                s.settlement_debit_major_usd
        FROM main.fact_refund AS d
        JOIN #Source AS s
            ON s.refund_id = d.refund_id
        WHERE EXISTS (
            SELECT
                d.completed_at,
                d.minutes_to_refund,
                d.[status],
                d.reason COLLATE Latin1_General_100_BIN2,
                d.settlement_debit_major,
                d.amount_major_usd,
                d.settlement_debit_major_usd
            EXCEPT
            SELECT
                s.completed_at,
                s.minutes_to_refund,
                s.[status],
                s.reason COLLATE Latin1_General_100_BIN2,
                s.settlement_debit_major,
                s.amount_major_usd,
                s.settlement_debit_major_usd
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 12. Insert new refunds
        INSERT INTO main.fact_refund (
            refund_id,
            intent_id,
            requested_at,
            completed_at,
            requested_date_key,
            minutes_to_refund,
            [status],
            reason,
            currency_code,
            amount_major,
            settlement_debit_major,
            amount_major_usd,
            settlement_debit_major_usd
        )
        SELECT
            s.refund_id,
            s.intent_id,
            s.requested_at,
            s.completed_at,
            s.requested_date_key,
            s.minutes_to_refund,
            s.[status],
            s.reason,
            s.currency_code,
            s.amount_major,
            s.settlement_debit_major,
            s.amount_major_usd,
            s.settlement_debit_major_usd
        FROM #Source AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_refund AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.refund_id = s.refund_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 13. Essential post-load reconciliation
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.fact_refund;

        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @InsertedRows
            THROW 55013, 'Refund row count mismatch.', 1;

        -- Verify the destination matches the snapshot.
        IF EXISTS (
            SELECT
                refund_id,
                intent_id,
                requested_at,
                completed_at,
                requested_date_key,
                minutes_to_refund,
                [status],
                reason COLLATE Latin1_General_100_BIN2,
                currency_code,
                amount_major,
                settlement_debit_major,
                amount_major_usd,
                settlement_debit_major_usd
            FROM #Source

            EXCEPT

            SELECT
                refund_id,
                intent_id,
                requested_at,
                completed_at,
                requested_date_key,
                minutes_to_refund,
                [status],
                reason COLLATE Latin1_General_100_BIN2,
                currency_code,
                amount_major,
                settlement_debit_major,
                amount_major_usd,
                settlement_debit_major_usd
            FROM main.fact_refund
        )
            THROW 55014, 'Refund snapshot reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 14. Execution summary
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

-- Execute the stored procedure
EXEC dbo.usp_LoadFactRefund;
