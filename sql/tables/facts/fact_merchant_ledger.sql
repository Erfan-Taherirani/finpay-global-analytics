
-- =====================================================
-- PROCEDURE: dbo.usp_LoadFactMerchantLedger
-- Immutable Postings + Financial Reconciliation
-- =====================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactMerchantLedger
    @ExpectedRowCount BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @ExpectedRows BIGINT = 0,
        @TargetRows BIGINT = 0,
        @InitialRows BIGINT = 0,
        @InsertedRows BIGINT = 0,
        @UpdatedRows BIGINT = 0,
        @LockResult INT;

    BEGIN TRY

        -- 1. Verify required tables
        IF OBJECT_ID(N'stg.fact_merchant_ledger', N'U') IS NULL
            THROW 58001, 'Staging ledger is missing.', 1;

        IF OBJECT_ID(N'main.fact_merchant_ledger', N'U') IS NULL
            THROW 58002, 'Destination ledger is missing.', 1;

        IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
           OR OBJECT_ID(N'main.fact_fee', N'U') IS NULL
           OR OBJECT_ID(N'main.fact_refund', N'U') IS NULL
           OR OBJECT_ID(N'main.fact_dispute', N'U') IS NULL
           OR OBJECT_ID(N'main.fact_settlement', N'U') IS NULL
            THROW 58003, 'Load the originating facts first.', 1;

        IF @ExpectedRowCount IS NOT NULL
           AND @ExpectedRowCount <= 0
            THROW 58004, 'Invalid expected row count.', 1;

        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_merchant_ledger',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 58005, 'Could not acquire ETL lock.', 1;

        -- 2. Capture staging snapshot
        SELECT
            entry_id,
            merchant_id,
            currency_code,
            posted_at,
            event_type,
            source_id,
            signed_amount_major,
            signed_amount_major_usd
        INTO #Raw
        FROM stg.fact_merchant_ledger
            WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #Raw;

        IF @SourceRows = 0
           OR (
                @ExpectedRowCount IS NOT NULL
                AND @SourceRows <> @ExpectedRowCount
           )
            THROW 58006, 'Invalid ledger snapshot size.', 1;

        -- 3. Reject overlong values before casting
        IF EXISTS (
            SELECT 1
            FROM #Raw
            WHERE DATALENGTH(TRIM(CONVERT(
                    VARCHAR(MAX), event_type
                  ))) > 30
               OR DATALENGTH(TRIM(CONVERT(
                    VARCHAR(MAX), currency_code
                  ))) > 3
        )
            THROW 58007, 'Ledger text exceeds column size.', 1;

        -- 4. Normalize staging data
        SELECT
            TRY_CONVERT(BIGINT, entry_id) AS entry_id,
            TRY_CONVERT(BIGINT, merchant_id) AS merchant_id,

            CAST(UPPER(TRIM(
                CONVERT(VARCHAR(MAX), currency_code)
            )) AS VARCHAR(3)) AS currency_code,

            TRY_CONVERT(DATETIME2(6), posted_at)
                AS posted_at,

            CAST(LOWER(TRIM(
                CONVERT(VARCHAR(MAX), event_type)
            )) AS VARCHAR(30)) AS event_type,

            TRY_CONVERT(BIGINT, source_id) AS source_id,

            TRY_CONVERT(
                DECIMAL(19,4), signed_amount_major
            ) AS signed_amount_major,

            TRY_CONVERT(
                DECIMAL(28,8),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), signed_amount_major_usd
                )), '')
            ) AS signed_amount_major_usd

        INTO #Source
        FROM #Raw;

        -- 5. Essential data and sign validation
        IF EXISTS (
            SELECT 1
            FROM #Source AS s
            WHERE s.entry_id IS NULL OR s.entry_id <= 0
               OR s.merchant_id IS NULL OR s.merchant_id <= 0
               OR s.source_id IS NULL OR s.source_id <= 0

               OR s.posted_at IS NULL
               OR s.posted_at < '2021-10-01'
               OR s.posted_at >= '2026-10-01'

               OR s.currency_code IS NULL
               OR DATALENGTH(s.currency_code) <> 3

               OR s.event_type IS NULL
               OR s.event_type COLLATE Latin1_General_100_BIN2
                  NOT IN (
                    'capture_credit',
                    'merchant_fee_debit',
                    'refund_debit',
                    'dispute_debit',
                    'dispute_fee_debit',
                    'payout_debit'
                  )

               OR s.signed_amount_major IS NULL
               OR s.signed_amount_major = 0

               OR (
                    s.event_type = 'capture_credit'
                    AND s.signed_amount_major < 0
               )

               OR (
                    s.event_type <> 'capture_credit'
                    AND s.signed_amount_major > 0
               )

               OR (
                    s.signed_amount_major_usd IS NOT NULL
                    AND (
                        (s.signed_amount_major > 0
                         AND s.signed_amount_major_usd <= 0)
                        OR
                        (s.signed_amount_major < 0
                         AND s.signed_amount_major_usd >= 0)
                    )
               )
        )
            THROW 58008, 'Invalid ledger posting.', 1;

        -- 6. Unique entries and originating events
        IF EXISTS (
            SELECT entry_id
            FROM #Source
            GROUP BY entry_id
            HAVING COUNT_BIG(*) > 1
        )
        OR EXISTS (
            SELECT event_type, source_id
            FROM #Source
            GROUP BY event_type, source_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 58009, 'Duplicate ledger entry or source event.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_SourceLedger
            ON #Source(entry_id);

        CREATE UNIQUE NONCLUSTERED INDEX IX_SourceEvent
            ON #Source(event_type, source_id);

        -- 7. Construct expected postings from
        -- actual originating financial events.
        SELECT
            CAST('capture_credit' AS VARCHAR(30))
                AS event_type,
            p.intent_id AS source_id,
            p.merchant_id,
            p.presentment_currency AS currency_code,
            p.captured_settlement_major
                AS signed_amount_major,
            p.captured_at AS event_at
        INTO #Expected
        FROM main.fact_payment_intent AS p
        WHERE p.final_outcome = 'succeeded'

        UNION ALL

        SELECT
            'merchant_fee_debit',
            f.fee_id,
            p.merchant_id,
            f.settlement_currency,
            -f.amount_settlement_major,
            f.assessed_at
        FROM main.fact_fee AS f
        JOIN main.fact_payment_intent AS p
            ON p.intent_id = f.intent_id
        WHERE f.fee_type = 'merchant_fee'

        UNION ALL

        SELECT
            'refund_debit',
            r.refund_id,
            p.merchant_id,
            r.currency_code,
            -r.settlement_debit_major,
            r.completed_at
        FROM main.fact_refund AS r
        JOIN main.fact_payment_intent AS p
            ON p.intent_id = r.intent_id
        WHERE r.[status] IN ('succeeded', 'completed')

        UNION ALL

        SELECT
            'dispute_debit',
            d.dispute_id,
            p.merchant_id,
            d.currency_code,
            -d.settlement_debit_major,
            d.resolved_at
        FROM main.fact_dispute AS d
        JOIN main.fact_payment_intent AS p
            ON p.intent_id = d.intent_id
        WHERE d.[status] = 'lost'

        UNION ALL

        SELECT
            'dispute_fee_debit',
            f.fee_id,
            p.merchant_id,
            f.settlement_currency,
            -f.amount_settlement_major,
            f.assessed_at
        FROM main.fact_fee AS f
        JOIN main.fact_dispute AS d
            ON d.dispute_id = f.dispute_id
           AND d.[status] = 'lost'
        JOIN main.fact_payment_intent AS p
            ON p.intent_id = f.intent_id
        WHERE f.fee_type = 'dispute_fee'

        UNION ALL

        SELECT
            'payout_debit',
            s.settlement_id,
            s.merchant_id,
            s.currency_code,
            -s.amount_major,
            s.completed_at
        FROM main.fact_settlement AS s
        WHERE s.[status] = 'completed';

        SELECT @ExpectedRows = COUNT_BIG(*)
        FROM #Expected;

        CREATE UNIQUE CLUSTERED INDEX IX_ExpectedEvent
            ON #Expected(event_type, source_id);

        -- Posting cannot precede its financial event.
        IF EXISTS (
            SELECT 1
            FROM #Source AS s
            JOIN #Expected AS e
                ON e.event_type = s.event_type
               AND e.source_id = s.source_id
            WHERE s.posted_at < e.event_at
        )
            THROW 58012, 'Posting precedes originating event.', 1;

        -- 9. Resolve historical merchant version
        -- and derive exact integer minor-unit amounts.
        SELECT
            s.*,
            m.merchant_sk,

            YEAR(s.posted_at) * 10000
                + MONTH(s.posted_at) * 100
                + DAY(s.posted_at)
                AS posted_date_key,

            x.scaled_minor,
            TRY_CONVERT(BIGINT, x.scaled_minor)
                AS signed_amount_minor

        INTO #Resolved
        FROM #Source AS s

        LEFT JOIN main.dim_currency AS c
            ON c.currency_code = s.currency_code

        OUTER APPLY (
            SELECT TOP (1)
                d.merchant_sk
            FROM main.dim_merchant AS d WITH (HOLDLOCK)
            WHERE d.merchant_id = s.merchant_id
              AND (
                  (
                    s.posted_at >= d.valid_from
                    AND s.posted_at < d.valid_to
                  )
                  OR
                  (
                    d.version_number = 1
                    AND s.posted_at < d.valid_from
                  )
              )
            ORDER BY d.version_number DESC
        ) AS m

        CROSS APPLY (
            SELECT
                s.signed_amount_major *
                CAST(
                    CASE c.minor_units
                        WHEN 0 THEN 1
                        WHEN 1 THEN 10
                        WHEN 2 THEN 100
                        WHEN 3 THEN 1000
                        WHEN 4 THEN 10000
                    END AS DECIMAL(10,0)
                ) AS scaled_minor
        ) AS x;

        CREATE UNIQUE CLUSTERED INDEX IX_ResolvedLedger
            ON #Resolved(entry_id);

        -- 11. Preserve existing financial postings
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_merchant_ledger
            WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.fact_merchant_ledger AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #Resolved AS s
                WHERE s.entry_id = d.entry_id
            )
        )
            THROW 58014, 'Existing ledger entry missing.', 1;

        -- Financial identity and local amounts
        -- are immutable after first insertion.
        IF EXISTS (
            SELECT 1
            FROM main.fact_merchant_ledger AS d
            JOIN #Resolved AS s
                ON s.entry_id = d.entry_id
            WHERE d.merchant_id <> s.merchant_id
               OR d.merchant_sk <> s.merchant_sk
               OR d.currency_code <> s.currency_code
               OR d.posted_at <> s.posted_at
               OR d.posted_date_key <> s.posted_date_key
               OR d.event_type <> s.event_type
               OR d.source_id <> s.source_id
               OR d.signed_amount_major <> s.signed_amount_major
               OR d.signed_amount_minor <> s.signed_amount_minor
        )
            THROW 58015, 'Immutable ledger posting changed.', 1;

        -- 12. Update only the USD reporting value
        UPDATE d
        SET
            d.signed_amount_major_usd =
                s.signed_amount_major_usd
        FROM main.fact_merchant_ledger AS d
        JOIN #Resolved AS s
            ON s.entry_id = d.entry_id
        WHERE EXISTS (
            SELECT d.signed_amount_major_usd
            EXCEPT
            SELECT s.signed_amount_major_usd
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 13. Insert new financial postings
        INSERT INTO main.fact_merchant_ledger (
            entry_id,
            merchant_id,
            merchant_sk,
            currency_code,
            posted_at,
            posted_date_key,
            event_type,
            source_id,
            signed_amount_major,
            signed_amount_minor,
            signed_amount_major_usd
        )
        SELECT
            s.entry_id,
            s.merchant_id,
            s.merchant_sk,
            s.currency_code,
            s.posted_at,
            s.posted_date_key,
            s.event_type,
            s.source_id,
            s.signed_amount_major,
            s.signed_amount_minor,
            s.signed_amount_major_usd
        FROM #Resolved AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_merchant_ledger AS d
                WITH (UPDLOCK, HOLDLOCK)
            WHERE d.entry_id = s.entry_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 14. Post-load reconciliation
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.fact_merchant_ledger;

        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @InsertedRows
            THROW 58016, 'Ledger row count mismatch.', 1;

        IF EXISTS (
            SELECT
                entry_id, merchant_id, merchant_sk,
                currency_code, posted_at, posted_date_key,
                event_type, source_id,
                signed_amount_major, signed_amount_minor,
                signed_amount_major_usd
            FROM #Resolved

            EXCEPT

            SELECT
                entry_id, merchant_id, merchant_sk,
                currency_code, posted_at, posted_date_key,
                event_type, source_id,
                signed_amount_major, signed_amount_minor,
                signed_amount_major_usd
            FROM main.fact_merchant_ledger
        )
            THROW 58017, 'Ledger snapshot reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 15. Execution summary
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
EXEC dbo.usp_LoadFactMerchantLedger;
