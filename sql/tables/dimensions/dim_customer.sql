
-- ====================================================
-- PROCEDURE: dbo.usp_LoadDimCustomer
-- Full Snapshot + SCD Type 2 + Validations
-- ====================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadDimCustomer
    @ExpectedCustomerCount INT = 100000,
    @SnapshotCutoff DATETIME2(6) = '2026-10-01T00:00:00'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @CurrentRows BIGINT = 0,
        @HistoryRows BIGINT = 0,
        @InitialHistoryRows BIGINT = 0,
        @NewCustomers BIGINT = 0,
        @ChangedCustomers BIGINT = 0,
        @ExpiredVersions BIGINT = 0,
        @InsertedVersions BIGINT = 0,
        @LockResult INT,
        @LoadUTC DATETIME2(7),
        @OpenEnded DATETIME2(7) =
            '9999-12-31T23:59:59.9999999';

    BEGIN TRY

        -- 1. Verify source and destination
        IF OBJECT_ID(N'stg.dim_customer', N'U') IS NULL
            THROW 51001, 'Staging table does not exist.', 1;

        IF OBJECT_ID(N'main.dim_customer', N'U') IS NULL
            THROW 51002, 'Destination table does not exist.', 1;

        IF @ExpectedCustomerCount IS NULL
           OR @ExpectedCustomerCount <= 0
           OR @SnapshotCutoff IS NULL
            THROW 51003, 'Invalid ETL parameters.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent ETL executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_customer',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 51004, 'Could not acquire ETL lock.', 1;

        -- 3. Capture the complete staging snapshot
        SELECT
            customer_id,
            signed_up_at,
            country_code,
            acquisition_channel,
            is_verified
        INTO #RawCustomer
        FROM stg.dim_customer WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawCustomer;

        -- 4. Validate snapshot completeness
        IF @SourceRows <> @ExpectedCustomerCount
            THROW 51005, 'Unexpected customer count.', 1;

        -- 5. Validate required fields and data types
        IF EXISTS (
            SELECT 1
            FROM #RawCustomer
            WHERE customer_id IS NULL
               OR TRY_CONVERT(BIGINT, customer_id) IS NULL
               OR TRY_CONVERT(BIGINT, customer_id) <= 0

               OR (
                    TRY_CONVERT(DECIMAL(38,10), customer_id)
                    IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), customer_id) <>
                        TRY_CONVERT(
                            DECIMAL(38,10),
                            TRY_CONVERT(BIGINT, customer_id)
                        )
               )

               OR signed_up_at IS NULL
               OR TRY_CONVERT(DATETIME2(6), signed_up_at) IS NULL
               OR TRY_CONVERT(DATETIME2(6), signed_up_at)
                    >= @SnapshotCutoff

               OR country_code IS NULL
               OR DATALENGTH(
                    CONVERT(VARCHAR(MAX), country_code)
                  ) <> 2
               OR CONVERT(VARCHAR(MAX), country_code)
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z]'

               OR acquisition_channel IS NULL
               OR NULLIF(
                    TRIM(
                        CONVERT(NVARCHAR(MAX), acquisition_channel)
                    ), N''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(
                        CONVERT(NVARCHAR(MAX), acquisition_channel)
                    )
                  ) > 200

               OR is_verified IS NULL
               OR LOWER(
                    TRIM(CONVERT(VARCHAR(20), is_verified))
                  ) NOT IN ('0', '1', 'true', 'false')
        )
            THROW 51006, 'Invalid customer data.', 1;

        -- 6. Normalize and type the source
        SELECT
            CONVERT(BIGINT, customer_id) AS customer_id,

            CONVERT(DATETIME2(6), signed_up_at)
                AS signed_up_at,

            CAST(country_code AS VARCHAR(2))
                AS country_code,

            CAST(
                TRIM(CONVERT(NVARCHAR(MAX), acquisition_channel))
                AS NVARCHAR(100)
            ) AS acquisition_channel,

            CONVERT(
                BIT,
                CASE
                    WHEN LOWER(
                        TRIM(CONVERT(VARCHAR(20), is_verified))
                    ) IN ('1', 'true')
                    THEN 1
                    ELSE 0
                END
            ) AS is_verified

        INTO #CustomerSource
        FROM #RawCustomer;

        -- 7. Reject duplicate customer IDs
        IF EXISTS (
            SELECT customer_id
            FROM #CustomerSource
            GROUP BY customer_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51007, 'Duplicate customer IDs.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_CustomerSource
            ON #CustomerSource(customer_id);

        -- 8. Validate country references
        IF EXISTS (
            SELECT 1
            FROM #CustomerSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_market AS m
                WHERE m.country_code = s.country_code
            )
        )
            THROW 51008, 'Unknown customer country.', 1;

        -- 9. Lock destination and capture history count
        SELECT @InitialHistoryRows = COUNT_BIG(*)
        FROM main.dim_customer WITH (TABLOCKX, HOLDLOCK);

        -- 10. Reject business keys missing
        -- from the authoritative full snapshot
        IF EXISTS (
            SELECT 1
            FROM (
                SELECT DISTINCT customer_id
                FROM main.dim_customer
            ) AS h
            WHERE NOT EXISTS (
                SELECT 1
                FROM #CustomerSource AS s
                WHERE s.customer_id = h.customer_id
            )
        )
            THROW 51009, 'Historical customer missing from snapshot.', 1;

        -- 11. Every existing customer must have
        -- a current version
        IF EXISTS (
            SELECT 1
            FROM main.dim_customer AS h
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_customer AS c
                WHERE c.customer_id = h.customer_id
                  AND c.is_current = 1
            )
        )
            THROW 51010, 'Customer has no current version.', 1;

        -- 12. Registration timestamp is immutable
        IF EXISTS (
            SELECT 1
            FROM #CustomerSource AS s
            INNER JOIN main.dim_customer AS d
                ON d.customer_id = s.customer_id
            WHERE d.signed_up_at <> s.signed_up_at
        )
            THROW 51011, 'Customer registration timestamp changed.', 1;

        -- 13. Prevent version-number overflow
        IF EXISTS (
            SELECT 1
            FROM main.dim_customer
            WHERE is_current = 1
              AND version_number = 2147483647
        )
            THROW 51012, 'Customer version limit reached.', 1;

        -- 14. Capture one effective ETL timestamp
        SET @LoadUTC = SYSUTCDATETIME();

        -- 15. Identify new and changed customers
        SELECT
            s.customer_id,

            CASE
                WHEN d.customer_sk IS NULL THEN 1
                ELSE d.version_number + 1
            END AS next_version,

            CAST(
                CASE
                    WHEN d.customer_sk IS NULL THEN 1
                    ELSE 0
                END AS BIT
            ) AS is_new

        INTO #ToVersion
        FROM #CustomerSource AS s
        LEFT JOIN main.dim_customer AS d
            ON d.customer_id = s.customer_id
           AND d.is_current = 1

        WHERE d.customer_sk IS NULL
           OR EXISTS (
                SELECT
                    d.country_code COLLATE Latin1_General_100_BIN2,
                    d.acquisition_channel
                        COLLATE Latin1_General_100_BIN2,
                    d.is_verified

                EXCEPT

                SELECT
                    s.country_code COLLATE Latin1_General_100_BIN2,
                    s.acquisition_channel
                        COLLATE Latin1_General_100_BIN2,
                    s.is_verified
           );

        CREATE UNIQUE CLUSTERED INDEX IX_ToVersion
            ON #ToVersion(customer_id);

        -- 16. Count new and changed customers
        SELECT
            @NewCustomers =
                COUNT_BIG(CASE WHEN is_new = 1 THEN 1 END),

            @ChangedCustomers =
                COUNT_BIG(CASE WHEN is_new = 0 THEN 1 END)
        FROM #ToVersion;

        -- 17. Validate version timestamps
        IF EXISTS (
            SELECT 1
            FROM #ToVersion AS v
            INNER JOIN main.dim_customer AS d
                ON d.customer_id = v.customer_id
               AND d.is_current = 1
            WHERE @LoadUTC <= d.valid_from
        )
            THROW 51013, 'Invalid SCD version timestamp.', 1;

        -- 18. Expire changed current versions
        UPDATE d
        SET
            d.valid_to = @LoadUTC,
            d.is_current = 0
        FROM main.dim_customer AS d
        INNER JOIN #ToVersion AS v
            ON d.customer_id = v.customer_id
        WHERE d.is_current = 1
          AND v.is_new = 0;

        SET @ExpiredVersions = @@ROWCOUNT;

        IF @ExpiredVersions <> @ChangedCustomers
            THROW 51014, 'Version expiration mismatch.', 1;

        -- 19. Insert new customer versions
        INSERT INTO main.dim_customer (
            customer_id,
            signed_up_at,
            country_code,
            acquisition_channel,
            is_verified,
            valid_from,
            valid_to,
            is_current,
            version_number
        )
        SELECT
            s.customer_id,
            s.signed_up_at,
            s.country_code,
            s.acquisition_channel,
            s.is_verified,
            @LoadUTC,
            @OpenEnded,
            1,
            v.next_version
        FROM #CustomerSource AS s
        INNER JOIN #ToVersion AS v
            ON s.customer_id = v.customer_id;

        SET @InsertedVersions = @@ROWCOUNT;

        IF @InsertedVersions <>
           @NewCustomers + @ChangedCustomers
            THROW 51015, 'Version insertion mismatch.', 1;

        -- 20. Validate current customer count
        SELECT @CurrentRows = COUNT_BIG(*)
        FROM main.dim_customer
        WHERE is_current = 1;

        IF @CurrentRows <> @SourceRows
            THROW 51016, 'Current customer count mismatch.', 1;

        -- 21. Full source-to-current reconciliation
        IF EXISTS (
            SELECT
                customer_id,
                signed_up_at,
                country_code COLLATE Latin1_General_100_BIN2,
                acquisition_channel
                    COLLATE Latin1_General_100_BIN2,
                is_verified
            FROM #CustomerSource

            EXCEPT

            SELECT
                customer_id,
                signed_up_at,
                country_code COLLATE Latin1_General_100_BIN2,
                acquisition_channel
                    COLLATE Latin1_General_100_BIN2,
                is_verified
            FROM main.dim_customer
            WHERE is_current = 1
        )
        OR EXISTS (
            SELECT
                customer_id,
                signed_up_at,
                country_code COLLATE Latin1_General_100_BIN2,
                acquisition_channel
                    COLLATE Latin1_General_100_BIN2,
                is_verified
            FROM main.dim_customer
            WHERE is_current = 1

            EXCEPT

            SELECT
                customer_id,
                signed_up_at,
                country_code COLLATE Latin1_General_100_BIN2,
                acquisition_channel
                    COLLATE Latin1_General_100_BIN2,
                is_verified
            FROM #CustomerSource
        )
            THROW 51017, 'Current snapshot reconciliation failed.', 1;

        -- 22. Validate SCD Type 2 history
        IF EXISTS (
            SELECT 1
            FROM (
                SELECT
                    customer_id,
                    version_number,
                    valid_from,
                    valid_to,
                    is_current,

                    ROW_NUMBER() OVER (
                        PARTITION BY customer_id
                        ORDER BY version_number
                    ) AS expected_version,

                    LEAD(valid_from) OVER (
                        PARTITION BY customer_id
                        ORDER BY version_number
                    ) AS next_valid_from

                FROM main.dim_customer
            ) AS h
            WHERE h.version_number <> h.expected_version

               OR h.valid_from >= h.valid_to

               OR (
                    h.next_valid_from IS NOT NULL
                    AND (
                        h.valid_to <> h.next_valid_from
                        OR h.is_current <> 0
                    )
               )

               OR (
                    h.next_valid_from IS NULL
                    AND (
                        h.is_current <> 1
                        OR h.valid_to <> @OpenEnded
                    )
               )
        )
            THROW 51018, 'SCD Type 2 history validation failed.', 1;

        -- 23. Ensure historical rows were preserved
        SELECT @HistoryRows = COUNT_BIG(*)
        FROM main.dim_customer;

        IF @HistoryRows <>
           @InitialHistoryRows + @InsertedVersions
            THROW 51019, 'Historical row reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 24. Execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @CurrentRows AS current_customers,
            @HistoryRows AS total_version_rows,
            @NewCustomers AS new_customers,
            @ChangedCustomers AS changed_customers,
            @ExpiredVersions AS expired_versions,
            @InsertedVersions AS inserted_versions,
            @SourceRows - @NewCustomers - @ChangedCustomers
                AS unchanged_customers,
            @LoadUTC AS effective_at_utc,
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
EXEC dbo.usp_LoadDimCustomer;
