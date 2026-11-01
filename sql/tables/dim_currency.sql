
CREATE OR ALTER PROCEDURE dbo.usp_LoadDimCurrency
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows INT,
        @UpdatedRows INT,
        @InsertedRows INT,
        @LockResult INT;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- 1. Prevent concurrent executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_currency',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult < 0
            THROW 50001, 'Could not acquire ETL lock.', 1;

        -- 2. Snapshot the staging dataset
        SELECT
            currency_code,
            minor_units,
            currency_name
        INTO #SourceCurrency
        FROM stg.dim_currency;

        SET @SourceRows = @@ROWCOUNT;

        -- 3. Validate expected source row count
        IF @SourceRows <> 10
            THROW 50002, 'Expected exactly 10 currencies.', 1;

        -- 4. Validate currency codes and minor units
        IF EXISTS (
            SELECT 1
            FROM #SourceCurrency
            WHERE currency_code IS NULL
               OR currency_code COLLATE Latin1_General_100_BIN2
                  NOT LIKE '[A-Z][A-Z][A-Z]'
               OR DATALENGTH(CONVERT(VARCHAR(100), currency_code)) <> 3
               OR TRY_CONVERT(DECIMAL(18,6), minor_units)
                  NOT IN (0, 1, 2, 3, 4)
               OR minor_units IS NULL
        )
            THROW 50003, 'Invalid currency data.', 1;

        -- 5. Reject duplicate currency codes
        IF EXISTS (
            SELECT currency_code
            FROM #SourceCurrency
            GROUP BY currency_code
            HAVING COUNT(*) > 1
        )
            THROW 50004, 'Duplicate currency codes.', 1;

        -- 6. Prevent accidental deletion of existing keys
        IF EXISTS (
            SELECT 1
            FROM main.dim_currency AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #SourceCurrency AS s
                WHERE s.currency_code = d.currency_code
            )
        )
            THROW 50005, 'Existing currency missing from staging.', 1;

        -- 7. Update changed records
        UPDATE d
        SET d.minor_units = CAST(s.minor_units AS TINYINT)
        FROM main.dim_currency AS d
        JOIN #SourceCurrency AS s
            ON d.currency_code = s.currency_code
        WHERE d.minor_units <> CAST(s.minor_units AS TINYINT);

        SET @UpdatedRows = @@ROWCOUNT;

        -- 8. Insert new records
        INSERT INTO main.dim_currency (
            currency_code,
            minor_units,
            currency_name
        )
        SELECT
            s.currency_code,
            CAST(s.minor_units AS TINYINT),
            s.currency_code
        FROM #SourceCurrency AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.dim_currency AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.currency_code = s.currency_code
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 9. Final reconciliation
        IF (SELECT COUNT(*) FROM main.dim_currency) <> @SourceRows
            THROW 50006, 'Destination row count mismatch.', 1;

        COMMIT TRANSACTION;

        -- 10. Return execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @UpdatedRows AS updated_rows,
            @InsertedRows AS inserted_rows,
            SYSDATETIME() AS completed_at;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
GO
