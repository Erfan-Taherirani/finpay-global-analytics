
-- ==============================================
-- DDL: main.fact_refund
-- Strategy: Non-SCD Financial Fact
-- ==============================================

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
    THROW 55001, 'Create fact_payment_intent first.', 1;

IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 55002, 'Create dim_currency first.', 1;

IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
    THROW 55003, 'Create dim_date first.', 1;

IF OBJECT_ID(N'main.fact_refund', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_refund (
        refund_id BIGINT NOT NULL,
        intent_id BIGINT NOT NULL,

        requested_at DATETIME2(6) NOT NULL,
        completed_at DATETIME2(6) NULL,
        requested_date_key INT NOT NULL,
        minutes_to_refund DECIMAL(20,3) NULL,

        [status] VARCHAR(30) NOT NULL,
        reason NVARCHAR(200) NULL,
        currency_code VARCHAR(3) NOT NULL,

        amount_major DECIMAL(19,4) NOT NULL,
        settlement_debit_major DECIMAL(19,4) NULL,
        amount_major_usd DECIMAL(28,8) NULL,
        settlement_debit_major_usd DECIMAL(28,8) NULL,

        CONSTRAINT PK_fact_refund
            PRIMARY KEY CLUSTERED (refund_id),

        CONSTRAINT CK_fact_refund_basic
            CHECK (
                refund_id > 0
                AND intent_id > 0
                AND amount_major > 0
                AND (
                    settlement_debit_major IS NULL
                    OR settlement_debit_major >= 0
                )
                AND (
                    amount_major_usd IS NULL
                    OR amount_major_usd >= 0
                )
                AND (
                    settlement_debit_major_usd IS NULL
                    OR settlement_debit_major_usd >= 0
                )
            ),

        CONSTRAINT CK_fact_refund_status
            CHECK (
                [status] COLLATE Latin1_General_100_BIN2
                IN ('succeeded', 'completed', 'failed', 'pending')
            ),

        CONSTRAINT CK_fact_refund_lifecycle
            CHECK (
                (completed_at IS NULL
                 AND minutes_to_refund IS NULL)
                OR
                (completed_at IS NOT NULL
                 AND completed_at >= requested_at
                 AND minutes_to_refund IS NOT NULL
                 AND minutes_to_refund >= 0)
            ),

        CONSTRAINT CK_fact_refund_pending
            CHECK (
                [status] <> 'pending'
                OR completed_at IS NULL
            ),

        CONSTRAINT CK_fact_refund_date_key
            CHECK (
                requested_date_key =
                    YEAR(requested_at) * 10000
                    + MONTH(requested_at) * 100
                    + DAY(requested_at)
            )
    );
END;
