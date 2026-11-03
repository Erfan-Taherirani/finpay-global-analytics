
-- ======================================================
-- PROCEDURE: dbo.usp_LoadFactFee
-- Full Snapshot + Financial Controls + Validations
-- ======================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactFee
    @ExpectedFeeCount BIGINT = NULL,
    @StartDate DATETIME2(6) = '2021-10-01T00:00:00',
    @SnapshotCutoff DATETIME2(6) = '2026-10-01T00:00:00'
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
        @MerchantFeeRows BIGINT = 0,
        @ProcessorCostRows BIGINT = 0,
        @DisputeFeeRows BIGINT = 0,
        @MissingUsdRows BIGINT = 0,
        @LockResult INT,
        @LoadUTC DATETIME2(7);

    BEGIN TRY

        -- 1. Verify source and target
        IF OBJECT_ID(N'stg.fact_fee', N'U') IS NULL
            THROW 54001, 'Staging fact_fee is missing.', 1;

        IF OBJECT_ID(N'main.fact_fee', N'U') IS NULL
            THROW 54002, 'Destination fact_fee is missing.', 1;

        IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
            THROW 54003, 'Parent fact_payment_intent missing.', 1;

        IF @StartDate IS NULL
           OR @SnapshotCutoff IS NULL
           OR @StartDate >= @SnapshotCutoff
           OR (
                @ExpectedFeeCount IS NOT NULL
                AND @ExpectedFeeCount <= 0
           )
            THROW 54004, 'Invalid ETL parameters.', 1;

        BEGIN TRANSACTION;

        -- 2. Acquire exclusive ETL application lock
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_fee',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 54005, 'Could not acquire ETL lock.', 1;

        SET @LoadUTC = SYSUTCDATETIME();

        -- 3. Capture authoritative source snapshot
        SELECT
            fee_id,
            intent_id,
            dispute_id,
            assessed_at,
            fee_type,
            settlement_currency,
            amount_settlement_major,
            amount_settlement_major_usd
        INTO #RawFee
        FROM stg.fact_fee WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawFee;

        -- 4. Validate source completeness
        IF @SourceRows = 0
            THROW 54006, 'Fee snapshot is empty.', 1;

        IF @ExpectedFeeCount IS NOT NULL
           AND @SourceRows <> @ExpectedFeeCount
            THROW 54007, 'Unexpected fee snapshot count.', 1;

        -- 5. Validate lengths and parseability
        IF EXISTS (
            SELECT 1
            FROM #RawFee AS r
            WHERE
                DATALENGTH(TRIM(CONVERT(
                    VARCHAR(MAX), r.fee_type
                ))) > 20

                OR DATALENGTH(TRIM(CONVERT(
                    VARCHAR(MAX), r.settlement_currency
                ))) > 3

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.dispute_id
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(BIGINT, r.dispute_id) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.amount_settlement_major_usd
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(28,8),
                        r.amount_settlement_major_usd
                    ) IS NULL
                )
        )
            THROW 54008, 'Invalid fee field or length.', 1;

        -- 6. Normalize and type staging records
        SELECT
            TRY_CONVERT(BIGINT, r.fee_id)
                AS fee_id,

            TRY_CONVERT(BIGINT, r.intent_id)
                AS intent_id,

            TRY_CONVERT(
                BIGINT,
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.dispute_id
                )), '')
            ) AS dispute_id,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), r.assessed_at
                )), N'')
            ) AS assessed_at,

            CAST(LOWER(TRIM(CONVERT(
                VARCHAR(MAX), r.fee_type
            ))) AS VARCHAR(20)) AS fee_type,

            CAST(UPPER(TRIM(CONVERT(
                VARCHAR(MAX), r.settlement_currency
            ))) AS VARCHAR(3)) AS settlement_currency,

            TRY_CONVERT(
                DECIMAL(19,4),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.amount_settlement_major
                )), '')
            ) AS amount_settlement_major,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.amount_settlement_major_usd
                )), '')
            ) AS amount_settlement_major_usd

        INTO #FeeSource
        FROM #RawFee AS r;

        -- 7. Validate required fields and categories
        IF EXISTS (
            SELECT 1
            FROM #FeeSource AS s
            WHERE s.fee_id IS NULL
               OR s.fee_id <= 0

               OR s.intent_id IS NULL
               OR s.intent_id <= 0

               OR (
                    s.dispute_id IS NOT NULL
                    AND s.dispute_id <= 0
               )

               OR s.assessed_at IS NULL
               OR s.assessed_at < @StartDate
               OR s.assessed_at >= @SnapshotCutoff

               OR s.fee_type IS NULL
               OR s.fee_type NOT IN (
                    'merchant_fee',
                    'processor_cost',
                    'dispute_fee'
               )

               OR s.settlement_currency IS NULL
               OR DATALENGTH(s.settlement_currency) <> 3
               OR s.settlement_currency
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z][A-Z]'

               OR s.amount_settlement_major IS NULL
               OR s.amount_settlement_major <= 0

               OR (
                    s.amount_settlement_major_usd IS NOT NULL
                    AND s.amount_settlement_major_usd <= 0
               )
        )
            THROW 54009, 'Invalid required fee data.', 1;

        -- 8. Reject fractional or truncated identifiers
        IF EXISTS (
            SELECT 1
            FROM #RawFee AS r
            WHERE
                TRY_CONVERT(BIGINT, r.fee_id) IS NULL
                OR TRY_CONVERT(BIGINT, r.intent_id) IS NULL

                OR (
                    TRY_CONVERT(DECIMAL(38,10), r.fee_id)
                        IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), r.fee_id)
                        <> TRY_CONVERT(DECIMAL(38,10),
                            TRY_CONVERT(BIGINT, r.fee_id))
                )

                OR (
                    TRY_CONVERT(DECIMAL(38,10), r.intent_id)
                        IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), r.intent_id)
                        <> TRY_CONVERT(DECIMAL(38,10),
                            TRY_CONVERT(BIGINT, r.intent_id))
                )

                OR (
                    TRY_CONVERT(DECIMAL(38,10), r.dispute_id)
                        IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), r.dispute_id)
                        <> TRY_CONVERT(DECIMAL(38,10),
                            TRY_CONVERT(BIGINT, r.dispute_id))
                )
        )
            THROW 54010, 'Fractional or invalid fee identifier.', 1;

        -- 10. Validate dispute ID category rules
        IF EXISTS (
            SELECT 1
            FROM #FeeSource
            WHERE (
                    fee_type = 'dispute_fee'
                    AND dispute_id IS NULL
                  )
               OR (
                    fee_type <> 'dispute_fee'
                    AND dispute_id IS NOT NULL
                  )
        )
            THROW 54012, 'Invalid dispute fee reference.', 1;

        -- 11. Reject duplicate fee IDs
        IF EXISTS (
            SELECT fee_id
            FROM #FeeSource
            GROUP BY fee_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 54013, 'Duplicate fee IDs.', 1;

        -- 12. One fee per category per intent
        IF EXISTS (
            SELECT intent_id, fee_type
            FROM #FeeSource
            GROUP BY intent_id, fee_type
            HAVING COUNT_BIG(*) > 1
        )
            THROW 54014, 'Duplicate fee category per intent.', 1;

        -- 13. One dispute fee per dispute ID
        IF EXISTS (
            SELECT dispute_id
            FROM #FeeSource
            WHERE dispute_id IS NOT NULL
            GROUP BY dispute_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 54015, 'Duplicate dispute fee.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_FeeSource
            ON #FeeSource(fee_id);

        CREATE NONCLUSTERED INDEX IX_FeeSourceIntent
            ON #FeeSource(intent_id, fee_type);

        -- 14. Validate parent payment and currency
        IF EXISTS (
            SELECT 1
            FROM #FeeSource AS s
            LEFT JOIN main.fact_payment_intent AS p
                WITH (HOLDLOCK)
                ON p.intent_id = s.intent_id
            WHERE p.intent_id IS NULL

               OR p.final_outcome <> 'succeeded'

               OR p.captured_at IS NULL

               OR s.assessed_at < p.captured_at

               OR s.settlement_currency <>
                  p.presentment_currency
        )
            THROW 54016, 'Fee/parent payment mismatch.', 1;

        -- 15. Verify all currencies exist
        IF EXISTS (
            SELECT 1
            FROM #FeeSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_currency AS c
                WHERE c.currency_code = s.settlement_currency
            )
        )
            THROW 54017, 'Unknown settlement currency.', 1;

        -- 16. Validate USD-local equivalence
        -- for USD fees when reporting amount exists.
        IF EXISTS (
            SELECT 1
            FROM #FeeSource
            WHERE settlement_currency = 'USD'
              AND amount_settlement_major_usd IS NOT NULL
              AND ABS(
                    amount_settlement_major_usd
                    - amount_settlement_major
                  ) > 0.00000001
        )
            THROW 54018, 'USD fee conversion mismatch.', 1;

        -- 17. Verify expected capture-generated fees
        -- Each succeeded intent must have exactly
        -- one merchant_fee and one processor_cost.
        IF EXISTS (
            SELECT 1
            FROM main.fact_payment_intent AS p
                WITH (HOLDLOCK)
            LEFT JOIN #FeeSource AS s
                ON s.intent_id = p.intent_id
            WHERE p.final_outcome = 'succeeded'
            GROUP BY p.intent_id
            HAVING COUNT_BIG(
                CASE WHEN s.fee_type = 'merchant_fee'
                     THEN 1 END
            ) <> 1
            OR COUNT_BIG(
                CASE WHEN s.fee_type = 'processor_cost'
                     THEN 1 END
            ) <> 1
        )
            THROW 54019, 'Missing capture-related fee.', 1;

        -- 19. Resolve analytical date key
        SELECT
            s.fee_id,
            s.intent_id,
            s.dispute_id,
            s.assessed_at,

            YEAR(s.assessed_at) * 10000
                + MONTH(s.assessed_at) * 100
                + DAY(s.assessed_at)
                AS assessed_date_key,

            s.fee_type,
            s.settlement_currency,
            s.amount_settlement_major,
            s.amount_settlement_major_usd

        INTO #ResolvedFee
        FROM #FeeSource AS s;

        CREATE UNIQUE CLUSTERED INDEX IX_ResolvedFee
            ON #ResolvedFee(fee_id);

        -- 20. Lock target, reject deleted historical fees
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_fee WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.fact_fee AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #ResolvedFee AS s
                WHERE s.fee_id = d.fee_id
            )
        )
            THROW 54021, 'Historical fee missing from snapshot.', 1;

        -- 21. Protect immutable financial event fields
        IF EXISTS (
            SELECT 1
            FROM main.fact_fee AS d
            INNER JOIN #ResolvedFee AS s
                ON s.fee_id = d.fee_id
            WHERE d.intent_id <> s.intent_id

               OR ISNULL(d.dispute_id, -1)
                    <> ISNULL(s.dispute_id, -1)

               OR d.assessed_at <> s.assessed_at

               OR d.assessed_date_key <>
                    s.assessed_date_key

               OR d.fee_type COLLATE Latin1_General_100_BIN2
                    <> s.fee_type COLLATE Latin1_General_100_BIN2

               OR d.settlement_currency
                    COLLATE Latin1_General_100_BIN2
                    <> s.settlement_currency
                        COLLATE Latin1_General_100_BIN2

               OR d.amount_settlement_major <>
                    s.amount_settlement_major
        )
            THROW 54022, 'Immutable financial fee changed.', 1;

        -- 22. Update only revised USD reporting values
        -- Local-currency financial events remain immutable.
        UPDATE d
        SET
            d.amount_settlement_major_usd =
                s.amount_settlement_major_usd
        FROM main.fact_fee AS d
        INNER JOIN #ResolvedFee AS s
            ON d.fee_id = s.fee_id
        WHERE EXISTS (
            SELECT d.amount_settlement_major_usd
            EXCEPT
            SELECT s.amount_settlement_major_usd
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 23. Insert new fee events
        INSERT INTO main.fact_fee (
            fee_id,
            intent_id,
            dispute_id,
            assessed_at,
            assessed_date_key,
            fee_type,
            settlement_currency,
            amount_settlement_major,
            amount_settlement_major_usd
        )
        SELECT
            s.fee_id,
            s.intent_id,
            s.dispute_id,
            s.assessed_at,
            s.assessed_date_key,
            s.fee_type,
            s.settlement_currency,
            s.amount_settlement_major,
            s.amount_settlement_major_usd
        FROM #ResolvedFee AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_fee AS d
                WITH (UPDLOCK, HOLDLOCK)
            WHERE d.fee_id = s.fee_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 24. Reconcile destination row counts
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.fact_fee;

        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @InsertedRows
            THROW 54023, 'Fee row count reconciliation failed.', 1;

        -- 25. Full bidirectional source/target reconciliation
        IF EXISTS (
            SELECT
                fee_id,
                intent_id,
                dispute_id,
                assessed_at,
                assessed_date_key,
                fee_type COLLATE Latin1_General_100_BIN2,
                settlement_currency
                    COLLATE Latin1_General_100_BIN2,
                amount_settlement_major,
                amount_settlement_major_usd
            FROM #ResolvedFee

            EXCEPT

            SELECT
                fee_id,
                intent_id,
                dispute_id,
                assessed_at,
                assessed_date_key,
                fee_type COLLATE Latin1_General_100_BIN2,
                settlement_currency
                    COLLATE Latin1_General_100_BIN2,
                amount_settlement_major,
                amount_settlement_major_usd
            FROM main.fact_fee
        )
        OR EXISTS (
            SELECT
                fee_id,
                intent_id,
                dispute_id,
                assessed_at,
                assessed_date_key,
                fee_type COLLATE Latin1_General_100_BIN2,
                settlement_currency
                    COLLATE Latin1_General_100_BIN2,
                amount_settlement_major,
                amount_settlement_major_usd
            FROM main.fact_fee

            EXCEPT

            SELECT
                fee_id,
                intent_id,
                dispute_id,
                assessed_at,
                assessed_date_key,
                fee_type COLLATE Latin1_General_100_BIN2,
                settlement_currency
                    COLLATE Latin1_General_100_BIN2,
                amount_settlement_major,
                amount_settlement_major_usd
            FROM #ResolvedFee
        )
            THROW 54024, 'Full fee reconciliation failed.', 1;

        -- 26. Capture execution statistics
        SELECT
            @MerchantFeeRows = COUNT_BIG(
                CASE WHEN fee_type = 'merchant_fee' THEN 1 END
            ),

            @ProcessorCostRows = COUNT_BIG(
                CASE WHEN fee_type = 'processor_cost' THEN 1 END
            ),

            @DisputeFeeRows = COUNT_BIG(
                CASE WHEN fee_type = 'dispute_fee' THEN 1 END
            ),

            @MissingUsdRows = COUNT_BIG(
                CASE
                    WHEN amount_settlement_major_usd IS NULL
                    THEN 1
                END
            )
        FROM main.fact_fee;

        COMMIT TRANSACTION;

        -- 27. Return execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @TargetRows AS target_rows,
            @InsertedRows AS inserted_rows,
            @UpdatedRows AS updated_rows,
            @SourceRows - @InsertedRows - @UpdatedRows
                AS unchanged_rows,
            @MerchantFeeRows AS merchant_fee_rows,
            @ProcessorCostRows AS processor_cost_rows,
            @DisputeFeeRows AS dispute_fee_rows,
            @MissingUsdRows AS missing_usd_rows,
            @LoadUTC AS load_started_utc,
            SYSUTCDATETIME() AS completed_at_utc;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
GO

-- 28. Execute the procedure
EXEC dbo.usp_LoadFactFee;
