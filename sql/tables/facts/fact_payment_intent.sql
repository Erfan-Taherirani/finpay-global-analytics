
-- ======================================================
-- PROCEDURE: dbo.usp_LoadFactPaymentIntent
-- Full Snapshot + Upsert + Integrated Validations
-- SQL Server
-- ======================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactPaymentIntent
    @ExpectedIntentCount BIGINT = 1620000,
    @StartDate DATETIME2(6) = '2021-10-01T00:00:00',
    @SnapshotCutoff DATETIME2(6) = '2026-10-01T00:00:00'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @ResolvedRows BIGINT = 0,
        @InitialRows BIGINT = 0,
        @TargetRows BIGINT = 0,
        @UpdatedRows BIGINT = 0,
        @InsertedRows BIGINT = 0,
        @LockResult INT,
        @LoadUTC DATETIME2(7);

    BEGIN TRY

        -- 1. Verify prerequisites
        IF OBJECT_ID(N'stg.fact_payment_intent', N'U') IS NULL
            THROW 52001, 'Staging fact_payment_intent missing.', 1;

        IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
            THROW 52002, 'Destination fact_payment_intent missing.', 1;

        IF @ExpectedIntentCount IS NULL
           OR @ExpectedIntentCount <= 0
           OR @StartDate IS NULL
           OR @SnapshotCutoff IS NULL
           OR @StartDate >= @SnapshotCutoff
            THROW 52003, 'Invalid ETL parameters.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_payment_intent',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 52004, 'Could not acquire ETL lock.', 1;

        SET @LoadUTC = SYSUTCDATETIME();

        -- 3. Capture the full staging snapshot
        SELECT
            intent_id,
            merchant_id,
            customer_id,
            created_at,
            buyer_country,
            checkout_channel,
            presentment_currency,
            final_outcome,
            closed_at,
            captured_at,
            amount_major,
            captured_settlement_major,
            payment_resolution_time,
            time_to_capture,
            amount_major_usd,
            captured_settlement_major_usd
        INTO #RawIntent
        FROM stg.fact_payment_intent WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawIntent;

        -- 4. Verify complete historical snapshot
        IF @SourceRows <> @ExpectedIntentCount
            THROW 52005, 'Unexpected payment intent count.', 1;

        -- 5. Reject overlong text and invalid optional numerics
        -- before conversion/truncation
        IF EXISTS (
            SELECT 1
            FROM #RawIntent AS r
            WHERE
                DATALENGTH(TRIM(
                    CONVERT(VARCHAR(MAX), r.buyer_country)
                )) > 2

                OR DATALENGTH(TRIM(
                    CONVERT(VARCHAR(MAX), r.checkout_channel)
                )) > 50

                OR DATALENGTH(TRIM(
                    CONVERT(VARCHAR(MAX), r.presentment_currency)
                )) > 3

                OR DATALENGTH(TRIM(
                    CONVERT(VARCHAR(MAX), r.final_outcome)
                )) > 20

                OR (
                    NULLIF(TRIM(
                        CONVERT(VARCHAR(100), r.customer_id)
                    ), '') IS NOT NULL
                    AND TRY_CONVERT(BIGINT, r.customer_id) IS NULL
                )

                OR (
                    NULLIF(TRIM(
                        CONVERT(NVARCHAR(100), r.closed_at)
                    ), N'') IS NOT NULL
                    AND TRY_CONVERT(
                        DATETIME2(6), r.closed_at
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(
                        CONVERT(NVARCHAR(100), r.captured_at)
                    ), N'') IS NOT NULL
                    AND TRY_CONVERT(
                        DATETIME2(6), r.captured_at
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.captured_settlement_major
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(19,4), r.captured_settlement_major
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.payment_resolution_time
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(20,3), r.payment_resolution_time
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.time_to_capture
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(20,3), r.time_to_capture
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.amount_major_usd
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(28,8), r.amount_major_usd
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.captured_settlement_major_usd
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(28,8), r.captured_settlement_major_usd
                    ) IS NULL
                )
        )
            THROW 52006, 'Invalid source field or length.', 1;

        -- 6. Normalize and type staging records
        SELECT
            TRY_CONVERT(BIGINT, r.intent_id)
                AS intent_id,

            TRY_CONVERT(BIGINT, r.merchant_id)
                AS merchant_id,

            TRY_CONVERT(
                BIGINT,
                NULLIF(TRIM(
                    CONVERT(VARCHAR(100), r.customer_id)
                ), '')
            ) AS customer_id,

            TRY_CONVERT(DATETIME2(6), r.created_at)
                AS created_at,

            CAST(NULLIF(UPPER(TRIM(
                CONVERT(VARCHAR(20), r.buyer_country)
            )), '') AS VARCHAR(2))
                AS buyer_country,

            CAST(TRIM(CONVERT(
                VARCHAR(MAX), r.checkout_channel
            )) AS VARCHAR(50))
                AS checkout_channel,

            CAST(UPPER(TRIM(CONVERT(
                VARCHAR(20), r.presentment_currency
            ))) AS VARCHAR(3))
                AS presentment_currency,

            CAST(LOWER(TRIM(CONVERT(
                VARCHAR(30), r.final_outcome
            ))) AS VARCHAR(20))
                AS final_outcome,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), r.closed_at
                )), N'')
            ) AS closed_at,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), r.captured_at
                )), N'')
            ) AS captured_at,

            TRY_CONVERT(
                DECIMAL(19,4), r.amount_major
            ) AS amount_major,

            TRY_CONVERT(
                DECIMAL(19,4),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.captured_settlement_major
                )), '')
            ) AS captured_settlement_major,

            TRY_CONVERT(
                DECIMAL(20,3),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.payment_resolution_time
                )), '')
            ) AS payment_resolution_time,

            TRY_CONVERT(
                DECIMAL(20,3),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.time_to_capture
                )), '')
            ) AS time_to_capture,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.amount_major_usd
                )), '')
            ) AS amount_major_usd,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.captured_settlement_major_usd
                )), '')
            ) AS captured_settlement_major_usd

        INTO #IntentSource
        FROM #RawIntent AS r;

        -- 7. Validate required values and codes
        IF EXISTS (
            SELECT 1
            FROM #IntentSource AS s
            WHERE s.intent_id IS NULL
               OR s.intent_id <= 0
               OR s.merchant_id IS NULL
               OR s.merchant_id <= 0
               OR (s.customer_id IS NOT NULL AND s.customer_id <= 0)

               OR s.created_at IS NULL
               OR s.created_at < @StartDate
               OR s.created_at >= @SnapshotCutoff

               OR s.checkout_channel IS NULL
               OR DATALENGTH(s.checkout_channel) = 0

               OR s.presentment_currency IS NULL
               OR DATALENGTH(s.presentment_currency) <> 3
               OR s.presentment_currency
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z][A-Z]'

               OR (
                    s.buyer_country IS NOT NULL
                    AND (
                        DATALENGTH(s.buyer_country) <> 2
                        OR s.buyer_country
                            COLLATE Latin1_General_100_BIN2
                            NOT LIKE '[A-Z][A-Z]'
                    )
               )

               OR s.final_outcome IS NULL
               OR s.final_outcome NOT IN (
                    'succeeded', 'failed', 'abandoned', 'pending'
               )

               OR s.amount_major IS NULL
               OR s.amount_major <= 0

               OR (
                    s.captured_settlement_major IS NOT NULL
                    AND s.captured_settlement_major < 0
               )

               OR (
                    s.amount_major_usd IS NOT NULL
                    AND s.amount_major_usd < 0
               )

               OR (
                    s.captured_settlement_major_usd IS NOT NULL
                    AND s.captured_settlement_major_usd < 0
               )
        )
            THROW 52007, 'Required-field validation failed.', 1;

        -- 8. Reject duplicate payment intents
        IF EXISTS (
            SELECT intent_id
            FROM #IntentSource
            GROUP BY intent_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 52008, 'Duplicate intent IDs.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_IntentSource
            ON #IntentSource(intent_id);

        -- 10. Validate USD amount parity when supplied
        -- The project reports using created-date FX.
        IF EXISTS (
            SELECT 1
            FROM #IntentSource AS s
            WHERE
                (
                    s.presentment_currency = 'USD'
                    AND s.amount_major_usd IS NOT NULL
                    AND ABS(
                        s.amount_major_usd - s.amount_major
                    ) > 0.00000001
                )
                OR (
                    s.presentment_currency = 'USD'
                    AND s.captured_settlement_major_usd IS NOT NULL
                    AND s.captured_settlement_major IS NOT NULL
                    AND ABS(
                        s.captured_settlement_major_usd
                        - s.captured_settlement_major
                    ) > 0.00000001
                )
                OR (
                    s.final_outcome = 'succeeded'
                    AND (
                        (
                            s.amount_major_usd IS NULL
                            AND s.captured_settlement_major_usd IS NOT NULL
                        )
                        OR (
                            s.amount_major_usd IS NOT NULL
                            AND s.captured_settlement_major_usd IS NULL
                        )
                        OR (
                            s.amount_major_usd IS NOT NULL
                            AND s.captured_settlement_major_usd IS NOT NULL
                            AND ABS(
                                s.amount_major_usd
                                - s.captured_settlement_major_usd
                            ) > 0.00000001
                        )
                    )
                )
        )
            THROW 52011, 'USD amount consistency failed.', 1;

        -- 12. Validate currency and buyer market references
        IF EXISTS (
            SELECT 1
            FROM #IntentSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_currency AS c
                WHERE c.currency_code = s.presentment_currency
            )
            OR (
                s.buyer_country IS NOT NULL
                AND NOT EXISTS (
                    SELECT 1
                    FROM main.dim_market AS m
                    WHERE m.country_code = s.buyer_country
                )
            )
        )
            THROW 52012, 'Invalid currency or buyer market.', 1;

        -- 12. Resolve historical dimension versions
        -- Version 1 is the baseline for pre-ETL facts.
        -- Later versions use their true validity intervals.
        SELECT
            s.*,
            m.merchant_sk,
            c.customer_sk,

            YEAR(s.created_at) * 10000
                + MONTH(s.created_at) * 100
                + DAY(s.created_at) AS created_date_key,

            m.settlement_currency
                AS resolved_settlement_currency,

            c.signed_up_at
                AS resolved_signed_up_at

        INTO #ResolvedIntent
        FROM #IntentSource AS s

        LEFT JOIN main.dim_merchant AS m
            ON m.merchant_id = s.merchant_id
           AND (
                s.created_at >= m.valid_from
                OR m.version_number = 1
           )
           AND s.created_at < m.valid_to

        LEFT JOIN main.dim_customer AS c
            ON c.customer_id = s.customer_id
           AND (
                s.created_at >= c.valid_from
                OR c.version_number = 1
           )
           AND s.created_at < c.valid_to;

        SELECT @ResolvedRows = COUNT_BIG(*)
        FROM #ResolvedIntent;

        -- 13. Reject duplicate or missing SCD matches
        IF @ResolvedRows <> @SourceRows
            THROW 52013, 'Ambiguous SCD Type 2 dimension match.', 1;

        IF EXISTS (
            SELECT intent_id
            FROM #ResolvedIntent
            GROUP BY intent_id
            HAVING COUNT_BIG(*) <> 1
        )
            THROW 52014, 'Multiple dimension versions matched.', 1;

        IF EXISTS (
            SELECT 1
            FROM #ResolvedIntent AS r
            WHERE r.merchant_sk IS NULL
               OR (
                    r.customer_id IS NOT NULL
                    AND r.customer_sk IS NULL
               )
        )
            THROW 52015, 'Missing merchant or customer version.', 1;

        -- 14. Verify registration precedes payment
        IF EXISTS (
            SELECT 1
            FROM #ResolvedIntent
            WHERE customer_id IS NOT NULL
              AND created_at < resolved_signed_up_at
        )
            THROW 52016, 'Payment predates customer registration.', 1;

        -- 15. Check merchant settlement currency
        IF EXISTS (
            SELECT 1
            FROM #ResolvedIntent
            WHERE resolved_settlement_currency <>
                  presentment_currency
        )
            THROW 52017, 'Merchant settlement currency mismatch.', 1;

        -- 16. Verify date-dimension coverage
        IF EXISTS (
            SELECT 1
            FROM #ResolvedIntent AS r
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_date AS d
                WHERE d.date_key = r.created_date_key
            )
        )
            THROW 52018, 'Missing date dimension key.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_ResolvedIntent
            ON #ResolvedIntent(intent_id);

        -- 17. Lock target and reject missing snapshot IDs
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_payment_intent WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.fact_payment_intent AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #ResolvedIntent AS s
                WHERE s.intent_id = d.intent_id
            )
        )
            THROW 52019, 'Existing intent missing from snapshot.', 1;

        -- 18. Protect immutable transaction identity fields
        IF EXISTS (
            SELECT 1
            FROM main.fact_payment_intent AS d
            JOIN #ResolvedIntent AS s
                ON s.intent_id = d.intent_id
            WHERE d.merchant_id <> s.merchant_id
               OR ISNULL(d.customer_id, -1) <>
                  ISNULL(s.customer_id, -1)
               OR d.created_at <> s.created_at
               OR d.presentment_currency <>
                  s.presentment_currency
               OR d.amount_major <> s.amount_major
        )
            THROW 52020, 'Immutable intent attributes changed.', 1;

        -- 19. Do not reverse a finalized outcome
        IF EXISTS (
            SELECT 1
            FROM main.fact_payment_intent AS d
            JOIN #ResolvedIntent AS s
                ON s.intent_id = d.intent_id
            WHERE d.final_outcome <> 'pending'
              AND d.final_outcome <> s.final_outcome
        )
            THROW 52021, 'A finalized payment outcome changed.', 1;

        -- 20. Update changed records only
        UPDATE d
        SET
            d.merchant_sk = s.merchant_sk,
            d.customer_sk = s.customer_sk,
            d.created_date_key = s.created_date_key,
            d.buyer_country = s.buyer_country,
            d.checkout_channel = s.checkout_channel,
            d.final_outcome = s.final_outcome,
            d.closed_at = s.closed_at,
            d.captured_at = s.captured_at,
            d.captured_settlement_major =
                s.captured_settlement_major,
            d.payment_resolution_time =
                s.payment_resolution_time,
            d.time_to_capture = s.time_to_capture,
            d.amount_major_usd = s.amount_major_usd,
            d.captured_settlement_major_usd =
                s.captured_settlement_major_usd
        FROM main.fact_payment_intent AS d
        JOIN #ResolvedIntent AS s
            ON s.intent_id = d.intent_id
        WHERE EXISTS (
            SELECT
                d.merchant_sk,
                d.customer_sk,
                d.created_date_key,
                d.buyer_country,
                d.checkout_channel
                    COLLATE Latin1_General_100_BIN2,
                d.final_outcome
                    COLLATE Latin1_General_100_BIN2,
                d.closed_at,
                d.captured_at,
                d.captured_settlement_major,
                d.payment_resolution_time,
                d.time_to_capture,
                d.amount_major_usd,
                d.captured_settlement_major_usd

            EXCEPT

            SELECT
                s.merchant_sk,
                s.customer_sk,
                s.created_date_key,
                s.buyer_country,
                s.checkout_channel
                    COLLATE Latin1_General_100_BIN2,
                s.final_outcome
                    COLLATE Latin1_General_100_BIN2,
                s.closed_at,
                s.captured_at,
                s.captured_settlement_major,
                s.payment_resolution_time,
                s.time_to_capture,
                s.amount_major_usd,
                s.captured_settlement_major_usd
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 21. Insert new payment intents
        INSERT INTO main.fact_payment_intent (
            intent_id,
            merchant_id,
            customer_id,
            merchant_sk,
            customer_sk,
            created_date_key,
            created_at,
            buyer_country,
            checkout_channel,
            presentment_currency,
            final_outcome,
            closed_at,
            captured_at,
            amount_major,
            captured_settlement_major,
            payment_resolution_time,
            time_to_capture,
            amount_major_usd,
            captured_settlement_major_usd
        )
        SELECT
            s.intent_id,
            s.merchant_id,
            s.customer_id,
            s.merchant_sk,
            s.customer_sk,
            s.created_date_key,
            s.created_at,
            s.buyer_country,
            s.checkout_channel,
            s.presentment_currency,
            s.final_outcome,
            s.closed_at,
            s.captured_at,
            s.amount_major,
            s.captured_settlement_major,
            s.payment_resolution_time,
            s.time_to_capture,
            s.amount_major_usd,
            s.captured_settlement_major_usd
        FROM #ResolvedIntent AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_payment_intent AS d
                WITH (UPDLOCK, HOLDLOCK)
            WHERE d.intent_id = s.intent_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 22. Reconcile destination row counts
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.fact_payment_intent;

        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @InsertedRows
            THROW 52022, 'Fact row count reconciliation failed.', 1;

        -- 23. Complete source-to-target reconciliation
        -- Includes technical surrogate keys.
        IF EXISTS (
            SELECT
                intent_id, merchant_id, customer_id,
                merchant_sk, customer_sk, created_date_key,
                created_at, buyer_country,
                checkout_channel COLLATE Latin1_General_100_BIN2,
                presentment_currency COLLATE Latin1_General_100_BIN2,
                final_outcome COLLATE Latin1_General_100_BIN2,
                closed_at, captured_at, amount_major,
                captured_settlement_major,
                payment_resolution_time, time_to_capture,
                amount_major_usd, captured_settlement_major_usd
            FROM #ResolvedIntent

            EXCEPT

            SELECT
                intent_id, merchant_id, customer_id,
                merchant_sk, customer_sk, created_date_key,
                created_at, buyer_country,
                checkout_channel COLLATE Latin1_General_100_BIN2,
                presentment_currency COLLATE Latin1_General_100_BIN2,
                final_outcome COLLATE Latin1_General_100_BIN2,
                closed_at, captured_at, amount_major,
                captured_settlement_major,
                payment_resolution_time, time_to_capture,
                amount_major_usd, captured_settlement_major_usd
            FROM main.fact_payment_intent
        )
        OR EXISTS (
            SELECT
                intent_id, merchant_id, customer_id,
                merchant_sk, customer_sk, created_date_key,
                created_at, buyer_country,
                checkout_channel COLLATE Latin1_General_100_BIN2,
                presentment_currency COLLATE Latin1_General_100_BIN2,
                final_outcome COLLATE Latin1_General_100_BIN2,
                closed_at, captured_at, amount_major,
                captured_settlement_major,
                payment_resolution_time, time_to_capture,
                amount_major_usd, captured_settlement_major_usd
            FROM main.fact_payment_intent

            EXCEPT

            SELECT
                intent_id, merchant_id, customer_id,
                merchant_sk, customer_sk, created_date_key,
                created_at, buyer_country,
                checkout_channel COLLATE Latin1_General_100_BIN2,
                presentment_currency COLLATE Latin1_General_100_BIN2,
                final_outcome COLLATE Latin1_General_100_BIN2,
                closed_at, captured_at, amount_major,
                captured_settlement_major,
                payment_resolution_time, time_to_capture,
                amount_major_usd, captured_settlement_major_usd
            FROM #ResolvedIntent
        )
            THROW 52023, 'Full snapshot reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 24. Execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @TargetRows AS target_rows,
            @InsertedRows AS inserted_rows,
            @UpdatedRows AS updated_rows,
            @SourceRows - @InsertedRows - @UpdatedRows
                AS unchanged_rows,
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

-- 25. Execute the stored procedure
EXEC dbo.usp_LoadFactPaymentIntent;
