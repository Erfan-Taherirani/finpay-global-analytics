-- SCD TYPE 2 ILLUSTRATIVE COMPLETE PATTERN (SQL SERVER).
-- DO NOT RUN WITHOUT CHANGING NAMES/COLUMN CONTRACTS.
-- Example pre-typed full staging snapshot:
-- stg.dim_entity(entity_id BIGINT, label NVARCHAR(100), status VARCHAR(30))
-- Type 2 tracked columns: label and status.
-- ETL-observation UTC time; cannot reconstruct prior source history.

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

IF OBJECT_ID(N'main.dim_entity', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_entity (
        entity_sk BIGINT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_dim_entity PRIMARY KEY,
        entity_id BIGINT NOT NULL,
        label NVARCHAR(100) NOT NULL,
        [status] VARCHAR(30) NOT NULL,
        valid_from DATETIME2(7) NOT NULL,
        valid_to DATETIME2(7) NOT NULL,
        is_current BIT NOT NULL,
        version_number INT NOT NULL,
        CONSTRAINT UQ_dim_entity_ver UNIQUE(entity_id, version_number),
        CONSTRAINT UQ_dim_entity_from UNIQUE(entity_id, valid_from),
        CONSTRAINT CK_dim_entity_valid CHECK (valid_from < valid_to),
        CONSTRAINT CK_dim_entity_ver CHECK (version_number >= 1),
        CONSTRAINT CK_dim_entity_current CHECK (
            (is_current = 1 AND valid_to = '9999-12-31T23:59:59.9999999')
            OR
            (is_current = 0 AND valid_to < '9999-12-31T23:59:59.9999999')
        )
    );
    CREATE UNIQUE NONCLUSTERED INDEX UX_dim_entity_current
        ON main.dim_entity(entity_id) WHERE is_current = 1;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_LoadDimEntity
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @LockResult INT,
            @EffectiveUTC DATETIME2(7),
            @MaxDate DATETIME2(7) = '9999-12-31T23:59:59.9999999',
            @SourceRows BIGINT, @Changed BIGINT, @Inserted BIGINT;
    BEGIN TRY
        IF OBJECT_ID(N'stg.dim_entity', N'U') IS NULL
            THROW 52101, 'Missing staging dim_entity.', 1;
        BEGIN TRANSACTION;
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.dim_entity',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction', @LockTimeout = 30000;
        IF @LockResult IS NULL OR @LockResult < 0
            THROW 52102, 'Failed to acquire ETL lock.', 1;

        SELECT entity_id, label, [status]
        INTO #Source
        FROM stg.dim_entity WITH (TABLOCK, HOLDLOCK);
        SELECT @SourceRows = COUNT_BIG(*) FROM #Source;

        IF EXISTS (
            SELECT 1 FROM #Source
            WHERE entity_id IS NULL OR entity_id <= 0
               OR label IS NULL OR DATALENGTH(TRIM(label)) = 0
               OR [status] IS NULL OR DATALENGTH(TRIM([status])) = 0
        )
            THROW 52103, 'Invalid required fields.', 1;

        IF EXISTS (
            SELECT entity_id FROM #Source
            GROUP BY entity_id HAVING COUNT_BIG(*) > 1
        )
            THROW 52104, 'Duplicate entity ID.', 1;
        CREATE UNIQUE CLUSTERED INDEX IX_Source ON #Source(entity_id);

        -- Exclusive target lock serializes target mutation during this load.
        DECLARE @HistoryBefore BIGINT;
        SELECT @HistoryBefore = COUNT_BIG(*)
        FROM main.dim_entity WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1 FROM main.dim_entity AS d
            WHERE NOT EXISTS (
                SELECT 1 FROM #Source AS s WHERE s.entity_id = d.entity_id
            )
        )
            THROW 52105, 'Existing entity missing from full snapshot.', 1;

        IF EXISTS (
            SELECT 1 FROM main.dim_entity AS d
            WHERE NOT EXISTS (
                SELECT 1 FROM main.dim_entity AS c
                WHERE c.entity_id = d.entity_id AND c.is_current = 1
            )
        )
            THROW 52106, 'Existing entity has no current version.', 1;

        IF EXISTS (
            SELECT 1 FROM main.dim_entity
            WHERE is_current = 1 AND version_number = 2147483647
        )
            THROW 52107, 'Version number overflow risk.', 1;

        SET @EffectiveUTC = SYSUTCDATETIME();
        SELECT s.entity_id,
               CASE WHEN d.entity_sk IS NULL THEN 1
                    ELSE d.version_number + 1 END AS next_version,
               CONVERT(BIT, CASE WHEN d.entity_sk IS NULL THEN 1 ELSE 0 END)
                   AS is_new
        INTO #ToVersion
        FROM #Source AS s
        LEFT JOIN main.dim_entity AS d
            ON d.entity_id = s.entity_id AND d.is_current = 1
        WHERE d.entity_sk IS NULL
           OR EXISTS (
                SELECT d.label COLLATE Latin1_General_100_BIN2,
                       d.[status] COLLATE Latin1_General_100_BIN2
                EXCEPT
                SELECT s.label COLLATE Latin1_General_100_BIN2,
                       s.[status] COLLATE Latin1_General_100_BIN2
           );

        CREATE UNIQUE CLUSTERED INDEX IX_ToVersion
            ON #ToVersion(entity_id);
        IF EXISTS (
            SELECT 1 FROM #ToVersion AS v
            JOIN main.dim_entity AS d
                ON d.entity_id = v.entity_id AND d.is_current = 1
            WHERE @EffectiveUTC <= d.valid_from
        )
            THROW 52108, 'Nonmonotonic SCD2 timestamp.', 1;

        UPDATE d SET valid_to = @EffectiveUTC, is_current = 0
        FROM main.dim_entity AS d
        JOIN #ToVersion AS v ON v.entity_id = d.entity_id
        WHERE d.is_current = 1 AND v.is_new = 0;
        SET @Changed = @@ROWCOUNT;

        INSERT INTO main.dim_entity (
            entity_id, label, [status], valid_from, valid_to,
            is_current, version_number
        )
        SELECT s.entity_id, s.label, s.[status], @EffectiveUTC,
               @MaxDate, 1, v.next_version
        FROM #Source AS s
        JOIN #ToVersion AS v ON v.entity_id = s.entity_id;
        SET @Inserted = @@ROWCOUNT;

        IF (SELECT COUNT_BIG(*) FROM main.dim_entity WHERE is_current = 1)
            <> @SourceRows
            THROW 52109, 'Current dimension count mismatch.', 1;
        IF (SELECT COUNT_BIG(*) FROM main.dim_entity)
            <> @HistoryBefore + @Inserted
            THROW 52110, 'Historical row count mismatch.', 1;

        IF EXISTS (
            SELECT 1 FROM (
                SELECT entity_id, version_number, valid_from, valid_to,
                    is_current,
                    ROW_NUMBER() OVER (
                        PARTITION BY entity_id ORDER BY version_number
                    ) AS rn,
                    LEAD(valid_from) OVER (
                        PARTITION BY entity_id ORDER BY version_number
                    ) AS next_from
                FROM main.dim_entity
            ) AS h
            WHERE version_number <> rn
               OR (next_from IS NOT NULL AND
                   (valid_to <> next_from OR is_current <> 0))
               OR (next_from IS NULL AND
                   (valid_to <> @MaxDate OR is_current <> 1))
        )
            THROW 52111, 'SCD2 continuity mismatch.', 1;

        COMMIT TRANSACTION;
        SELECT 'SUCCESS' AS load_status,
               @SourceRows AS source_rows,
               @Changed AS closed_versions,
               @Inserted AS inserted_versions,
               SYSUTCDATETIME() AS completed_at_utc;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO
EXEC dbo.usp_LoadDimEntity;
