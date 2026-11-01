
CREATE OR ALTER PROCEDURE dbo.usp_LoadDimMerchant
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT,
        @UpdatedRows INT = 0,
        @InsertedRows INT = 0,
        @LockResult INT;

    BEGIN TRY

        -- 1. Check source table
        IF OBJECT_ID(N'stg.dim_merchant', N'U') IS NULL
            THROW 50001, 'Source table does not exist.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent ETL executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_merchant',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50002, 'Could not acquire ETL lock.', 1;

        -- 3. Snapshot the staging records
        SELECT
            merchant_id, merchant_name, country_code,
            industry, onboarded_at, settlement_currency,
            pricing_tier, payout_frequency, account_status
        INTO #RawMerchant
        FROM stg.dim_merchant;

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawMerchant;

        IF @SourceRows = 0
            THROW 50003, 'Staging table is empty.', 1;

        -- 4. Validate required fields and data types
        IF EXISTS (
            SELECT 1
            FROM #RawMerchant
            WHERE TRY_CONVERT(BIGINT, merchant_id) IS NULL
               OR TRY_CONVERT(BIGINT, merchant_id) <= 0
               OR NULLIF(TRIM(CONVERT(NVARCHAR(MAX), merchant_name)), N'') IS NULL
               OR LEN(TRIM(CONVERT(NVARCHAR(MAX), merchant_name))) > 200
               OR NULLIF(TRIM(CONVERT(NVARCHAR(MAX), industry)), N'') IS NULL
               OR LEN(TRIM(CONVERT(NVARCHAR(MAX), industry))) > 100
               OR NULLIF(TRIM(CONVERT(NVARCHAR(100), onboarded_at)), N'') IS NULL
               OR TRY_CONVERT(DATETIME2(3), onboarded_at) IS NULL
               OR TRY_CONVERT(DATETIME2(3), onboarded_at) > SYSUTCDATETIME()
               OR NULLIF(TRIM(CONVERT(VARCHAR(MAX), pricing_tier)), '') IS NULL
               OR LEN(TRIM(CONVERT(VARCHAR(MAX), pricing_tier))) > 30
               OR NULLIF(TRIM(CONVERT(VARCHAR(MAX), payout_frequency)), '') IS NULL
               OR LEN(TRIM(CONVERT(VARCHAR(MAX), payout_frequency))) > 30
               OR NULLIF(TRIM(CONVERT(VARCHAR(MAX), account_status)), '') IS NULL
               OR LEN(TRIM(CONVERT(VARCHAR(MAX), account_status))) > 30
               OR country_code IS NULL
               OR DATALENGTH(CONVERT(VARCHAR(100), country_code)) <> 2
               OR CONVERT(VARCHAR(100), country_code)
                   COLLATE Latin1_General_100_BIN2 NOT LIKE '[A-Z][A-Z]'
               OR settlement_currency IS NULL
               OR DATALENGTH(CONVERT(VARCHAR(100), settlement_currency)) <> 3
               OR CONVERT(VARCHAR(100), settlement_currency)
                   COLLATE Latin1_General_100_BIN2 NOT LIKE '[A-Z][A-Z][A-Z]'
        )
            THROW 50004, 'Invalid merchant data.', 1;

        -- 5. Normalize and type the source
        SELECT
            TRY_CONVERT(BIGINT, merchant_id) AS merchant_id,
            CAST(TRIM(CONVERT(NVARCHAR(MAX), merchant_name)) AS NVARCHAR(200))
                AS merchant_name,
            CAST(country_code AS VARCHAR(2)) AS country_code,
            CAST(TRIM(CONVERT(NVARCHAR(MAX), industry)) AS NVARCHAR(100))
                AS industry,
            TRY_CONVERT(DATETIME2(3), onboarded_at) AS onboarded_at,
            CAST(settlement_currency AS VARCHAR(3)) AS settlement_currency,
            CAST(TRIM(CONVERT(VARCHAR(MAX), pricing_tier)) AS VARCHAR(30))
                AS pricing_tier,
            CAST(TRIM(CONVERT(VARCHAR(MAX), payout_frequency)) AS VARCHAR(30))
                AS payout_frequency,
            CAST(TRIM(CONVERT(VARCHAR(MAX), account_status)) AS VARCHAR(30))
                AS account_status
        INTO #MerchantSource
        FROM #RawMerchant;

        -- 6. Reject duplicate merchant IDs
        IF EXISTS (
            SELECT merchant_id
            FROM #MerchantSource
            GROUP BY merchant_id
            HAVING COUNT(*) > 1
        )
            THROW 50005, 'Duplicate merchant IDs.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_MerchantSource
            ON #MerchantSource(merchant_id);

        -- 7. Verify settlement currency references
        IF EXISTS (
            SELECT 1
            FROM #MerchantSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_currency AS c
                WHERE c.currency_code = s.settlement_currency
            )
        )
            THROW 50006, 'Unknown settlement currency.', 1;

        -- 8. Update existing merchants only when changed
        UPDATE d
        SET
            d.merchant_name = s.merchant_name,
            d.country_code = s.country_code,
            d.industry = s.industry,
            d.onboarded_at = s.onboarded_at,
            d.settlement_currency = s.settlement_currency,
            d.pricing_tier = s.pricing_tier,
            d.payout_frequency = s.payout_frequency,
            d.account_status = s.account_status
        FROM main.dim_merchant AS d
        INNER JOIN #MerchantSource AS s
            ON d.merchant_id = s.merchant_id
        WHERE EXISTS (
            SELECT
                d.merchant_name, d.country_code, d.industry,
                d.onboarded_at, d.settlement_currency,
                d.pricing_tier, d.payout_frequency,
                d.account_status
            EXCEPT
            SELECT
                s.merchant_name, s.country_code, s.industry,
                s.onboarded_at, s.settlement_currency,
                s.pricing_tier, s.payout_frequency,
                s.account_status
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 9. Insert new merchants
        INSERT INTO main.dim_merchant (
            merchant_id, merchant_name, country_code,
            industry, onboarded_at, settlement_currency,
            pricing_tier, payout_frequency, account_status
        )
        SELECT
            s.merchant_id, s.merchant_name, s.country_code,
            s.industry, s.onboarded_at, s.settlement_currency,
            s.pricing_tier, s.payout_frequency, s.account_status
        FROM #MerchantSource AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.dim_merchant AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.merchant_id = s.merchant_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 10. Reconcile source keys
        IF EXISTS (
            SELECT 1
            FROM #MerchantSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_merchant AS d
                WHERE d.merchant_id = s.merchant_id
            )
        )
            THROW 50007, 'Merchant key reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 11. Return execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @UpdatedRows AS updated_rows,
            @InsertedRows AS inserted_rows,
            @SourceRows - @UpdatedRows - @InsertedRows AS unchanged_rows,
            SYSUTCDATETIME() AS completed_at_utc;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
