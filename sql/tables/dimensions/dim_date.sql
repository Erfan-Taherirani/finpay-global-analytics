
-- ============================================
-- PROCEDURE: dbo.usp_LoadDimDate
-- Full Snapshot + Upsert + Validations
-- ============================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadDimDate
    @ExpectedStartDate DATE = '20211001',
    @ExpectedEndDate DATE = '20260930'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @TargetRows BIGINT = 0,
        @UpdatedRows INT = 0,
        @InsertedRows INT = 0,
        @ExpectedRows INT,
        @LockResult INT;

    BEGIN TRY

        -- 1. Verify source and destination
        IF OBJECT_ID(N'stg.dim_date', N'U') IS NULL
            THROW 51001, 'Staging table does not exist.', 1;

        IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
            THROW 51002, 'Destination table does not exist.', 1;

        -- 2. Validate configured date range
        IF @ExpectedStartDate IS NULL
           OR @ExpectedEndDate IS NULL
           OR @ExpectedStartDate > @ExpectedEndDate
           OR @ExpectedStartDate < '19000101'
            THROW 51003, 'Invalid expected date range.', 1;

        SET @ExpectedRows =
            DATEDIFF(DAY, @ExpectedStartDate, @ExpectedEndDate) + 1;

        BEGIN TRANSACTION;

        -- 3. Prevent concurrent ETL executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_date',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 51004, 'Could not acquire ETL lock.', 1;

        -- 4. Capture the complete staging snapshot
        SELECT
            date_key,
            date_utc,
            [year],
            [month],
            day_of_month,
            [week],
            day_of_week,
            is_business_day,
            month_start,
            month_end,
            is_weekend
        INTO #RawDate
        FROM stg.dim_date WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawDate;

        -- 5. Validate snapshot completeness
        IF @SourceRows <> @ExpectedRows
            THROW 51005, 'Incomplete date snapshot.', 1;

        -- 6. Validate required fields and conversions
        IF EXISTS (
            SELECT 1
            FROM #RawDate
            WHERE TRY_CONVERT(INT, date_key) IS NULL
               OR TRY_CONVERT(DATE, date_utc) IS NULL
               OR TRY_CONVERT(DATETIME2(7), date_utc) IS NULL
               OR TRY_CONVERT(DATETIME2(7), date_utc) <>
                    CONVERT(
                        DATETIME2(7),
                        TRY_CONVERT(DATE, date_utc)
                    )

               OR TRY_CONVERT(SMALLINT, [year]) IS NULL
               OR TRY_CONVERT(TINYINT, [month]) IS NULL
               OR TRY_CONVERT(TINYINT, day_of_month) IS NULL
               OR TRY_CONVERT(TINYINT, [week]) IS NULL
               OR TRY_CONVERT(TINYINT, day_of_week) IS NULL

               OR TRY_CONVERT(DATE, month_start) IS NULL
               OR TRY_CONVERT(DATE, month_end) IS NULL

               OR TRY_CONVERT(DATETIME2(7), month_start) <>
                    CONVERT(
                        DATETIME2(7),
                        TRY_CONVERT(DATE, month_start)
                    )

               OR TRY_CONVERT(DATETIME2(7), month_end) <>
                    CONVERT(
                        DATETIME2(7),
                        TRY_CONVERT(DATE, month_end)
                    )

               OR is_business_day IS NULL
               OR LOWER(TRIM(CONVERT(VARCHAR(50), is_business_day)))
                    NOT IN ('0', '1', 'true', 'false')

               OR is_weekend IS NULL
               OR LOWER(TRIM(CONVERT(VARCHAR(50), is_weekend)))
                    NOT IN ('0', '1', 'true', 'false')
        )
            THROW 51006, 'Invalid date data or data types.', 1;

        -- 7. Normalize and type source records
        SELECT
            CONVERT(INT, date_key) AS date_key,
            CONVERT(DATE, date_utc) AS date_utc,
            CONVERT(SMALLINT, [year]) AS [year],
            CONVERT(TINYINT, [month]) AS [month],
            CONVERT(TINYINT, day_of_month) AS day_of_month,
            CONVERT(TINYINT, [week]) AS [week],
            CONVERT(TINYINT, day_of_week) AS day_of_week,

            CONVERT(
                BIT,
                CASE
                    WHEN LOWER(TRIM(CONVERT(VARCHAR(50), is_business_day)))
                         IN ('1', 'true') THEN 1
                    ELSE 0
                END
            ) AS is_business_day,

            CONVERT(DATE, month_start) AS month_start,
            CONVERT(DATE, month_end) AS month_end,

            CONVERT(
                BIT,
                CASE
                    WHEN LOWER(TRIM(CONVERT(VARCHAR(50), is_weekend)))
                         IN ('1', 'true') THEN 1
                    ELSE 0
                END
            ) AS is_weekend

        INTO #DateSource
        FROM #RawDate;

        -- 8. Reject duplicate dates and keys
        IF EXISTS (
            SELECT date_key
            FROM #DateSource
            GROUP BY date_key
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51007, 'Duplicate date keys.', 1;

        IF EXISTS (
            SELECT date_utc
            FROM #DateSource
            GROUP BY date_utc
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51008, 'Duplicate calendar dates.', 1;

        -- 9. Validate derived calendar attributes
        IF EXISTS (
            SELECT 1
            FROM #DateSource AS s
            WHERE s.date_key <>
                    YEAR(s.date_utc) * 10000
                    + MONTH(s.date_utc) * 100
                    + DAY(s.date_utc)

               OR s.[year] <> YEAR(s.date_utc)
               OR s.[month] <> MONTH(s.date_utc)
               OR s.day_of_month <> DAY(s.date_utc)

               OR s.[week] <> DATEPART(ISO_WEEK, s.date_utc)

               OR s.day_of_week <>
                    DATEDIFF(
                        DAY,
                        CONVERT(DATE, '19000101', 112),
                        s.date_utc
                    ) % 7 + 1

               OR s.month_start <>
                    DATEFROMPARTS(
                        YEAR(s.date_utc),
                        MONTH(s.date_utc),
                        1
                    )

               OR s.month_end <> EOMONTH(s.date_utc)

               OR s.is_weekend <>
                    CASE
                        WHEN s.day_of_week IN (6, 7) THEN 1
                        ELSE 0
                    END

               OR s.is_business_day <>
                    CASE
                        WHEN s.day_of_week BETWEEN 1 AND 5 THEN 1
                        ELSE 0
                    END
        )
            THROW 51009, 'Calendar attributes are inconsistent.', 1;

        -- 10. Validate date range and continuous coverage
        IF (SELECT MIN(date_utc) FROM #DateSource) <> @ExpectedStartDate
           OR (SELECT MAX(date_utc) FROM #DateSource) <> @ExpectedEndDate
            THROW 51010, 'Date range mismatch.', 1;

        -- Count + unique dates + min/max guarantee no gaps.

        CREATE UNIQUE CLUSTERED INDEX IX_DateSource
            ON #DateSource(date_key);

        -- 11. Lock destination and reject target-only dates
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.dim_date WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.dim_date AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #DateSource AS s
                WHERE s.date_key = d.date_key
            )
        )
            THROW 51011, 'Existing date missing from snapshot.', 1;

        -- 12. Update only changed attributes
        UPDATE d
        SET
            d.date_utc = s.date_utc,
            d.[year] = s.[year],
            d.[month] = s.[month],
            d.day_of_month = s.day_of_month,
            d.[week] = s.[week],
            d.day_of_week = s.day_of_week,
            d.is_business_day = s.is_business_day,
            d.month_start = s.month_start,
            d.month_end = s.month_end,
            d.is_weekend = s.is_weekend
        FROM main.dim_date AS d
        INNER JOIN #DateSource AS s
            ON d.date_key = s.date_key
        WHERE EXISTS (
            SELECT
                d.date_utc,
                d.[year],
                d.[month],
                d.day_of_month,
                d.[week],
                d.day_of_week,
                d.is_business_day,
                d.month_start,
                d.month_end,
                d.is_weekend

            EXCEPT

            SELECT
                s.date_utc,
                s.[year],
                s.[month],
                s.day_of_month,
                s.[week],
                s.day_of_week,
                s.is_business_day,
                s.month_start,
                s.month_end,
                s.is_weekend
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 13. Insert missing dates
        INSERT INTO main.dim_date (
            date_key,
            date_utc,
            [year],
            [month],
            day_of_month,
            [week],
            day_of_week,
            is_business_day,
            month_start,
            month_end,
            is_weekend
        )
        SELECT
            s.date_key,
            s.date_utc,
            s.[year],
            s.[month],
            s.day_of_month,
            s.[week],
            s.day_of_week,
            s.is_business_day,
            s.month_start,
            s.month_end,
            s.is_weekend
        FROM #DateSource AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.dim_date AS d WITH (UPDLOCK, HOLDLOCK)
            WHERE d.date_key = s.date_key
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 14. Reconcile destination row count
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.dim_date;

        IF @TargetRows <> @SourceRows
            THROW 51012, 'Destination row count mismatch.', 1;

        -- 15. Full bidirectional attribute reconciliation
        IF EXISTS (
            SELECT
                date_key, date_utc, [year], [month],
                day_of_month, [week], day_of_week,
                is_business_day, month_start, month_end,
                is_weekend
            FROM #DateSource

            EXCEPT

            SELECT
                date_key, date_utc, [year], [month],
                day_of_month, [week], day_of_week,
                is_business_day, month_start, month_end,
                is_weekend
            FROM main.dim_date
        )
        OR EXISTS (
            SELECT
                date_key, date_utc, [year], [month],
                day_of_month, [week], day_of_week,
                is_business_day, month_start, month_end,
                is_weekend
            FROM main.dim_date

            EXCEPT

            SELECT
                date_key, date_utc, [year], [month],
                day_of_month, [week], day_of_week,
                is_business_day, month_start, month_end,
                is_weekend
            FROM #DateSource
        )
            THROW 51013, 'Full snapshot reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 16. Return execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @TargetRows AS target_rows,
            @UpdatedRows AS updated_rows,
            @InsertedRows AS inserted_rows,
            @SourceRows - @UpdatedRows - @InsertedRows
                AS unchanged_rows,
            @ExpectedStartDate AS first_date,
            @ExpectedEndDate AS last_date,
            SYSUTCDATETIME() AS completed_at_utc;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
GO

-- 17. Execute the stored procedure
EXEC dbo.usp_LoadDimDate;
