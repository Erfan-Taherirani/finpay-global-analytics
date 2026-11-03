
-- ======================================================
-- PROCEDURE: dbo.usp_LoadFactPaymentAttempt
-- Full Snapshot + Upsert + Integrated Validations
-- ======================================================

CREATE OR ALTER PROCEDURE dbo.usp_LoadFactPaymentAttempt
    @ExpectedAttemptCount BIGINT = NULL,
    @StartDate DATETIME2(6) = '2021-10-01T00:00:00',
    @SnapshotCutoff DATETIME2(6) = '2026-10-01T00:00:00'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @SourceRows BIGINT = 0,
        @TargetRows BIGINT = 0,
        @InitialRows BIGINT = 0,
        @UpdatedRows BIGINT = 0,
        @InsertedRows BIGINT = 0,
        @PendingRows BIGINT = 0,
        @SucceededRows BIGINT = 0,
        @FailedRows BIGINT = 0,
        @LockResult INT,
        @LoadUTC DATETIME2(7);

    BEGIN TRY

        -- 1. Verify required tables
        IF OBJECT_ID(N'stg.fact_payment_attempt', N'U') IS NULL
            THROW 53001, 'Staging attempt table is missing.', 1;

        IF OBJECT_ID(N'main.fact_payment_attempt', N'U') IS NULL
            THROW 53002, 'Destination attempt table is missing.', 1;

        IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
            THROW 53003, 'Parent payment-intent table is missing.', 1;

        IF @StartDate IS NULL
           OR @SnapshotCutoff IS NULL
           OR @StartDate >= @SnapshotCutoff
           OR (@ExpectedAttemptCount IS NOT NULL
               AND @ExpectedAttemptCount <= 0)
            THROW 53004, 'Invalid ETL parameters.', 1;

        BEGIN TRANSACTION;

        -- 2. Prevent concurrent loads of this fact
        EXEC @LockResult = sys.sp_getapplock
            @Resource = N'ETL:main.fact_payment_attempt',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 30000;

        IF @LockResult IS NULL OR @LockResult < 0
            THROW 53005, 'Could not acquire ETL lock.', 1;

        SET @LoadUTC = SYSUTCDATETIME();

        -- 3. Capture complete staging snapshot
        SELECT
            attempt_id,
            intent_id,
            gateway_id,
            attempt_number,
            started_at,
            finished_at,
            payment_method,
            outcome,
            failure_reason,
            latency_ms
        INTO #RawAttempt
        FROM stg.fact_payment_attempt WITH (TABLOCK, HOLDLOCK);

        SELECT @SourceRows = COUNT_BIG(*)
        FROM #RawAttempt;

        -- 4. Validate snapshot size
        IF @SourceRows = 0
            THROW 53006, 'Payment attempt snapshot is empty.', 1;

        IF @ExpectedAttemptCount IS NOT NULL
           AND @SourceRows <> @ExpectedAttemptCount
            THROW 53007, 'Unexpected payment attempt count.', 1;

        -- 5. Validate text lengths before conversion
        IF EXISTS (
            SELECT 1
            FROM #RawAttempt AS r
            WHERE
                DATALENGTH(TRIM(CONVERT(
                    VARCHAR(MAX), r.payment_method
                ))) > 20

                OR DATALENGTH(TRIM(CONVERT(
                    VARCHAR(MAX), r.outcome
                ))) > 20

                OR DATALENGTH(TRIM(CONVERT(
                    NVARCHAR(MAX), r.failure_reason
                ))) > 400
        )
            THROW 53008, 'Source text exceeds allowed length.', 1;

        -- 6. Normalize and type source data
        SELECT
            TRY_CONVERT(BIGINT, r.attempt_id)
                AS attempt_id,

            TRY_CONVERT(BIGINT, r.intent_id)
                AS intent_id,

            TRY_CONVERT(INT, r.gateway_id)
                AS gateway_id,

            TRY_CONVERT(TINYINT, r.attempt_number)
                AS attempt_number,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), r.started_at
                )), N'')
            ) AS started_at,

            TRY_CONVERT(
                DATETIME2(6),
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(100), r.finished_at
                )), N'')
            ) AS finished_at,

            TRY_CONVERT(
                INT,
                r.latency_ms
            ) AS latency_ms,

            CAST(
                LOWER(TRIM(CONVERT(
                    VARCHAR(MAX), r.payment_method
                ))) AS VARCHAR(20)
            ) AS payment_method,

            CAST(
                LOWER(TRIM(CONVERT(
                    VARCHAR(MAX), r.outcome
                ))) AS VARCHAR(20)
            ) AS outcome,

            CAST(
                NULLIF(TRIM(CONVERT(
                    NVARCHAR(MAX), r.failure_reason
                )), N'') AS NVARCHAR(200)
            ) AS failure_reason

        INTO #AttemptSource
        FROM #RawAttempt AS r;

        -- 7. Validate required fields and identifiers
        IF EXISTS (
            SELECT 1
            FROM #AttemptSource AS s
            WHERE s.attempt_id IS NULL
               OR s.attempt_id <= 0
               OR s.intent_id IS NULL
               OR s.intent_id <= 0
               OR s.gateway_id IS NULL
               OR s.gateway_id <= 0

               OR s.attempt_number IS NULL
               OR s.attempt_number NOT BETWEEN 1 AND 3

               OR s.started_at IS NULL
               OR s.started_at < @StartDate
               OR s.started_at >= @SnapshotCutoff

               OR s.payment_method IS NULL
               OR s.payment_method NOT IN (
                    'card', 'wallet', 'bank_debit'
               )

               OR s.outcome IS NULL
               OR s.outcome NOT IN (
                    'succeeded', 'failed', 'pending'
               )
        )
            THROW 53009, 'Invalid required attempt data.', 1;

        -- 8. Validate all original identifiers precisely
        -- Avoid accepting decimal values truncated to integers
        IF EXISTS (
            SELECT 1
            FROM #RawAttempt AS r
            WHERE
                TRY_CONVERT(BIGINT, r.attempt_id) IS NULL
                OR TRY_CONVERT(BIGINT, r.intent_id) IS NULL
                OR TRY_CONVERT(INT, r.gateway_id) IS NULL
                OR TRY_CONVERT(TINYINT, r.attempt_number) IS NULL

                OR (
                    TRY_CONVERT(DECIMAL(38,10), r.attempt_id)
                        IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), r.attempt_id)
                        <> TRY_CONVERT(DECIMAL(38,10),
                            TRY_CONVERT(BIGINT, r.attempt_id))
                )

                OR (
                    TRY_CONVERT(DECIMAL(38,10), r.intent_id)
                        IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), r.intent_id)
                        <> TRY_CONVERT(DECIMAL(38,10),
                            TRY_CONVERT(BIGINT, r.intent_id))
                )

                OR (
                    TRY_CONVERT(DECIMAL(38,10), r.gateway_id)
                        IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), r.gateway_id)
                        <> TRY_CONVERT(DECIMAL(38,10),
                            TRY_CONVERT(INT, r.gateway_id))
                )

                OR (
                    TRY_CONVERT(DECIMAL(38,10), r.attempt_number)
                        IS NOT NULL
                    AND TRY_CONVERT(DECIMAL(38,10), r.attempt_number)
                        <> TRY_CONVERT(DECIMAL(38,10),
                            TRY_CONVERT(TINYINT, r.attempt_number))
                )
        )
            THROW 53010, 'Invalid or fractional business key.', 1;

        -- 10. Reject duplicate attempt IDs
        IF EXISTS (
            SELECT attempt_id
            FROM #AttemptSource
            GROUP BY attempt_id
            HAVING COUNT_BIG(*) > 1
        )
            THROW 53012, 'Duplicate attempt IDs.', 1;

        -- 11. Reject repeated attempt numbers per intent
        IF EXISTS (
            SELECT intent_id, attempt_number
            FROM #AttemptSource
            GROUP BY intent_id, attempt_number
            HAVING COUNT_BIG(*) > 1
        )
            THROW 53013, 'Duplicate attempt sequence number.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_AttemptSource
            ON #AttemptSource(intent_id, attempt_number);

        CREATE UNIQUE NONCLUSTERED INDEX IX_AttemptSourceId
            ON #AttemptSource(attempt_id);

        -- 12. Validate exact retry numbering and ordering
        ;WITH AttemptSequence AS (
            SELECT
                intent_id,
                attempt_number,
                started_at,
                outcome,

                ROW_NUMBER() OVER (
                    PARTITION BY intent_id
                    ORDER BY attempt_number
                ) AS expected_number,

                LAG(outcome) OVER (
                    PARTITION BY intent_id
                    ORDER BY attempt_number
                ) AS previous_outcome,

                LAG(finished_at) OVER (
                    PARTITION BY intent_id
                    ORDER BY attempt_number
                ) AS previous_finished_at

            FROM #AttemptSource
        )
        SELECT
            intent_id,
            attempt_number,
            started_at,
            outcome,
            expected_number,
            previous_outcome,
            previous_finished_at
        INTO #AttemptSequence
        FROM AttemptSequence;

        IF EXISTS (
            SELECT 1
            FROM #AttemptSequence
            WHERE attempt_number <> expected_number

               OR (
                    attempt_number > 1
                    AND (
                        previous_outcome IS NULL
                        OR previous_outcome <> 'failed'
                        OR previous_finished_at IS NULL
                        OR started_at < previous_finished_at
                    )
               )
        )
            THROW 53014, 'Invalid payment retry sequence.', 1;

        -- 13. Ensure every attempt has a parent intent
        IF EXISTS (
            SELECT 1
            FROM #AttemptSource AS s
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.fact_payment_intent AS p WITH (HOLDLOCK)
                WHERE p.intent_id = s.intent_id
            )
        )
            THROW 53015, 'Attempt references unknown intent.', 1;

        -- 15. Reconcile all attempts with parent outcomes
        SELECT
            p.intent_id,
            p.final_outcome,
            p.captured_at,

            COUNT_BIG(a.attempt_id) AS attempt_count,

            COUNT_BIG(
                CASE WHEN a.outcome = 'succeeded'
                     THEN 1 END
            ) AS succeeded_count,

            COUNT_BIG(
                CASE WHEN a.outcome = 'failed'
                     THEN 1 END
            ) AS failed_count,

            COUNT_BIG(
                CASE WHEN a.outcome = 'pending'
                     THEN 1 END
            ) AS pending_count,

            MAX(a.attempt_number) AS last_number,

            MAX(
                CASE WHEN a.outcome = 'succeeded'
                     THEN a.attempt_number END
            ) AS succeeded_number,

            MAX(
                CASE WHEN a.outcome = 'pending'
                     THEN a.attempt_number END
            ) AS pending_number,

            MAX(
                CASE WHEN a.outcome = 'succeeded'
                     THEN a.finished_at END
            ) AS succeeded_finished_at

        INTO #IntentAudit
        FROM main.fact_payment_intent AS p WITH (HOLDLOCK)
        LEFT JOIN #AttemptSource AS a
            ON a.intent_id = p.intent_id
        GROUP BY
            p.intent_id,
            p.final_outcome,
            p.captured_at;

        IF EXISTS (
            SELECT 1
            FROM #IntentAudit
            WHERE attempt_count > 3

               OR (
                    final_outcome = 'abandoned'
                    AND attempt_count <> 0
               )

               OR (
                    final_outcome = 'succeeded'
                    AND (
                        succeeded_count <> 1
                        OR pending_count <> 0
                        OR succeeded_number <> last_number
                        OR captured_at IS NULL
                        OR captured_at < succeeded_finished_at
                    )
               )

               OR (
                    final_outcome = 'failed'
                    AND (
                        attempt_count = 0
                        OR succeeded_count <> 0
                        OR pending_count <> 0
                        OR failed_count <> attempt_count
                    )
               )

               OR (
                    final_outcome = 'pending'
                    AND (
                        attempt_count = 0
                        OR succeeded_count <> 0
                        OR pending_count <> 1
                        OR pending_number <> last_number
                    )
               )
        )
            THROW 53017, 'Parent intent/attempt reconciliation failed.', 1;

        -- 16. Resolve SCD Type 2 gateway version
        -- Version 1 is the baseline for transactions
        -- before the first warehouse observation.
        SELECT
            s.attempt_id,
            s.intent_id,
            s.gateway_id,
            s.attempt_number,
            g.gateway_sk,

            YEAR(s.started_at) * 10000
                + MONTH(s.started_at) * 100
                + DAY(s.started_at) AS started_date_key,

            s.started_at,
            s.finished_at,
            s.payment_method,
            s.outcome,
            s.failure_reason,
            latency_ms

        INTO #ResolvedAttempt
        FROM #AttemptSource AS s
        LEFT JOIN main.dim_gateway AS g WITH (HOLDLOCK)
            ON g.gateway_id = s.gateway_id
           AND s.started_at < g.valid_to
           AND (
                s.started_at >= g.valid_from
                OR g.version_number = 1
           );

        -- 17. Validate gateway history resolution
        IF (
            SELECT COUNT_BIG(*)
            FROM #ResolvedAttempt
        ) <> @SourceRows
            THROW 53018, 'Ambiguous SCD gateway mapping.', 1;

        IF EXISTS (
            SELECT 1
            FROM #ResolvedAttempt
            WHERE gateway_sk IS NULL
        )
            THROW 53019, 'Unknown gateway or historical version.', 1;

        -- 18. Validate date dimension coverage
        IF EXISTS (
            SELECT 1
            FROM #ResolvedAttempt AS r
            WHERE NOT EXISTS (
                SELECT 1
                FROM main.dim_date AS d
                WHERE d.date_key = r.started_date_key
            )
        )
            THROW 53020, 'Missing attempt date dimension.', 1;

        CREATE UNIQUE CLUSTERED INDEX IX_ResolvedAttempt
            ON #ResolvedAttempt(attempt_id);

        -- 19. Lock destination and reject missing source IDs
        SELECT @InitialRows = COUNT_BIG(*)
        FROM main.fact_payment_attempt WITH (TABLOCKX, HOLDLOCK);

        IF EXISTS (
            SELECT 1
            FROM main.fact_payment_attempt AS d
            WHERE NOT EXISTS (
                SELECT 1
                FROM #ResolvedAttempt AS s
                WHERE s.attempt_id = d.attempt_id
            )
        )
            THROW 53021, 'Existing attempt missing from snapshot.', 1;

        -- 20. Protect immutable attempt identity
        IF EXISTS (
            SELECT 1
            FROM main.fact_payment_attempt AS d
            JOIN #ResolvedAttempt AS s
                ON s.attempt_id = d.attempt_id
            WHERE d.intent_id <> s.intent_id
               OR d.gateway_id <> s.gateway_id
               OR d.attempt_number <> s.attempt_number
               OR d.started_at <> s.started_at
               OR d.payment_method <> s.payment_method
        )
            THROW 53022, 'Immutable attempt attributes changed.', 1;

        -- 21. Prevent reversing completed outcomes
        IF EXISTS (
            SELECT 1
            FROM main.fact_payment_attempt AS d
            JOIN #ResolvedAttempt AS s
                ON s.attempt_id = d.attempt_id
            WHERE d.outcome <> s.outcome
              AND d.outcome <> 'pending'
        )
            THROW 53023, 'Finalized attempt outcome changed.', 1;

        -- 22. Update changed records only
        UPDATE d
        SET
            d.gateway_sk = s.gateway_sk,
            d.started_date_key = s.started_date_key,
            d.finished_at = s.finished_at,
            d.outcome = s.outcome,
            d.failure_reason = s.failure_reason
        FROM main.fact_payment_attempt AS d
        JOIN #ResolvedAttempt AS s
            ON s.attempt_id = d.attempt_id
        WHERE EXISTS (
            SELECT
                d.gateway_sk,
                d.started_date_key,
                d.finished_at,
                d.outcome COLLATE Latin1_General_100_BIN2,
                d.failure_reason COLLATE Latin1_General_100_BIN2

            EXCEPT

            SELECT
                s.gateway_sk,
                s.started_date_key,
                s.finished_at,
                s.outcome COLLATE Latin1_General_100_BIN2,
                s.failure_reason COLLATE Latin1_General_100_BIN2
        );

        SET @UpdatedRows = @@ROWCOUNT;

        -- 23. Insert missing attempts
        INSERT INTO main.fact_payment_attempt (
            attempt_id,
            intent_id,
            gateway_id,
            attempt_number,
            gateway_sk,
            started_date_key,
            started_at,
            finished_at,
            payment_method,
            outcome,
            failure_reason,
            latency_ms
        )
        SELECT
            s.attempt_id,
            s.intent_id,
            s.gateway_id,
            s.attempt_number,
            s.gateway_sk,
            s.started_date_key,
            s.started_at,
            s.finished_at,
            s.payment_method,
            s.outcome,
            s.failure_reason,
            latency_ms
        FROM #ResolvedAttempt AS s
        WHERE NOT EXISTS (
            SELECT 1
            FROM main.fact_payment_attempt AS d
                WITH (UPDLOCK, HOLDLOCK)
            WHERE d.attempt_id = s.attempt_id
        );

        SET @InsertedRows = @@ROWCOUNT;

        -- 24. Reconcile destination counts
        SELECT @TargetRows = COUNT_BIG(*)
        FROM main.fact_payment_attempt;

        IF @TargetRows <> @SourceRows
           OR @TargetRows <> @InitialRows + @InsertedRows
            THROW 53024, 'Attempt row count mismatch.', 1;

        -- 25. Full bidirectional source/target reconciliation
        IF EXISTS (
            SELECT
                attempt_id, intent_id, gateway_id,
                attempt_number, gateway_sk, started_date_key,
                started_at, finished_at,
                payment_method COLLATE Latin1_General_100_BIN2,
                outcome COLLATE Latin1_General_100_BIN2,
                failure_reason COLLATE Latin1_General_100_BIN2,
                latency_ms
            FROM #ResolvedAttempt

            EXCEPT

            SELECT
                attempt_id, intent_id, gateway_id,
                attempt_number, gateway_sk, started_date_key,
                started_at, finished_at,
                payment_method COLLATE Latin1_General_100_BIN2,
                outcome COLLATE Latin1_General_100_BIN2,
                failure_reason COLLATE Latin1_General_100_BIN2,
                latency_ms
            FROM main.fact_payment_attempt
        )
        OR EXISTS (
            SELECT
                attempt_id, intent_id, gateway_id,
                attempt_number, gateway_sk, started_date_key,
                started_at, finished_at,
                payment_method COLLATE Latin1_General_100_BIN2,
                outcome COLLATE Latin1_General_100_BIN2,
                failure_reason COLLATE Latin1_General_100_BIN2,
                latency_ms
            FROM main.fact_payment_attempt

            EXCEPT

            SELECT
                attempt_id, intent_id, gateway_id,
                attempt_number, gateway_sk, started_date_key,
                started_at, finished_at,
                payment_method COLLATE Latin1_General_100_BIN2,
                outcome COLLATE Latin1_General_100_BIN2,
                failure_reason COLLATE Latin1_General_100_BIN2,
                latency_ms
            FROM #ResolvedAttempt
        )
            THROW 53025, 'Full snapshot reconciliation failed.', 1;

        -- 26. Capture attempt outcome statistics
        SELECT
            @SucceededRows = COUNT_BIG(
                CASE WHEN outcome = 'succeeded' THEN 1 END
            ),
            @FailedRows = COUNT_BIG(
                CASE WHEN outcome = 'failed' THEN 1 END
            ),
            @PendingRows = COUNT_BIG(
                CASE WHEN outcome = 'pending' THEN 1 END
            )
        FROM main.fact_payment_attempt;

        COMMIT TRANSACTION;

        -- 27. Return execution summary
        SELECT
            'SUCCESS' AS load_status,
            @SourceRows AS source_rows,
            @TargetRows AS target_rows,
            @InsertedRows AS inserted_rows,
            @UpdatedRows AS updated_rows,
            @SourceRows - @InsertedRows - @UpdatedRows
                AS unchanged_rows,
            @SucceededRows AS succeeded_attempts,
            @FailedRows AS failed_attempts,
            @PendingRows AS pending_attempts,
            @LoadUTC AS load_started_utc,
            SYSUTCDATETIME() AS completed_at_utc;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH
END;
GO

-- 28. Execute the procedure
EXEC dbo.usp_LoadFactPaymentAttempt;
