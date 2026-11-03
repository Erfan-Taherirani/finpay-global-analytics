
-- ====================================================
-- PROCEDURE: dbo.usp_LoadFactFxRate
-- Full Snapshot + Insert + Missing-Rate Backfill
-- ====================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactFxRate
    @ExpectedRowCount BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @InitialRows BIGINT = 0,
        @TargetRows BIGINT = 0,
        @InsertedRows BIGINT = 0,
        @BackfilledRows BIGINT = 0,
        @MissingRates BIGINT = 0,
        @LockResult INT;

    BEGIN TRY

        -- 1. Verify source and destination
        IF OBJECT_ID(N'stg.fact_fx_rate', N'U') IS NULL
            THROW 59001, 'Staging FX table is missing.', 1;

        IF OBJECT_ID(N'main.fact_fx_rate', N'U') IS NULL
            THROW 59002, 'Destination FX table is missing.', 1;

        IF @ExpectedRowCount IS NOT NULL
           AND @ExpectedRowCount <= 0
            THROW 59003, 'Invalid expected row count.', 1;

        BEGIN TRANSACTION;

        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_fx_rate',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 59004, 'Could not acquire ETL lock.', 1;

        -- 2. Capture full staging snapshot
        SELECT
            rate_date,
            currency_code,
            usd_per_major_unit,
            observation_date,
            provider,
            rate_status
        INTO #Raw
        FROM stg.fact_fx_rate WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #Raw;

        IF @SourceRows = 0
           OR (
                @ExpectedRowCount IS NOT NULL
                AND @SourceRows <> @ExpectedRowCount
           )
            THROW 59005, 'Invalid FX snapshot size.', 1;

        -- 3. Essential source-format checks
        IF EXISTS (
            SELECT 1
            FROM #Raw AS r
            WHERE
                DATALENGTH(TRIM(CONVERT(
                    VARCHAR(MAX), r.currency_code
                ))) > 3

                OR DATALENGTH(TRIM(CONVERT(
                    NVARCHAR(MAX), r.provider
                ))) > 200

                OR DATALENGTH(TRIM(CONVERT(
                    NVARCHAR(MAX), r.rate_status
                ))) > 80

                OR (
                    NULLIF(TRIM(CONVERT(
                        VARCHAR(100), r.usd_per_major_unit
                    )), '') IS NOT NULL
                    AND TRY_CONVERT(
                        DECIMAL(28,12), r.usd_per_major_unit
                    ) IS NULL
                )

                OR (
                    NULLIF(TRIM(CONVERT(
                        NVARCHAR(100), r.observation_date
                    )), N'') IS NOT NULL
                    AND TRY_CONVERT(DATE, r.observation_date)
                        IS NULL
                )
        )
            THROW 59006, 'Invalid FX source format.', 1;

        -- 4. Normalize staging records
        SELECT
            TRY_CONVERT(DATE, r.rate_date)
                AS rate_date,

            CAST(UPPER(TRIM(CONVERT(
                VARCHAR(MAX), r.currency_code
            ))) AS VARCHAR(3)) AS currency_code,

            TRY_CONVERT(
                DECIMAL(28,12),
                NULLIF(TRIM(CONVERT(
                    VARCHAR(100), r.usd_per_major_unit
                )), '')
            ) AS usd_per_major_unit,

            TRY_CONVERT(
                DATE,
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), r.observation_date
                )), N'')
            ) AS observation_date,

            CAST(NULLIF(TRIM(CONVERT(
                NVARCHAR(MAX), r.provider
            )), N'') AS NVARCHAR(100)) AS provider,

            CAST(TRIM(CONVERT(
                NVARCHAR(MAX), r.rate_status
            )) AS NVARCHAR(40)) AS rate_status,

            YEAR(TRY_CONVERT(DATE, r.rate_date)) * 10000
                + MONTH(TRY_CONVERT(DATE, r.rate_date)) * 100
                + DAY(TRY_CONVERT(DATE, r.rate_date))
                AS rate_date_key

        INTO #Source
        FROM #Raw AS r;

        -- 5. Validate FX business rules
        IF EXISTS (
            SELECT 1
            FROM #Source AS s
            WHERE s.rate_date IS NULL
               OR s.rate_date < '2021-10-01'
               OR s.rate_date >= '2026-10-01'

               OR s.currency_code IS NULL
               OR DATALENGTH(s.currency_code) <> 3
               OR s.currency_code
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z][A-Z]'

               OR s.rate_status IS NULL
               OR DATALENGTH(s.rate_status) = 0

               OR (
                    s.usd_per_major_unit IS NOT NULL
                    AND s.usd_per_major_unit <= 0
               )

               OR (
                    s.currency_code = 'USD'
                    AND s.usd_per_major_unit IS NOT NULL
                    AND s.usd_per_major_unit <> 1
               )

               OR (
                    s.observation_date IS NOT NULL
                    AND s.observation_date > s.rate_date
               )

               OR (
                    s.currency_code <> 'USD'
                    AND s.usd_per_major_unit IS NOT NULL
                    AND (
                        s.observation_date IS NULL
                        OR s.provider IS NULL
                    )
               )
        )
            THROW 59007, 'FX business validation failed.', 1;

        -- 6. Reject duplicate daily currency rates
        IF EXISTS (
            SELECT rate_date, currency_code
            FROM #Source
            GROUP BY rate_date, currency_code
            HAVING COUNT_BIG(*) > 1
        )
            THROW 59008, 'Duplicate FX date/currency keys.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_SourceFx
            ON #Source(rate_date, currency_code);

        -- 7. Validate dimension references
        IF EXISTS (
            SELECT 1
            FROM #Source AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_currency AS c
                WHERE c.currency_code = s.currency_code
            )
            OR NOT EXISTS (
                SELECT 1
                FROM main.dim_date AS d
                WHERE d.date_key = s.rate_date_key
            )
        )
            THROW 59009, 'Invalid currency or calendar reference.', 1;

        -- 8. Lock target and protect historical rows
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_fx_rate WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.fact_fx_rate AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #Source AS s
                WHERE s.rate_date = d.rate_date
                  AND s.currency_code = d.currency_code
            )
        )
            THROW 59010, 'Existing FX rate missing from snapshot.', 1;

        -- 9. Reject changes to already published rates
        -- The only permitted change is NULL -> valid rate.
        IF EXISTS (
            SELECT 1
            FROM main.fact_fx_rate AS d
            JOIN #Source AS s
                ON s.rate_date = d.rate_date
               AND s.currency_code = d.currency_code
            WHERE EXISTS (
                SELECT
                    d.usd_per_major_unit,
                    d.observation_date,
                    d.provider COLLATE Latin1_General_100_BIN2,
                    d.rate_status COLLATE Latin1_General_100_BIN2

                EXCEPT

                SELECT
                    s.usd_per_major_unit,
                    s.observation_date,
                    s.provider COLLATE Latin1_General_100_BIN2,
                    s.rate_status COLLATE Latin1_General_100_BIN2
            )
            AND NOT (
                d.usd_per_major_unit IS NULL
                AND s.usd_per_major_unit IS NOT NULL
            )
        )
            THROW 59011, 'Existing FX reference data changed.', 1;

        -- 10. Backfill previously missing rates
        UPDATE d
        SET
            d.usd_per_major_unit = s.usd_per_major_unit,
            d.observation_date = s.observation_date,
            d.provider = s.provider,
            d.rate_status = s.rate_status
        FROM main.fact_fx_rate AS d
        JOIN #Source AS s
            ON s.rate_date = d.rate_date
           AND s.currency_code = d.currency_code
        WHERE d.usd_per_major_unit IS NULL
          AND s.usd_per_major_unit IS NOT NULL;

        SET @BackfilledRows = @@ROWCOUNT;

        -- 11. Insert new daily FX records
        INSERT INTO main.fact_fx_rate (
            rate_date,
            currency_code,
            usd_per_major_unit,
            observation_date,
            provider,
            rate_status,
            rate_date_key
        )
        SELECT
            s.rate_date,
            s.currency_code,
            s.usd_per_major_unit,
            s.observation_date,
            s.provider,
            s.rate_status,
            s.rate_date_key
        FROM #Source AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_fx_rate AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.rate_date = s.rate_date
              AND d.currency_code = s.currency_code
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 12. Essential post-load reconciliation
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.fact_fx_rate;

        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @InsertedRows
            THROW 59012, 'FX row count reconciliation failed.', 1;

        IF EXISTS (
            SELECT
                rate_date,
                currency_code,
                usd_per_major_unit,
                observation_date,
                provider COLLATE Latin1_General_100_BIN2,
                rate_status COLLATE Latin1_General_100_BIN2,
                rate_date_key
            FROM #Source

            EXCEPT

            SELECT
                rate_date,
                currency_code,
                usd_per_major_unit,
                observation_date,
                provider COLLATE Latin1_General_100_BIN2,
                rate_status COLLATE Latin1_General_100_BIN2,
                rate_date_key
            FROM main.fact_fx_rate
        )
            THROW 59013, 'FX snapshot reconciliation failed.', 1;

        SELECT @MissingRates = COUNT_BIG(*)
        FROM main.fact_fx_rate
        WHERE usd_per_major_unit IS NULL;

        COMMIT TRANSACTION;

        -- 13. Execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @TargetRows AS target_rows,
            @InsertedRows AS inserted_rows,
            @BackfilledRows AS backfilled_rates,
            @SourceRows - @InsertedRows - @BackfilledRows
                AS unchanged_rows,
            @MissingRates AS missing_rates,
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
EXEC dbo.usp_LoadFactFxRate;
