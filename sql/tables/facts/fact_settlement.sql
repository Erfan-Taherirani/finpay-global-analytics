
-- ====================================================
-- PROCEDURE: dbo.usp_LoadFactSettlement
-- Full Snapshot + Upsert + Essential Validations
-- ====================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactSettlement
    @ExpectedSettlementCount BIGINT = NULL
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
        @CompletedRows BIGINT = 0,
        @PendingRows BIGINT = 0,
        @FailedRows BIGINT = 0,
        @LockResult INT;

    BEGIN TRY

        -- 1. Verify source and destination
        IF OBJECT_ID(N'stg.fact_settlement', N'U') IS NULL
            THROW 57001, 'Staging fact_settlement is missing.', 1;

        IF OBJECT_ID(N'main.fact_settlement', N'U') IS NULL
            THROW 57002, 'Destination fact_settlement is missing.', 1;

        IF @ExpectedSettlementCount IS NOT NULL
           AND @ExpectedSettlementCount <= 0
            THROW 57003, 'Invalid expected row count.', 1;

        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_settlement',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 57004, 'Could not acquire ETL lock.', 1;

        -- 2. Capture full staging snapshot
        SELECT
            settlement_id,
            merchant_id,
            currency_code,
            initiated_at,
            scheduled_at,
            completed_at,
            [status],
            failure_reason,
            time_to_scheduled_payout,
            payout_completion_time,
            schedule_deviation,
            amount_major,
            amount_major_usd
        INTO #Raw
        FROM stg.fact_settlement WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #Raw;

        IF @SourceRows = 0
           OR (
                @ExpectedSettlementCount IS NOT NULL
                AND @SourceRows <> @ExpectedSettlementCount
           )
            THROW 57005, 'Invalid settlement snapshot size.', 1;

        -- 3. Check text lengths before casting
        IF EXISTS (
            SELECT 1
            FROM #Raw
            WHERE DATALENGTH(TRIM(
                    CONVERT(VARCHAR(MAX), currency_code)
                  )) > 3
               OR DATALENGTH(TRIM(
                    CONVERT(VARCHAR(MAX), [status])
                  )) > 20
               OR DATALENGTH(TRIM(
                    CONVERT(NVARCHAR(MAX), failure_reason)
                  )) > 400
        )
            THROW 57006, 'Settlement text exceeds column size.', 1;

        -- 4. Normalize staging data
        SELECT
            TRY_CONVERT(BIGINT, settlement_id)
                AS settlement_id,

            TRY_CONVERT(BIGINT, merchant_id)
                AS merchant_id,

            CAST(UPPER(TRIM(
                CONVERT(VARCHAR(20), currency_code)
            )) AS VARCHAR(3)) AS currency_code,

            TRY_CONVERT(DATETIME2(6), initiated_at)
                AS initiated_at,

            TRY_CONVERT(DATETIME2(6), scheduled_at)
                AS scheduled_at,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), completed_at
                )), N'')
            ) AS completed_at,

            CAST(LOWER(TRIM(
                CONVERT(VARCHAR(50), [status])
            )) AS VARCHAR(20)) AS [status],

            CAST(NULLIF(TRIM(
                CONVERT(NVARCHAR(MAX), failure_reason)
            ), N'') AS NVARCHAR(200)) AS failure_reason,

            TRY_CONVERT(
                DECIMAL(20,3), time_to_scheduled_payout
            ) AS time_to_scheduled_payout,

            TRY_CONVERT(
                DECIMAL(20,3),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), payout_completion_time
                )), '')
            ) AS payout_completion_time,

            TRY_CONVERT(
                DECIMAL(20,3),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), schedule_deviation
                )), '')
            ) AS schedule_deviation,

            TRY_CONVERT(
                DECIMAL(19,4), amount_major
            ) AS amount_major,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), amount_major_usd
                )), '')
            ) AS amount_major_usd

        INTO #Source
        FROM #Raw;

        -- 5. Essential business validations
        IF EXISTS (
            SELECT 1
            FROM #Source AS s
            WHERE s.settlement_id IS NULL
               OR s.settlement_id <= 0
               OR s.merchant_id IS NULL
               OR s.merchant_id <= 0

               OR s.currency_code IS NULL
               OR DATALENGTH(s.currency_code) <> 3

               OR s.initiated_at IS NULL
               OR s.scheduled_at IS NULL
               OR s.initiated_at < '2021-10-01'
               OR s.initiated_at >= '2026-10-01'
               OR s.scheduled_at < s.initiated_at

               OR s.[status] IS NULL
               OR s.[status] COLLATE Latin1_General_100_BIN2
                    NOT IN ('pending', 'completed', 'failed')

               OR s.amount_major IS NULL
               OR s.amount_major <= 0
               OR (
                    s.amount_major_usd IS NOT NULL
                    AND s.amount_major_usd <= 0
               )

               OR s.time_to_scheduled_payout IS NULL
               OR s.time_to_scheduled_payout < 0

               OR (
                    s.completed_at IS NULL
                    AND s.payout_completion_time IS NOT NULL
               )
               OR (
                    s.completed_at IS NOT NULL
                    AND (
                        s.completed_at < s.initiated_at
                        OR s.completed_at >= '2026-10-01'
                        OR s.payout_completion_time IS NULL
                        OR s.payout_completion_time < 0
                    )
               )

               OR (
                    s.[status] = 'completed'
                    AND s.completed_at IS NULL
               )
               OR (
                    s.[status] = 'pending'
                    AND s.completed_at IS NOT NULL
               )
        )
            THROW 57007, 'Settlement business validation failed.', 1;

        -- 6. Reject duplicate settlement IDs
        IF EXISTS (
            SELECT settlement_id
            FROM #Source
            GROUP BY settlement_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 57008, 'Duplicate settlement IDs.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_SourceSettlement
            ON #Source(settlement_id);

        -- 7. Resolve merchant SCD Type 2 history
        -- For pre-ETL transactions, version 1 is
        -- the explicitly defined baseline.
        SELECT
            s.*,
            m.merchant_sk,

            YEAR(s.initiated_at) * 10000
                + MONTH(s.initiated_at) * 100
                + DAY(s.initiated_at)
                AS initiated_date_key,

            m.settlement_currency AS merchant_currency

        INTO #Resolved
        FROM #Source AS s
        OUTER APPLY (
            SELECT TOP (1)
                d.merchant_sk,
                d.settlement_currency
            FROM main.dim_merchant AS d WITH (HOLDLOCK)
            WHERE d.merchant_id = s.merchant_id
              AND (
                    (
                        s.initiated_at >= d.valid_from
                        AND s.initiated_at < d.valid_to
                    )
                    OR (
                        d.version_number = 1
                        AND s.initiated_at < d.valid_from
                    )
              )
            ORDER BY d.valid_from DESC, d.merchant_sk DESC
        ) AS m;

        -- 8. Verify dimension relationships
        IF EXISTS (
            SELECT 1
            FROM #Resolved AS s
            WHERE s.merchant_sk IS NULL
               OR s.merchant_currency
                    COLLATE Latin1_General_100_BIN2
                    <> s.currency_code
                       COLLATE Latin1_General_100_BIN2

               OR NOT EXISTS (
                    SELECT 1
                    FROM main.dim_currency AS c
                    WHERE c.currency_code = s.currency_code
               )

               OR NOT EXISTS (
                    SELECT 1
                    FROM main.dim_date AS d
                    WHERE d.date_key = s.initiated_date_key
               )
        )
            THROW 57009, 'Invalid merchant, currency, or date.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_ResolvedSettlement
            ON #Resolved(settlement_id);

        -- 9. Lock destination and protect history
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_settlement WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.fact_settlement AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #Resolved AS s
                WHERE s.settlement_id = d.settlement_id
            )
        )
            THROW 57010, 'Existing payout missing from snapshot.', 1;

        -- 10. Protect original financial details
        -- Finalized payout states cannot be reversed.
        IF EXISTS (
            SELECT 1
            FROM main.fact_settlement AS d
            JOIN #Resolved AS s
                ON s.settlement_id = d.settlement_id
            WHERE d.merchant_id <> s.merchant_id
               OR d.currency_code <> s.currency_code
               OR d.initiated_at <> s.initiated_at
               OR d.scheduled_at <> s.scheduled_at
               OR d.amount_major <> s.amount_major
               OR d.time_to_scheduled_payout
                    <> s.time_to_scheduled_payout

               OR (
                    d.[status] <> 'pending'
                    AND EXISTS (
                        SELECT
                            d.[status],
                            d.completed_at,
                            d.payout_completion_time
                        EXCEPT
                        SELECT
                            s.[status],
                            s.completed_at,
                            s.payout_completion_time
                    )
               )
        )
            THROW 57011, 'Immutable settlement details changed.', 1;

        -- 11. Update changed records
        UPDATE d
        SET
            d.merchant_sk = s.merchant_sk,
            d.completed_at = s.completed_at,
            d.[status] = s.[status],
            d.failure_reason = s.failure_reason,
            d.payout_completion_time = s.payout_completion_time,
            d.schedule_deviation = s.schedule_deviation,
            d.amount_major_usd = s.amount_major_usd
        FROM main.fact_settlement AS d
        JOIN #Resolved AS s
            ON s.settlement_id = d.settlement_id
        WHERE EXISTS (
            SELECT
                d.merchant_sk,
                d.completed_at,
                d.[status] COLLATE Latin1_General_100_BIN2,
                d.failure_reason COLLATE Latin1_General_100_BIN2,
                d.payout_completion_time,
                d.schedule_deviation,
                d.amount_major_usd
            EXCEPT
            SELECT
                s.merchant_sk,
                s.completed_at,
                s.[status] COLLATE Latin1_General_100_BIN2,
                s.failure_reason COLLATE Latin1_General_100_BIN2,
                s.payout_completion_time,
                s.schedule_deviation,
                s.amount_major_usd
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 12. Insert new payout instructions
        INSERT INTO main.fact_settlement (
            settlement_id,
            merchant_id,
            merchant_sk,
            currency_code,
            initiated_at,
            scheduled_at,
            completed_at,
            initiated_date_key,
            [status],
            failure_reason,
            time_to_scheduled_payout,
            payout_completion_time,
            schedule_deviation,
            amount_major,
            amount_major_usd
        )
        SELECT
            s.settlement_id,
            s.merchant_id,
            s.merchant_sk,
            s.currency_code,
            s.initiated_at,
            s.scheduled_at,
            s.completed_at,
            s.initiated_date_key,
            s.[status],
            s.failure_reason,
            s.time_to_scheduled_payout,
            s.payout_completion_time,
            s.schedule_deviation,
            s.amount_major,
            s.amount_major_usd
        FROM #Resolved AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_settlement AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.settlement_id = s.settlement_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 13. Post-load reconciliation
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.fact_settlement;

        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @InsertedRows
            THROW 57012, 'Settlement row count mismatch.', 1;

        -- Confirm all source records match destination.
        IF EXISTS (
            SELECT
                settlement_id, merchant_id, merchant_sk,
                currency_code, initiated_at, scheduled_at,
                completed_at, initiated_date_key, [status],
                failure_reason COLLATE Latin1_General_100_BIN2,
                time_to_scheduled_payout,
                payout_completion_time, schedule_deviation,
                amount_major, amount_major_usd
            FROM #Resolved

            EXCEPT

            SELECT
                settlement_id, merchant_id, merchant_sk,
                currency_code, initiated_at, scheduled_at,
                completed_at, initiated_date_key, [status],
                failure_reason COLLATE Latin1_General_100_BIN2,
                time_to_scheduled_payout,
                payout_completion_time, schedule_deviation,
                amount_major, amount_major_usd
            FROM main.fact_settlement
        )
            THROW 57013, 'Settlement reconciliation failed.', 1;

        -- 14. Capture payout statistics
        SELECT
            @CompletedRows = COUNT_BIG(
                CASE WHEN [status] = 'completed' THEN 1 END
            ),
            @PendingRows = COUNT_BIG(
                CASE WHEN [status] = 'pending' THEN 1 END
            ),
            @FailedRows = COUNT_BIG(
                CASE WHEN [status] = 'failed' THEN 1 END
            )
        FROM main.fact_settlement;

        COMMIT TRANSACTION;

        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @TargetRows AS target_rows,
            @InsertedRows AS inserted_rows,
            @UpdatedRows AS updated_rows,
            @SourceRows - @InsertedRows - @UpdatedRows
                AS unchanged_rows,
            @CompletedRows AS completed_payouts,
            @PendingRows AS pending_payouts,
            @FailedRows AS failed_payouts,
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
EXEC dbo.usp_LoadFactSettlement;
