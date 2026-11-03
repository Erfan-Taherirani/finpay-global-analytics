
-- ============================================
-- PROCEDURE: dbo.usp_LoadDimMarket
-- Full Snapshot + SCD Type 1 + Validations
-- ============================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadDimMarket
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @TargetRows BIGINT = 0,
        @UpdatedRows INT = 0,
        @InsertedRows INT = 0,
        @LockResult INT;

    BEGIN TRY

        -- 1. Verify source and destination
        IF OBJECT_ID(N'stg.dim_market', N'U') IS NULL
            THROW 51001, 'Staging table does not exist.', 1;

        IF OBJECT_ID(N'main.dim_market', N'U') IS NULL
            THROW 51002, 'Destination table does not exist.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent ETL executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_market',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 51003, 'Could not acquire ETL lock.', 1;

        -- 3. Capture the complete staging snapshot
        SELECT
            country_code,
            market_name,
            currency_code,
            [timezone]
        INTO #RawMarket
        FROM stg.dim_market WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawMarket;

        -- 4. Validate snapshot completeness
        IF @SourceRows <> 12
            THROW 51004, 'Expected exactly 12 markets.', 1;

        -- 5. Validate required fields and lengths
        IF EXISTS (
            SELECT 1
            FROM #RawMarket
            WHERE country_code IS NULL
               OR DATALENGTH(CONVERT(VARCHAR(MAX), country_code)) <> 2
               OR CONVERT(VARCHAR(MAX), country_code)
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z]'

               OR market_name IS NULL
               OR NULLIF(
                    TRIM(CONVERT(NVARCHAR(MAX), market_name)), N''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(NVARCHAR(MAX), market_name))
                  ) > 300

               OR currency_code IS NULL
               OR DATALENGTH(CONVERT(VARCHAR(MAX), currency_code)) <> 3
               OR CONVERT(VARCHAR(MAX), currency_code)
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z][A-Z]'

               OR [timezone] IS NULL
               OR NULLIF(
                    TRIM(CONVERT(VARCHAR(MAX), [timezone])), ''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(VARCHAR(MAX), [timezone]))
                  ) > 100
        )
            THROW 51005, 'Invalid market data.', 1;

        -- 6. Normalize source records
        SELECT
            CAST(country_code AS VARCHAR(2)) AS country_code,
            CAST(
                TRIM(CONVERT(NVARCHAR(MAX), market_name))
                AS NVARCHAR(150)
            ) AS market_name,
            CAST(currency_code AS VARCHAR(3)) AS currency_code,
            CAST(
                TRIM(CONVERT(VARCHAR(MAX), [timezone]))
                AS VARCHAR(100)
            ) AS [timezone]
        INTO #MarketSource
        FROM #RawMarket;

        -- 7. Reject duplicate country codes
        IF EXISTS (
            SELECT country_code
            FROM #MarketSource
            GROUP BY country_code
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51006, 'Duplicate country codes.', 1;

        -- 8. Validate country-to-currency mapping
        -- 12 markets, 10 currencies; Iran uses USD
        IF EXISTS (
            SELECT 1
            FROM #MarketSource AS s
            LEFT JOIN (
                VALUES
                    ('US', 'USD'),
                    ('GB', 'GBP'),
                    ('DE', 'EUR'),
                    ('FR', 'EUR'),
                    ('CA', 'CAD'),
                    ('AU', 'AUD'),
                    ('JP', 'JPY'),
                    ('CN', 'CNY'),
                    ('IR', 'USD'),
                    ('RU', 'RUB'),
                    ('MX', 'MXN'),
                    ('EG', 'EGP')
            ) AS expected(country_code, currency_code)
                ON s.country_code = expected.country_code
            WHERE expected.country_code IS NULL
               OR s.currency_code <> expected.currency_code
        )
            THROW 51007, 'Invalid market or currency mapping.', 1;

        -- 9. Validate currency foreign keys
        IF EXISTS (
            SELECT 1
            FROM #MarketSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_currency AS c
                WHERE c.currency_code = s.currency_code
            )
        )
            THROW 51008, 'Unknown currency code.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_MarketSource
            ON #MarketSource(country_code);

        -- 10. Lock destination and reject target-only keys
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.dim_market WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.dim_market AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #MarketSource AS s
                WHERE s.country_code = d.country_code
            )
        )
            THROW 51009, 'Existing market missing from snapshot.', 1;

        -- 11. Update changed records (SCD Type 1)
        UPDATE d
        SET
            d.market_name = s.market_name,
            d.currency_code = s.currency_code,
            d.[timezone] = s.[timezone]
        FROM main.dim_market AS d
        INNER JOIN #MarketSource AS s
            ON d.country_code = s.country_code
        WHERE EXISTS (
            SELECT
                d.market_name COLLATE Latin1_General_100_BIN2,
                d.currency_code COLLATE Latin1_General_100_BIN2,
                d.[timezone] COLLATE Latin1_General_100_BIN2
            EXCEPT
            SELECT
                s.market_name COLLATE Latin1_General_100_BIN2,
                s.currency_code COLLATE Latin1_General_100_BIN2,
                s.[timezone] COLLATE Latin1_General_100_BIN2
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 12. Insert missing markets
        INSERT INTO main.dim_market (
            country_code,
            market_name,
            currency_code,
            [timezone]
        )
        SELECT
            s.country_code,
            s.market_name,
            s.currency_code,
            s.[timezone]
        FROM #MarketSource AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.dim_market AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.country_code = s.country_code
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 13. Validate destination row count
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.dim_market;

        IF @TargetRows <> @SourceRows
            THROW 51010, 'Destination row count mismatch.', 1;

        -- 14. Full bidirectional reconciliation
        IF EXISTS (
            SELECT
                country_code,
                market_name COLLATE Latin1_General_100_BIN2,
                currency_code COLLATE Latin1_General_100_BIN2,
                [timezone] COLLATE Latin1_General_100_BIN2
            FROM #MarketSource

            EXCEPT

            SELECT
                country_code,
                market_name COLLATE Latin1_General_100_BIN2,
                currency_code COLLATE Latin1_General_100_BIN2,
                [timezone] COLLATE Latin1_General_100_BIN2
            FROM main.dim_market
        )
        OR EXISTS (
            SELECT
                country_code,
                market_name COLLATE Latin1_General_100_BIN2,
                currency_code COLLATE Latin1_General_100_BIN2,
                [timezone] COLLATE Latin1_General_100_BIN2
            FROM main.dim_market

            EXCEPT

            SELECT
                country_code,
                market_name COLLATE Latin1_General_100_BIN2,
                currency_code COLLATE Latin1_General_100_BIN2,
                [timezone] COLLATE Latin1_General_100_BIN2
            FROM #MarketSource
        )
            THROW 51011, 'Full snapshot reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 15. Execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @TargetRows AS target_rows,
            @UpdatedRows AS updated_rows,
            @InsertedRows AS inserted_rows,
            @SourceRows - @UpdatedRows - @InsertedRows
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

-- 16. Execute the stored procedure
EXEC dbo.usp_LoadDimMarket;
