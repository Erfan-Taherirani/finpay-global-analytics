
-- ==============================================
-- DDL: main.fact_dispute
-- Strategy: Non-SCD Dispute Lifecycle Fact
-- ==============================================

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
    THROW 56001, 'Create fact_payment_intent first.', 1;

IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 56002, 'Create dim_currency first.', 1;

IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
    THROW 56003, 'Create dim_date first.', 1;

IF OBJECT_ID(N'main.fact_dispute', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_dispute (
        dispute_id BIGINT NOT NULL,
        intent_id BIGINT NOT NULL,

        opened_at DATETIME2(6) NOT NULL,
        resolved_at DATETIME2(6) NULL,
        opened_date_key INT NOT NULL,
        minutes_to_resolve DECIMAL(20,3) NULL,

        [status] VARCHAR(20) NOT NULL,
        reason NVARCHAR(200) NULL,
        currency_code VARCHAR(3) NOT NULL,

        disputed_amount_major DECIMAL(19,4) NOT NULL,
        settlement_debit_major DECIMAL(19,4) NULL,
        disputed_amount_major_usd DECIMAL(28,8) NULL,
        settlement_debit_major_usd DECIMAL(28,8) NULL,

        CONSTRAINT PK_fact_dispute
            PRIMARY KEY CLUSTERED (dispute_id),

        CONSTRAINT CK_fact_dispute_basic
            CHECK (
                dispute_id > 0
                AND intent_id > 0
                AND disputed_amount_major > 0
                AND (
                    disputed_amount_major_usd IS NULL
                    OR disputed_amount_major_usd > 0
                )
            ),

        CONSTRAINT CK_fact_dispute_status
            CHECK (
                [status] COLLATE Latin1_General_100_BIN2
                IN ('open', 'won', 'lost')
            ),

        CONSTRAINT CK_fact_dispute_lifecycle
            CHECK (
                (
                    [status] = 'open'
                    AND resolved_at IS NULL
                    AND minutes_to_resolve IS NULL
                )
                OR
                (
                    [status] IN ('won', 'lost')
                    AND resolved_at IS NOT NULL
                    AND resolved_at >= opened_at
                    AND minutes_to_resolve IS NOT NULL
                    AND minutes_to_resolve >= 0
                )
            ),

        CONSTRAINT CK_fact_dispute_date_key
            CHECK (
                opened_date_key =
                    YEAR(opened_at) * 10000
                    + MONTH(opened_at) * 100
                    + DAY(opened_at)
            )
    );
END;
