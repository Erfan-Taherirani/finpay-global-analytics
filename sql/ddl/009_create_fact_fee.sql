
-- ====================================================
-- DDL: main.fact_fee
-- Strategy: Financial Event Fact (No SCD Type 2)
-- Grain: One row per fee_id
-- ====================================================

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- Verify required parent tables
IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
    THROW 54001, 'Create fact_payment_intent first.', 1;

IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 54002, 'Create dim_currency first.', 1;

IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
    THROW 54003, 'Create dim_date first.', 1;

-- Create the fee fact
IF OBJECT_ID(N'main.fact_fee', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_fee (
        fee_id BIGINT NOT NULL,
        intent_id BIGINT NOT NULL,
        dispute_id BIGINT NULL,

        assessed_at DATETIME2(6) NOT NULL,
        assessed_date_key INT NOT NULL,

        fee_type VARCHAR(20) NOT NULL,
        settlement_currency VARCHAR(3) NOT NULL,

        amount_settlement_major DECIMAL(19,4) NOT NULL,
        amount_settlement_major_usd DECIMAL(28,8) NULL,

        CONSTRAINT PK_fact_fee
            PRIMARY KEY CLUSTERED (fee_id),

        CONSTRAINT FK_fact_fee_intent
            FOREIGN KEY (intent_id)
            REFERENCES main.fact_payment_intent(intent_id),

        CONSTRAINT FK_fact_fee_currency
            FOREIGN KEY (settlement_currency)
            REFERENCES main.dim_currency(currency_code),

        CONSTRAINT FK_fact_fee_date
            FOREIGN KEY (assessed_date_key)
            REFERENCES main.dim_date(date_key),

        CONSTRAINT CK_fact_fee_ids
            CHECK (
                fee_id > 0
                AND intent_id > 0
                AND (
                    dispute_id IS NULL
                    OR dispute_id > 0
                )
            ),

        CONSTRAINT CK_fact_fee_type
            CHECK (
                fee_type COLLATE Latin1_General_100_BIN2
                IN (
                    'merchant_fee',
                    'processor_cost',
                    'dispute_fee'
                )
            ),

        CONSTRAINT CK_fact_fee_dispute
            CHECK (
                (
                    fee_type = 'dispute_fee'
                    AND dispute_id IS NOT NULL
                )
                OR
                (
                    fee_type <> 'dispute_fee'
                    AND dispute_id IS NULL
                )
            ),

        CONSTRAINT CK_fact_fee_currency_code
            CHECK (
                DATALENGTH(settlement_currency) = 3
                AND settlement_currency
                    COLLATE Latin1_General_100_BIN2
                    LIKE '[A-Z][A-Z][A-Z]'
            ),

        CONSTRAINT CK_fact_fee_amount
            CHECK (
                amount_settlement_major > 0
                AND (
                    amount_settlement_major_usd IS NULL
                    OR amount_settlement_major_usd > 0
                )
            ),

        CONSTRAINT CK_fact_fee_date_key
            CHECK (
                assessed_date_key =
                    YEAR(assessed_at) * 10000
                    + MONTH(assessed_at) * 100
                    + DAY(assessed_at)
            )
    );

    -- One assessment per fee category per intent
    -- Under the simplified FinPay business model
    CREATE UNIQUE NONCLUSTERED INDEX
        UX_fact_fee_intent_type
    ON main.fact_fee (
        intent_id,
        fee_type
    );

    -- One dispute fee per dispute
    CREATE UNIQUE NONCLUSTERED INDEX
        UX_fact_fee_dispute
    ON main.fact_fee (dispute_id)
    WHERE dispute_id IS NOT NULL;

    -- Fee analysis by assessment date
    CREATE NONCLUSTERED INDEX
        IX_fact_fee_date_type
    ON main.fact_fee (
        assessed_date_key,
        fee_type
    )
    INCLUDE (
        settlement_currency,
        amount_settlement_major_usd
    );

    -- Currency-based financial analysis
    CREATE NONCLUSTERED INDEX
        IX_fact_fee_currency_date
    ON main.fact_fee (
        settlement_currency,
        assessed_date_key
    )
    INCLUDE (
        fee_type,
        amount_settlement_major
    );
END;
