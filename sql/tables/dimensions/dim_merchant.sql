
-- ===================================================
-- PROCEDURE: dbo.usp_LoadDimMerchant
-- Full Snapshot + SCD Type 2 + Validations
-- ===================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadDimMerchant
    @ExpectedMerchantCount INT = 2000,
    @SnapshotCutoff DATETIME2(3) = '2026-10-01T00:00:00'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @CurrentRows BIGINT = 0,
        @HistoryRows BIGINT = 0,
        @InitialHistoryRows BIGINT = 0,
        @NewMerchants BIGINT = 0,
        @ChangedMerchants BIGINT = 0,
        @ClosedVersions BIGINT = 0,
        @InsertedVersions BIGINT = 0,
        @LockResult INT,
        @LoadUTC DATETIME2(7),
        @OpenEnded DATETIME2(7) =
            '9999-12-31T23:59:59.9999999';

    BEGIN TRY

        -- 1. Verify source and destination
        IF OBJECT_ID(N'stg.dim_merchant', N'U') IS NULL
            THROW 51001, 'Staging table does not exist.', 1;

        IF OBJECT_ID(N'main.dim_merchant', N'U') IS NULL
            THROW 51002, 'Destination table does not exist.', 1;

        IF @ExpectedMerchantCount IS NULL
           OR @ExpectedMerchantCount <= 0
           OR @SnapshotCutoff IS NULL
            THROW 51003, 'Invalid ETL parameters.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent ETL executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_merchant',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 51004, 'Could not acquire ETL lock.', 1;

        -- 3. Capture the complete staging snapshot
        SELECT
            merchant_id,
            merchant_name,
            country_code,
            industry,
            onboarded_at,
            settlement_currency,
            pricing_tier,
            payout_frequency,
            account_status
        INTO #RawMerchant
        FROM stg.dim_merchant WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawMerchant;

        -- 4. Validate snapshot completeness
        IF @SourceRows <> @ExpectedMerchantCount
            THROW 51005, 'Unexpected merchant count.', 1;

        -- 5. Validate required fields and data types
        IF EXISTS (
            SELECT 1
            FROM #RawMerchant
            WHERE merchant_id IS NULL
               OR TRY_CONVERT(BIGINT, merchant_id) IS NULL
               OR TRY_CONVERT(BIGINT, merchant_id) <= 0
               OR (
                    TRY_CONVERT(DECIMAL(38,10), merchant_id)
                    IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), merchant_id) <>
                        TRY_CONVERT(
                            DECIMAL(38,10),
                            TRY_CONVERT(BIGINT, merchant_id)
                        )
               )

               OR NULLIF(
                    TRIM(CONVERT(NVARCHAR(MAX), merchant_name)), N''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(NVARCHAR(MAX), merchant_name))
                  ) > 400

               OR country_code IS NULL
               OR DATALENGTH(CONVERT(VARCHAR(MAX), country_code)) <> 2
               OR CONVERT(VARCHAR(MAX), country_code)
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z]'

               OR NULLIF(
                    TRIM(CONVERT(NVARCHAR(MAX), industry)), N''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(NVARCHAR(MAX), industry))
                  ) > 200

               OR TRY_CONVERT(DATETIME2(3), onboarded_at) IS NULL
               OR TRY_CONVERT(DATETIME2(3), onboarded_at)
                    >= @SnapshotCutoff

               OR settlement_currency IS NULL
               OR DATALENGTH(
                    CONVERT(VARCHAR(MAX), settlement_currency)
                  ) <> 3
               OR CONVERT(VARCHAR(MAX), settlement_currency)
                    COLLATE Latin1_General_100_BIN2
                    NOT LIKE '[A-Z][A-Z][A-Z]'

               OR NULLIF(
                    TRIM(CONVERT(VARCHAR(MAX), pricing_tier)), ''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(VARCHAR(MAX), pricing_tier))
                  ) > 30

               OR NULLIF(
                    TRIM(CONVERT(VARCHAR(MAX), payout_frequency)), ''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(VARCHAR(MAX), payout_frequency))
                  ) > 30

               OR NULLIF(
                    TRIM(CONVERT(VARCHAR(MAX), account_status)), ''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(VARCHAR(MAX), account_status))
                  ) > 30
        )
            THROW 51006, 'Invalid merchant data.', 1;

        -- 6. Normalize and type source records
        SELECT
            CONVERT(BIGINT, merchant_id) AS merchant_id,

            CAST(
                TRIM(CONVERT(NVARCHAR(MAX), merchant_name))
                AS NVARCHAR(200)
            ) AS merchant_name,

            CAST(country_code AS VARCHAR(2)) AS country_code,

            CAST(
                TRIM(CONVERT(NVARCHAR(MAX), industry))
                AS NVARCHAR(100)
            ) AS industry,

            CONVERT(DATETIME2(3), onboarded_at) AS onboarded_at,

            CAST(
                settlement_currency AS VARCHAR(3)
            ) AS settlement_currency,

            CAST(
                TRIM(CONVERT(VARCHAR(MAX), pricing_tier))
                AS VARCHAR(30)
            ) AS pricing_tier,

            CAST(
                TRIM(CONVERT(VARCHAR(MAX), payout_frequency))
                AS VARCHAR(30)
            ) AS payout_frequency,

            CAST(
                TRIM(CONVERT(VARCHAR(MAX), account_status))
                AS VARCHAR(30)
            ) AS account_status

        INTO #MerchantSource
        FROM #RawMerchant;

        -- 7. Reject duplicate business keys
        IF EXISTS (
            SELECT merchant_id
            FROM #MerchantSource
            GROUP BY merchant_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51007, 'Duplicate merchant IDs.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_MerchantSource
            ON #MerchantSource(merchant_id);

        -- 8. Validate market references
        IF EXISTS (
            SELECT 1
            FROM #MerchantSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_market AS m
                WHERE m.country_code = s.country_code
            )
        )
            THROW 51008, 'Unknown merchant market.', 1;

        -- 9. Validate settlement currency references
        IF EXISTS (
            SELECT 1
            FROM #MerchantSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_currency AS c
                WHERE c.currency_code = s.settlement_currency
            )
        )
            THROW 51009, 'Unknown settlement currency.', 1;

        -- 10. Lock destination and capture history count
        SELECT @InitialHistoryRows = COUNT_BIG(*)
        FROM main.dim_merchant WITH (TABLOCKX, HOLDLOCK);

        -- 11. Reject existing merchant keys missing
        -- from the complete staging snapshot
        IF EXISTS (
            SELECT 1
            FROM (
                SELECT DISTINCT merchant_id
                FROM main.dim_merchant
            ) AS h
            WHERE NOT EXISTS (
                SELECT 1
                FROM #MerchantSource AS s
                WHERE s.merchant_id = h.merchant_id
            )
        )
            THROW 51010, 'Historical merchant missing from snapshot.', 1;

        -- 12. Every existing merchant must have
        -- exactly one current version
        IF EXISTS (
            SELECT 1
            FROM main.dim_merchant AS h
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_merchant AS c
                WHERE c.merchant_id = h.merchant_id
                  AND c.is_current = 1
            )
        )
            THROW 51011, 'Merchant has no current version.', 1;

        -- Prevent version-number overflow
        IF EXISTS (
            SELECT 1
            FROM main.dim_merchant
            WHERE is_current = 1
              AND version_number = 2147483647
        )
            THROW 51012, 'Merchant version limit reached.', 1;

        -- 13. Capture one ETL effective timestamp
        SET @LoadUTC = SYSUTCDATETIME();

        -- 14. Identify new and changed merchants
        SELECT
            s.merchant_id,

            CASE
                WHEN d.merchant_sk IS NULL THEN 1
                ELSE d.version_number + 1
            END AS next_version,

            CAST(
                CASE
                    WHEN d.merchant_sk IS NULL THEN 1
                    ELSE 0
                END AS BIT
            ) AS is_new

        INTO #ToVersion
        FROM #MerchantSource AS s
        LEFT JOIN main.dim_merchant AS d
            ON d.merchant_id = s.merchant_id
           AND d.is_current = 1

        WHERE d.merchant_sk IS NULL
           OR EXISTS (
                SELECT
                    d.merchant_name COLLATE Latin1_General_100_BIN2,
                    d.country_code COLLATE Latin1_General_100_BIN2,
                    d.industry COLLATE Latin1_General_100_BIN2,
                    d.onboarded_at,
                    d.settlement_currency COLLATE Latin1_General_100_BIN2,
                    d.pricing_tier COLLATE Latin1_General_100_BIN2,
                    d.payout_frequency COLLATE Latin1_General_100_BIN2,
                    d.account_status COLLATE Latin1_General_100_BIN2

                EXCEPT

                SELECT
                    s.merchant_name COLLATE Latin1_General_100_BIN2,
                    s.country_code COLLATE Latin1_General_100_BIN2,
                    s.industry COLLATE Latin1_General_100_BIN2,
                    s.onboarded_at,
                    s.settlement_currency COLLATE Latin1_General_100_BIN2,
                    s.pricing_tier COLLATE Latin1_General_100_BIN2,
                    s.payout_frequency COLLATE Latin1_General_100_BIN2,
                    s.account_status COLLATE Latin1_General_100_BIN2
           );

        CREATE UNIQUE CLUSTERED INDEX IX_ToVersion
            ON #ToVersion(merchant_id);

        -- 15. Count new and changed merchants
        SELECT
            @NewMerchants = COUNT_BIG(
                CASE WHEN is_new = 1 THEN 1 END
            ),
            @ChangedMerchants = COUNT_BIG(
                CASE WHEN is_new = 0 THEN 1 END
            )
        FROM #ToVersion;

        -- 16. Validate effective timestamps
        IF EXISTS (
            SELECT 1
            FROM #ToVersion AS v
            JOIN main.dim_merchant AS d
                ON d.merchant_id = v.merchant_id
               AND d.is_current = 1
            WHERE @LoadUTC <= d.valid_from
        )
            THROW 51013, 'Invalid SCD version timestamp.', 1;

        -- 17. Expire changed current versions
        UPDATE d
        SET
            d.valid_to = @LoadUTC,
            d.is_current = 0
        FROM main.dim_merchant AS d
        INNER JOIN #ToVersion AS v
            ON d.merchant_id = v.merchant_id
        WHERE d.is_current = 1
          AND v.is_new = 0;

        SET @ClosedVersions = @@ROWCOUNT;

        IF @ClosedVersions <> @ChangedMerchants
            THROW 51014, 'Version expiration mismatch.', 1;

        -- 18. Insert new historical versions
        INSERT INTO main.dim_merchant (
            merchant_id,
            merchant_name,
            country_code,
            industry,
            onboarded_at,
            settlement_currency,
            pricing_tier,
            payout_frequency,
            account_status,
            valid_from,
            valid_to,
            is_current,
            version_number
        )
        SELECT
            s.merchant_id,
            s.merchant_name,
            s.country_code,
            s.industry,
            s.onboarded_at,
            s.settlement_currency,
            s.pricing_tier,
            s.payout_frequency,
            s.account_status,
            @LoadUTC,
            @OpenEnded,
            1,
            v.next_version
        FROM #MerchantSource AS s
        INNER JOIN #ToVersion AS v
            ON s.merchant_id = v.merchant_id;

        SET @InsertedVersions = @@ROWCOUNT;

        IF @InsertedVersions <>
            @NewMerchants + @ChangedMerchants
            THROW 51015, 'Version insertion mismatch.', 1;

        -- 19. Validate current merchant count
        SELECT @CurrentRows = COUNT_BIG(*)
        FROM main.dim_merchant
        WHERE is_current = 1;

        IF @CurrentRows <> @SourceRows
            THROW 51016, 'Current merchant count mismatch.', 1;

        -- 20. Full source-to-current reconciliation
        IF EXISTS (
            SELECT
                merchant_id,
                merchant_name COLLATE Latin1_General_100_BIN2,
                country_code COLLATE Latin1_General_100_BIN2,
                industry COLLATE Latin1_General_100_BIN2,
                onboarded_at,
                settlement_currency COLLATE Latin1_General_100_BIN2,
                pricing_tier COLLATE Latin1_General_100_BIN2,
                payout_frequency COLLATE Latin1_General_100_BIN2,
                account_status COLLATE Latin1_General_100_BIN2
            FROM #MerchantSource

            EXCEPT

            SELECT
                merchant_id,
                merchant_name COLLATE Latin1_General_100_BIN2,
                country_code COLLATE Latin1_General_100_BIN2,
                industry COLLATE Latin1_General_100_BIN2,
                onboarded_at,
                settlement_currency COLLATE Latin1_General_100_BIN2,
                pricing_tier COLLATE Latin1_General_100_BIN2,
                payout_frequency COLLATE Latin1_General_100_BIN2,
                account_status COLLATE Latin1_General_100_BIN2
            FROM main.dim_merchant
            WHERE is_current = 1
        )
        OR EXISTS (
            SELECT
                merchant_id,
                merchant_name COLLATE Latin1_General_100_BIN2,
                country_code COLLATE Latin1_General_100_BIN2,
                industry COLLATE Latin1_General_100_BIN2,
                onboarded_at,
                settlement_currency COLLATE Latin1_General_100_BIN2,
                pricing_tier COLLATE Latin1_General_100_BIN2,
                payout_frequency COLLATE Latin1_General_100_BIN2,
                account_status COLLATE Latin1_General_100_BIN2
            FROM main.dim_merchant
            WHERE is_current = 1

            EXCEPT

            SELECT
                merchant_id,
                merchant_name COLLATE Latin1_General_100_BIN2,
                country_code COLLATE Latin1_General_100_BIN2,
                industry COLLATE Latin1_General_100_BIN2,
                onboarded_at,
                settlement_currency COLLATE Latin1_General_100_BIN2,
                pricing_tier COLLATE Latin1_General_100_BIN2,
                payout_frequency COLLATE Latin1_General_100_BIN2,
                account_status COLLATE Latin1_General_100_BIN2
            FROM #MerchantSource
        )
            THROW 51017, 'Current snapshot reconciliation failed.', 1;

        -- 21. Validate history continuity and versions
        IF EXISTS (
            SELECT 1
            FROM (
                SELECT
                    merchant_id,
                    version_number,
                    valid_from,
                    valid_to,
                    is_current,

                    ROW_NUMBER() OVER (
                        PARTITION BY merchant_id
                        ORDER BY version_number
                    ) AS expected_version,

                    LEAD(valid_from) OVER (
                        PARTITION BY merchant_id
                        ORDER BY version_number
                    ) AS next_valid_from

                FROM main.dim_merchant
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

        -- 22. Ensure historical versions were preserved
        SELECT @HistoryRows = COUNT_BIG(*)
        FROM main.dim_merchant;

        IF @HistoryRows <>
            @InitialHistoryRows + @InsertedVersions
            THROW 51019, 'Historical row reconciliation failed.', 1;

        COMMIT TRANSACTION;

        -- 23. Execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @CurrentRows AS current_merchants,
            @HistoryRows AS total_version_rows,
            @NewMerchants AS new_merchants,
            @ChangedMerchants AS changed_merchants,
            @ClosedVersions AS expired_versions,
            @InsertedVersions AS inserted_versions,
            @SourceRows - @NewMerchants - @ChangedMerchants
                AS unchanged_merchants,
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

-- 24. Execute the procedure
EXEC dbo.usp_LoadDimMerchant;
