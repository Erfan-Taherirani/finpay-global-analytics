
-- ================================================
-- PROCEDURE: dbo.usp_LoadDimGateway
-- Full Snapshot + SCD Type 2 + Validations
-- ================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadDimGateway
    @ExpectedGatewayCount INT = 5
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @CurrentRows BIGINT = 0,
        @HistoryRows BIGINT = 0,
        @NewGateways INT = 0,
        @ChangedGateways INT = 0,
        @ExpiredRows INT = 0,
        @InsertedVersions INT = 0,
        @LockResult INT,
        @LoadUTC DATETIME2(7),
        @OpenEnded DATETIME2(7) =
            '9999-12-31T23:59:59.9999999';

    BEGIN TRY

        -- 1. Verify source and destination
        IF OBJECT_ID(N'stg.dim_gateway', N'U') IS NULL
            THROW 51001, 'Staging table does not exist.', 1;

        IF OBJECT_ID(N'main.dim_gateway', N'U') IS NULL
            THROW 51002, 'Destination table does not exist.', 1;

        IF @ExpectedGatewayCount IS NULL
           OR @ExpectedGatewayCount <= 0
            THROW 51003, 'Invalid expected gateway count.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent ETL executions
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_gateway',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 10000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 51004, 'Could not acquire ETL lock.', 1;

        -- 3. Capture complete staging snapshot
        SELECT
            gateway_id,
            gateway_name,
            home_region,
            is_enabled
        INTO #RawGateway
        FROM stg.dim_gateway WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawGateway;

        -- 4. Validate snapshot completeness
        IF @SourceRows <> @ExpectedGatewayCount
            THROW 51005, 'Unexpected gateway count.', 1;

        -- 5. Validate required fields and data types
        IF EXISTS (
            SELECT 1
            FROM #RawGateway
            WHERE gateway_id IS NULL
               OR TRY_CONVERT(INT, gateway_id) IS NULL
               OR TRY_CONVERT(INT, gateway_id) <= 0

               OR gateway_name IS NULL
               OR NULLIF(
                    TRIM(CONVERT(NVARCHAR(MAX), gateway_name)), N''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(NVARCHAR(MAX), gateway_name))
                  ) > 300

               OR home_region IS NULL
               OR NULLIF(
                    TRIM(CONVERT(NVARCHAR(MAX), home_region)), N''
                  ) IS NULL
               OR DATALENGTH(
                    TRIM(CONVERT(NVARCHAR(MAX), home_region))
                  ) > 200

               OR is_enabled IS NULL
               OR LOWER(
                    TRIM(CONVERT(VARCHAR(20), is_enabled))
                  ) NOT IN ('0', '1', 'true', 'false')
        )
            THROW 51006, 'Invalid gateway data.', 1;

        -- 6. Normalize and type source data
        SELECT
            CONVERT(INT, gateway_id) AS gateway_id,

            CAST(
                TRIM(CONVERT(NVARCHAR(MAX), gateway_name))
                AS NVARCHAR(150)
            ) AS gateway_name,

            CAST(
                TRIM(CONVERT(NVARCHAR(MAX), home_region))
                AS NVARCHAR(100)
            ) AS home_region,

            CONVERT(
                BIT,
                CASE
                    WHEN LOWER(
                        TRIM(CONVERT(VARCHAR(20), is_enabled))
                    ) IN ('1', 'true')
                    THEN 1 ELSE 0
                END
            ) AS is_enabled

        INTO #GatewaySource
        FROM #RawGateway;

        -- 7. Reject duplicate gateway IDs
        IF EXISTS (
            SELECT gateway_id
            FROM #GatewaySource
            GROUP BY gateway_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51007, 'Duplicate gateway IDs.', 1;

        -- 8. Reject duplicate provider names
        IF EXISTS (
            SELECT gateway_name COLLATE Latin1_General_100_CI_AS
            FROM #GatewaySource
            GROUP BY gateway_name COLLATE Latin1_General_100_CI_AS
            HAVING COUNT_BIG(*) > 1
        )
            THROW 51008, 'Duplicate gateway names.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_GatewaySource
            ON #GatewaySource(gateway_id);

        -- 9. Lock destination during synchronization
        SELECT @HistoryRows = COUNT_BIG(*)
        FROM main.dim_gateway WITH (TABLOCKX, HOLDLOCK);

        -- Reject historical business keys absent from snapshot
        IF EXISTS (
            SELECT 1
            FROM (
                SELECT DISTINCT gateway_id
                FROM main.dim_gateway
            ) AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #GatewaySource AS s
                WHERE s.gateway_id = d.gateway_id
            )
        )
            THROW 51009, 'Existing gateway missing from snapshot.', 1;

        -- 10. Reject historical keys without a current version
        IF EXISTS (
            SELECT 1
            FROM main.dim_gateway AS h
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_gateway AS c
                WHERE c.gateway_id = h.gateway_id
                  AND c.is_current = 1
            )
        )
            THROW 51010, 'Gateway history has no current version.', 1;

        -- 11. Capture a single effective ETL timestamp
        SET @LoadUTC = SYSUTCDATETIME();

        -- 12. Identify NEW or CHANGED gateways
        SELECT
            s.gateway_id,
            CASE
                WHEN d.gateway_sk IS NULL THEN 1
                ELSE d.version_number + 1
            END AS next_version,

            CAST(
                CASE
                    WHEN d.gateway_sk IS NULL THEN 1
                    ELSE 0
                END AS BIT
            ) AS is_new

        INTO #ToVersion
        FROM #GatewaySource AS s
        LEFT JOIN main.dim_gateway AS d
            ON d.gateway_id = s.gateway_id
           AND d.is_current = 1

        WHERE d.gateway_sk IS NULL
           OR EXISTS (
                SELECT
                    d.gateway_name COLLATE Latin1_General_100_BIN2,
                    d.home_region COLLATE Latin1_General_100_BIN2,
                    d.is_enabled

                EXCEPT

                SELECT
                    s.gateway_name COLLATE Latin1_General_100_BIN2,
                    s.home_region COLLATE Latin1_General_100_BIN2,
                    s.is_enabled
           );

        CREATE UNIQUE CLUSTERED INDEX IX_ToVersion
            ON #ToVersion(gateway_id);

        SELECT
            @NewGateways =
                COALESCE(SUM(
                    CASE WHEN is_new = 1 THEN 1 ELSE 0 END
                ), 0),

            @ChangedGateways =
                COALESCE(SUM(
                    CASE WHEN is_new = 0 THEN 1 ELSE 0 END
                ), 0)
        FROM #ToVersion;

        -- 13. Prevent invalid or duplicate version timestamps
        IF EXISTS (
            SELECT 1
            FROM #ToVersion AS v
            JOIN main.dim_gateway AS d
                ON d.gateway_id = v.gateway_id
               AND d.is_current = 1
            WHERE @LoadUTC <= d.valid_from
               OR d.version_number = 2147483647
        )
            THROW 51011, 'Invalid version timestamp or number.', 1;

        -- 14. Expire changed current versions
        UPDATE d
        SET
            d.valid_to = @LoadUTC,
            d.is_current = 0
        FROM main.dim_gateway AS d
        INNER JOIN #ToVersion AS v
            ON d.gateway_id = v.gateway_id
        WHERE d.is_current = 1
          AND v.is_new = 0;

        SET @ExpiredRows = @@ROWCOUNT;

        IF @ExpiredRows <> @ChangedGateways
            THROW 51012, 'Version expiration mismatch.', 1;

        -- 15. Insert new gateway versions
        INSERT INTO main.dim_gateway (
            gateway_id,
            gateway_name,
            home_region,
            is_enabled,
            valid_from,
            valid_to,
            is_current,
            version_number
        )
        SELECT
            s.gateway_id,
            s.gateway_name,
            s.home_region,
            s.is_enabled,
            @LoadUTC,
            @OpenEnded,
            1,
            v.next_version
        FROM #GatewaySource AS s
        INNER JOIN #ToVersion AS v
            ON s.gateway_id = v.gateway_id;

        SET @InsertedVersions = @@ROWCOUNT;

        IF @InsertedVersions <>
           @NewGateways + @ChangedGateways
            THROW 51013, 'Version insertion mismatch.', 1;

        -- 16. Validate number of current gateway records
        SELECT @CurrentRows = COUNT_BIG(*)
        FROM main.dim_gateway
        WHERE is_current = 1;

        IF @CurrentRows <> @SourceRows
            THROW 51014, 'Current gateway count mismatch.', 1;

        -- 17. Full source-to-current reconciliation
        IF EXISTS (
            SELECT
                gateway_id,
                gateway_name COLLATE Latin1_General_100_BIN2,
                home_region COLLATE Latin1_General_100_BIN2,
                is_enabled
            FROM #GatewaySource

            EXCEPT

            SELECT
                gateway_id,
                gateway_name COLLATE Latin1_General_100_BIN2,
                home_region COLLATE Latin1_General_100_BIN2,
                is_enabled
            FROM main.dim_gateway
            WHERE is_current = 1
        )
        OR EXISTS (
            SELECT
                gateway_id,
                gateway_name COLLATE Latin1_General_100_BIN2,
                home_region COLLATE Latin1_General_100_BIN2,
                is_enabled
            FROM main.dim_gateway
            WHERE is_current = 1

            EXCEPT

            SELECT
                gateway_id,
                gateway_name COLLATE Latin1_General_100_BIN2,
                home_region COLLATE Latin1_General_100_BIN2,
                is_enabled
            FROM #GatewaySource
        )
            THROW 51015, 'Current snapshot reconciliation failed.', 1;

        -- 18. Validate historical continuity and version order
        IF EXISTS (
            SELECT 1
            FROM (
                SELECT
                    gateway_id,
                    version_number,
                    is_current,
                    valid_from,
                    valid_to,

                    ROW_NUMBER() OVER (
                        PARTITION BY gateway_id
                        ORDER BY version_number
                    ) AS expected_version,

                    LEAD(valid_from) OVER (
                        PARTITION BY gateway_id
                        ORDER BY version_number
                    ) AS next_valid_from

                FROM main.dim_gateway
            ) AS h
            WHERE h.version_number <> h.expected_version

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
            THROW 51016, 'SCD Type 2 history validation failed.', 1;

        -- 19. Validate history row count
        SELECT @HistoryRows = COUNT_BIG(*)
        FROM main.dim_gateway;

        IF @HistoryRows < @CurrentRows
            THROW 51017, 'Invalid historical row count.', 1;

        COMMIT TRANSACTION;

        -- 20. Execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @CurrentRows AS current_rows,
            @HistoryRows AS total_version_rows,
            @NewGateways AS new_gateways,
            @ChangedGateways AS changed_gateways,
            @ExpiredRows AS expired_versions,
            @InsertedVersions AS inserted_versions,
            @SourceRows - @NewGateways - @ChangedGateways
                AS unchanged_gateways,
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

-- 21. Execute the stored procedure
EXEC dbo.usp_LoadDimGateway;
