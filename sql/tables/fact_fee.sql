
CREATE OR ALTER PROCEDURE dbo.usp_LoadFactFee
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT,
        @UpdatedRows INT = 0,
        @InsertedRows INT = 0,
        @MissingFxRows BIGINT,
        @LockResult INT;

    BEGIN TRY
        -- 1. Verify source table
        IF OBJECT_ID(N'stg.fact_fee', N'U') IS NULL
            THROW 50001, 'Staging fact_fee does not exist.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent procedure executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_fee',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50002, 'Could not acquire ETL lock.', 1;

        -- 3. Validate text fields before conversion
        IF EXISTS (
            SELECT 1
            FROM stg.fact_fee
            WHERE fee_type IS NULL
               OR fee_type COLLATE Latin1_General_100_BIN2
                  NOT IN ('merchant_fee', 'processor_cost', 'dispute_fee')
               OR settlement_currency IS NULL
               OR DATALENGTH(CONVERT(VARCHAR(100), settlement_currency)) <> 3
               OR settlement_currency COLLATE Latin1_General_100_BIN2
                  NOT LIKE '[A-Z][A-Z][A-Z]'
        )
            THROW 50003, 'Invalid fee type or currency.', 1;

        -- 4. Snapshot staging with destination data types
        SELECT
            CAST(fee_id AS BIGINT) AS fee_id,
            CAST(intent_id AS BIGINT) AS intent_id,
            CAST(dispute_id AS BIGINT) AS dispute_id,
            CAST(assessed_at AS DATETIME2(3)) AS assessed_at,
            CAST(fee_type AS VARCHAR(20)) AS fee_type,
            CAST(settlement_currency AS VARCHAR(3)) AS settlement_currency,
            CAST(amount_settlement_major AS DECIMAL(19,4))
                AS amount_settlement_major,
            CAST(amount_settlement_major_usd AS DECIMAL(28,8))
                AS amount_settlement_major_usd
        INTO #FeeSource
        FROM stg.fact_fee;

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #FeeSource;

        IF @SourceRows = 0
            THROW 50004, 'Staging table is empty.', 1;

        -- 5. Validate required fields and business rules
        IF EXISTS (
            SELECT 1
            FROM #FeeSource
            WHERE fee_id IS NULL OR fee_id <= 0
               OR intent_id IS NULL OR intent_id <= 0
               OR (dispute_id IS NOT NULL AND dispute_id <= 0)
               OR assessed_at IS NULL
               OR amount_settlement_major IS NULL
               OR amount_settlement_major < 0
               OR amount_settlement_major_usd < 0
               OR (fee_type = 'dispute_fee' AND dispute_id IS NULL)
               OR (fee_type <> 'dispute_fee' AND dispute_id IS NOT NULL)
        )
            THROW 50005, 'Invalid fee records.', 1;

        -- 6. Reject duplicate fee IDs
        IF EXISTS (
            SELECT fee_id
            FROM #FeeSource
            GROUP BY fee_id
            HAVING COUNT(*) > 1
        )
            THROW 50006, 'Duplicate fee IDs.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_FeeSource
            ON #FeeSource(fee_id);

        -- 7. Validate currency references
        IF EXISTS (
            SELECT 1
            FROM #FeeSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_currency AS c
                WHERE c.currency_code = s.settlement_currency
            )
        )
            THROW 50007, 'Unknown settlement currency.', 1;

        -- 8. Update existing records only when changed
        UPDATE d
        SET
            d.intent_id = s.intent_id,
            d.dispute_id = s.dispute_id,
            d.assessed_at = s.assessed_at,
            d.fee_type = s.fee_type,
            d.settlement_currency = s.settlement_currency,
            d.amount_settlement_major = s.amount_settlement_major,
            d.amount_settlement_major_usd = s.amount_settlement_major_usd
        FROM main.fact_fee AS d
        INNER JOIN #FeeSource AS s
            ON d.fee_id = s.fee_id
        WHERE EXISTS (
            SELECT
                d.intent_id, d.dispute_id, d.assessed_at,
                d.fee_type, d.settlement_currency,
                d.amount_settlement_major,
                d.amount_settlement_major_usd
            EXCEPT
            SELECT
                s.intent_id, s.dispute_id, s.assessed_at,
                s.fee_type, s.settlement_currency,
                s.amount_settlement_major,
                s.amount_settlement_major_usd
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 9. Insert new fees
        INSERT INTO main.fact_fee (
            fee_id, intent_id, dispute_id, assessed_at,
            fee_type, settlement_currency,
            amount_settlement_major,
            amount_settlement_major_usd
        )
        SELECT
            s.fee_id, s.intent_id, s.dispute_id, s.assessed_at,
            s.fee_type, s.settlement_currency,
            s.amount_settlement_major,
            s.amount_settlement_major_usd
        FROM #FeeSource AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_fee AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.fee_id = s.fee_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 10. Count fees without USD conversion
        SELECT @MissingFxRows = COUNT_BIG(*)
        FROM #FeeSource
        WHERE amount_settlement_major_usd IS NULL;

        COMMIT TRANSACTION;

        -- 11. Execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @UpdatedRows AS updated_rows,
            @InsertedRows AS inserted_rows,
            @MissingFxRows AS missing_usd_rows,
            SYSUTCDATETIME() AS completed_at_utc;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
GO


-- Execute the ETL procedure
EXEC dbo.usp_LoadFactFee;

-- Verify loaded data
SELECT
    COUNT_BIG(*) AS total_fees,
    COUNT(DISTINCT fee_id) AS unique_fees,
    SUM(CASE WHEN amount_settlement_major_usd IS NULL
             THEN 1 ELSE 0 END) AS missing_usd_rows
FROM main.fact_fee;

-- Verify fee types
SELECT fee_type, COUNT_BIG(*) AS fee_count
FROM main.fact_fee
GROUP BY fee_type
ORDER BY fee_type;
