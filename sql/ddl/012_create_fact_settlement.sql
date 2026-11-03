
-- ============================================
-- DDL: main.fact_settlement
-- Strategy: Non-SCD Payout Lifecycle Fact
-- ============================================

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

IF OBJECT_ID(N'main.dim_merchant', N'U') IS NULL
    THROW 57001, 'Create dim_merchant first.', 1;

IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 57002, 'Create dim_currency first.', 1;

IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
    THROW 57003, 'Create dim_date first.', 1;

IF OBJECT_ID(N'main.fact_settlement', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_settlement (
        settlement_id BIGINT NOT NULL,
        merchant_id BIGINT NOT NULL,
        merchant_sk BIGINT NOT NULL,

        currency_code VARCHAR(3) NOT NULL,

        initiated_at DATETIME2(6) NOT NULL,
        scheduled_at DATETIME2(6) NOT NULL,
        completed_at DATETIME2(6) NULL,
        initiated_date_key INT NOT NULL,

        [status] VARCHAR(20) NOT NULL,
        failure_reason NVARCHAR(200) NULL,

        time_to_scheduled_payout DECIMAL(20,3) NOT NULL,
        payout_completion_time DECIMAL(20,3) NULL,
        schedule_deviation DECIMAL(20,3) NULL,

        amount_major DECIMAL(19,4) NOT NULL,
        amount_major_usd DECIMAL(28,8) NULL,

        CONSTRAINT PK_fact_settlement
            PRIMARY KEY CLUSTERED (settlement_id),

        CONSTRAINT CK_fact_settlement_basic
            CHECK (
                settlement_id > 0
                AND merchant_id > 0
                AND amount_major > 0
                AND (
                    amount_major_usd IS NULL
                    OR amount_major_usd > 0
                )
            ),

        CONSTRAINT CK_fact_settlement_status
            CHECK (
                [status] COLLATE Latin1_General_100_BIN2
                IN ('pending', 'completed', 'failed')
            ),

        CONSTRAINT CK_fact_settlement_dates
            CHECK (
                scheduled_at >= initiated_at
                AND time_to_scheduled_payout >= 0
                AND (
                    completed_at IS NULL
                    OR completed_at >= initiated_at
                )
                AND (
                    (
                        completed_at IS NULL
                        AND payout_completion_time IS NULL
                    )
                    OR
                    (
                        completed_at IS NOT NULL
                        AND payout_completion_time >= 0
                    )
                )
            ),

        CONSTRAINT CK_fact_settlement_lifecycle
            CHECK (
                ([status] <> 'completed'
                 OR completed_at IS NOT NULL)
                AND
                ([status] <> 'pending'
                 OR completed_at IS NULL)
            ),

        CONSTRAINT CK_fact_settlement_date_key
            CHECK (
                initiated_date_key =
                    YEAR(initiated_at) * 10000
                    + MONTH(initiated_at) * 100
                    + DAY(initiated_at)
            )
    );
END;