GO


EXEC dbo.usp_LoadDimMerchant;


-- 1. Completeness and uniqueness
SELECT
    COUNT_BIG(*) AS total_merchants,
    COUNT(DISTINCT merchant_id) AS unique_merchant_ids,
    SUM(CASE WHEN merchant_name IS NULL
                 OR LEN(TRIM(merchant_name)) = 0
             THEN 1 ELSE 0 END) AS invalid_names,
    SUM(CASE WHEN industry IS NULL
                 OR LEN(TRIM(industry)) = 0
             THEN 1 ELSE 0 END) AS invalid_industries
FROM main.dim_merchant;

-- 2. Referential integrity
SELECT COUNT_BIG(*) AS invalid_currencies
FROM main.dim_merchant AS m
LEFT JOIN main.dim_currency AS c
    ON m.settlement_currency = c.currency_code
WHERE c.currency_code IS NULL;

-- 3. Distribution of merchant statuses
SELECT
    account_status,
    COUNT_BIG(*) AS merchant_count
FROM main.dim_merchant
GROUP BY account_status
ORDER BY merchant_count DESC;

-- 4. Merchant coverage by country
SELECT
    country_code,
    COUNT_BIG(*) AS merchant_count
FROM main.dim_merchant
GROUP BY country_code
ORDER BY country_code;

SELECT DISTINCT pricing_tier FROM stg.dim_merchant;
SELECT DISTINCT payout_frequency FROM stg.dim_merchant;
SELECT DISTINCT account_status FROM stg.dim_merchant;
SELECT DISTINCT industry FROM stg.dim_merchant;
