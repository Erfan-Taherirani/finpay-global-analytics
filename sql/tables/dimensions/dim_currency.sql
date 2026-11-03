
-- ============================================
-- PROCEDURE: dbo.usp_LoadDimCurrency
-- Full Snapshot + SCD Type 1 + Validations
-- ============================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadDimCurrency
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
        IF OBJECT_ID(N'stg.dim_currency', N'U') IS NULL
            THROW 51001, 'Staging table does not exist.', 1;

        IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
            THROW 51002, 'Destination table does not exist.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent ETL executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_currency',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 51003, 'Could not acquire ETL lock.', 1;

        -- 3. Capture the complete staging snapshot
        SELECT
            currency_code,
            minor_units,
            currency_name
        INTO #RawCurrency
        FROM stg.dim_currency WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawCurrency;

        -- 4. Validate snapshot completeness
        IF @SourceRows <> 10
            THROW 51004, 'Expected exactly 10 currencies.', 1;

        -- 5. Validate required fields and data types
        IF EXISTS (
            SELECT 1
            FROM #RawCurrency
            WHERE currency_code IS NULL
               OR DATALENGTH(
                    CONVERT(VARCHAR(MAX), currency_code)
                  ) <> 3
               OR CONVERT(VARCHAR(MAX), currency_code)
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z][A-Z]'

               OR minor_units IS NULL
               OR NULLIF(
                    TRIM(CONVERT(NVARCHAR(MAX), minor_units)), N''
                  ) IS NULL
               OR TRY_CONVERT(DECIMAL(18,6), minor_units) IS NULL
               OR TRY_CONVERT(DECIMAL(18,6), minor_units)
                    NOT BETWEEN 0 AND 4
               OR TRY_CONVERT(DECIMAL(18,6), minor_units) <>
                    FLOOR(TRY_CONVERT(DECIMAL(18,6), minor_units))

               OR currency_name IS NULL
               OR NULLIF(
                    TRIM(CONVERT(NVARCHAR(MAX), currency_name)), N''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(NVARCHAR(MAX), currency_name))
                  ) > 200
        )
            THROW 51005, 'Invalid currency data.', 1;

        -- 6. Normalize and type source records
        SELECT
            CAST(currency_code AS VARCHAR(3)) AS currency_code,

            CONVERT(
                TINYINT,
                CONVERT(DECIMAL(18,6), minor_units)
            ) AS minor_units,

            CAST(
                TRIM(CONVERT(NVARCHAR(MAX), currency_name))
                AS NVARCHAR(100)
            ) AS currency_name
        INTO #CurrencySource
        FROM #RawCurrency;

        -- 7. Reject duplicate currency codes
        IF EXISTS (
            SELECT currency_code
            FROM #CurrencySource
            GROUP BY currency_code
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51006, 'Duplicate currency codes.', 1;

        -- 8. Validate expected currency codes
        IF EXISTS (
            SELECT 1
            FROM #CurrencySource
            WHERE currency_code COLLATE Latin1_General_100_BIN2
                NOT IN (
                    'USD', 'EUR', 'GBP', 'CAD', 'AUD',
                    'JPY', 'CNY', 'RUB', 'MXN', 'EGP'
                )
        )
            THROW 51007, 'Unexpected currency code.', 1;

        -- 9. Validate decimal precision
        IF EXISTS (
            SELECT 1
            FROM #CurrencySource
            WHERE (currency_code = 'JPY' AND minor_units <> 0)
               OR (currency_code <> 'JPY' AND minor_units <> 2)
        )
            THROW 51008, 'Invalid currency minor units.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_CurrencySource
            ON #CurrencySource(currency_code);

        -- 10. Lock destination and reject target-only records
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.dim_currency WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.dim_currency AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #CurrencySource AS s
                WHERE s.currency_code = d.currency_code
            )
        )
            THROW 51009, 'Existing currency missing from snapshot.', 1;

        -- 11. Update only changed attributes (SCD Type 1)
        UPDATE d
        SET
            d.minor_units = s.minor_units,
            d.currency_name = s.currency_name
        FROM main.dim_currency AS d
        INNER JOIN #CurrencySource AS s
            ON d.currency_code = s.currency_code
        WHERE EXISTS (
            SELECT
                d.minor_units,
                d.currency_name COLLATE Latin1_General_100_BIN2

            EXCEPT

            SELECT
                s.minor_units,
                s.currency_name COLLATE Latin1_General_100_BIN2
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 12. Insert missing currencies
        INSERT INTO main.dim_currency (
            currency_code,
            minor_units,
            currency_name
        )
        SELECT
            s.currency_code,
            s.minor_units,
            s.currency_name
        FROM #CurrencySource AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.dim_currency AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.currency_code = s.currency_code
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 13. Validate destination row count
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.dim_currency;

        IF @TargetRows <> @SourceRows
            THROW 51010, 'Destination row count mismatch.', 1;

        -- 14. Full bidirectional reconciliation
        IF EXISTS (
            SELECT
                currency_code COLLATE Latin1_General_100_BIN2,
                minor_units,
                currency_name COLLATE Latin1_General_100_BIN2
            FROM #CurrencySource

            EXCEPT

            SELECT
                currency_code COLLATE Latin1_General_100_BIN2,
                minor_units,
                currency_name COLLATE Latin1_General_100_BIN2
            FROM main.dim_currency
        )
        OR EXISTS (
            SELECT
                currency_code COLLATE Latin1_General_100_BIN2,
                minor_units,
                currency_name COLLATE Latin1_General_100_BIN2
            FROM main.dim_currency

            EXCEPT

            SELECT
                currency_code COLLATE Latin1_General_100_BIN2,
                minor_units,
                currency_name COLLATE Latin1_General_100_BIN2
            FROM #CurrencySource
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

-- 16. Execute the procedure
EXEC dbo.usp_LoadDimCurrency;
