
-- Run once. Requires main.dim_currency to exist.
IF OBJECT_ID(N'main.fact_fee', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_fee (
        fee_id BIGINT NOT NULL,
        intent_id BIGINT NOT NULL,
        dispute_id BIGINT NULL,
        assessed_at DATETIME2(3) NOT NULL,
        fee_type VARCHAR(20) NOT NULL,
        settlement_currency VARCHAR(3) NOT NULL,
        amount_settlement_major DECIMAL(19,4) NOT NULL,
        amount_settlement_major_usd DECIMAL(28,8) NULL,

        CONSTRAINT PK_fact_fee
            PRIMARY KEY CLUSTERED (fee_id),

        CONSTRAINT CK_fact_fee_ids
            CHECK (
                fee_id > 0 AND intent_id > 0
                AND (dispute_id IS NULL OR dispute_id > 0)
            ),

        CONSTRAINT CK_fact_fee_type
            CHECK (
                fee_type COLLATE Latin1_General_100_BIN2 IN
                ('merchant_fee', 'processor_cost', 'dispute_fee')
            ),

        CONSTRAINT CK_fact_fee_dispute
            CHECK (
                (fee_type = 'dispute_fee' AND dispute_id IS NOT NULL)
                OR
                (fee_type <> 'dispute_fee' AND dispute_id IS NULL)
            ),

        CONSTRAINT CK_fact_fee_amounts
            CHECK (
                amount_settlement_major >= 0
                AND (
                    amount_settlement_major_usd IS NULL
                    OR amount_settlement_major_usd >= 0
                )
            ),

        CONSTRAINT FK_fact_fee_currency
            FOREIGN KEY (settlement_currency)
            REFERENCES main.dim_currency(currency_code)
    );

    -- Support payment-level joins
    CREATE INDEX IX_fact_fee_intent
        ON main.fact_fee (intent_id);

    -- Support date-range reporting and refreshes
    CREATE INDEX IX_fact_fee_assessed_at
        ON main.fact_fee (assessed_at);
END;
