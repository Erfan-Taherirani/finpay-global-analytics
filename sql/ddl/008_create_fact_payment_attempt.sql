
-- ===================================================
-- DDL: main.fact_payment_attempt
-- Strategy: Event Fact + Transactional Upsert
-- Grain: One row per attempt_id
-- ===================================================

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- Verify required parent tables
IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
    THROW 53001, 'Create fact_payment_intent first.', 1;

IF OBJECT_ID(N'main.dim_gateway', N'U') IS NULL
    THROW 53002, 'Create dim_gateway first.', 1;

IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
    THROW 53003, 'Create dim_date first.', 1;

IF OBJECT_ID(N'main.fact_payment_attempt', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_payment_attempt (
        -- Source business identifiers
        attempt_id BIGINT NOT NULL,
        intent_id BIGINT NOT NULL,
        gateway_id INT NOT NULL,
        attempt_number TINYINT NOT NULL,

        -- Analytical dimension keys
        gateway_sk BIGINT NOT NULL,
        started_date_key INT NOT NULL,

        -- Payment attempt attributes
        started_at DATETIME2(6) NOT NULL,
        finished_at DATETIME2(6) NULL,
        payment_method VARCHAR(20) NOT NULL,
        outcome VARCHAR(20) NOT NULL,
        failure_reason NVARCHAR(200) NULL,
        latency_ms INT

        CONSTRAINT PK_fact_payment_attempt
            PRIMARY KEY CLUSTERED (attempt_id),

        CONSTRAINT CK_fact_attempt_ids
            CHECK (
                attempt_id > 0
                AND intent_id > 0
                AND gateway_id > 0
            ),

        CONSTRAINT CK_fact_attempt_number
            CHECK (attempt_number BETWEEN 1 AND 3),

        CONSTRAINT CK_fact_attempt_method
            CHECK (
                payment_method IN (
                    'card',
                    'wallet',
                    'bank_debit'
                )
            ),

        CONSTRAINT CK_fact_attempt_outcome
            CHECK (
                outcome IN (
                    'succeeded',
                    'failed',
                    'pending'
                )
            ),

        CONSTRAINT CK_fact_attempt_failure_reason
            CHECK (
                failure_reason IS NULL
                OR DATALENGTH(TRIM(failure_reason)) > 0
            )
    );
END;
