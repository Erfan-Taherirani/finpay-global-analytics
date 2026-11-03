
-- =================================================
-- DDL: main.fact_merchant_ledger
-- Strategy: Immutable Financial Posting Fact
-- =================================================

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

IF OBJECT_ID(N'main.dim_merchant', N'U') IS NULL
    THROW 58001, 'Create dim_merchant first.', 1;

IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 58002, 'Create dim_currency first.', 1;

IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
    THROW 58003, 'Create dim_date first.', 1;

IF OBJECT_ID(N'main.fact_merchant_ledger', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_merchant_ledger (
        entry_id BIGINT NOT NULL,
        merchant_id BIGINT NOT NULL,
        merchant_sk BIGINT NOT NULL,

        currency_code VARCHAR(3) NOT NULL,
        posted_at DATETIME2(6) NOT NULL,
        posted_date_key INT NOT NULL,

        event_type VARCHAR(30) NOT NULL,
        source_id BIGINT NOT NULL,

        signed_amount_major DECIMAL(19,4) NOT NULL,
        signed_amount_minor BIGINT NOT NULL,
        signed_amount_major_usd DECIMAL(28,8) NULL,

        CONSTRAINT PK_fact_merchant_ledger
            PRIMARY KEY CLUSTERED (entry_id),

        CONSTRAINT CK_ledger_ids
            CHECK (
                entry_id > 0
                AND merchant_id > 0
                AND source_id > 0
            ),

        CONSTRAINT CK_ledger_event
            CHECK (
                event_type COLLATE Latin1_General_100_BIN2 IN (
                    'capture_credit',
                    'merchant_fee_debit',
                    'refund_debit',
                    'dispute_debit',
                    'dispute_fee_debit',
                    'payout_debit'
                )
            ),

        CONSTRAINT CK_ledger_sign
            CHECK (
                (
                    event_type = 'capture_credit'
                    AND signed_amount_major > 0
                    AND signed_amount_minor > 0
                )
                OR
                (
                    event_type <> 'capture_credit'
                    AND signed_amount_major < 0
                    AND signed_amount_minor < 0
                )
            ),

        CONSTRAINT CK_ledger_date_key
            CHECK (
                posted_date_key =
                    YEAR(posted_at) * 10000
                    + MONTH(posted_at) * 100
                    + DAY(posted_at)
            ),
    );
END;
