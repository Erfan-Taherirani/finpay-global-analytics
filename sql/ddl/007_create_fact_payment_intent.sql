
-- ======================================================
-- DDL: main.fact_payment_intent
-- Strategy: Accumulating Snapshot Fact (No SCD Type 2)
-- Grain: One row per intent_id
-- ======================================================

-- 1. Ensure the main schema exists
IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- 2. Verify required dimensions
IF OBJECT_ID(N'main.dim_merchant', N'U') IS NULL
    THROW 52001, 'Create dim_merchant first.', 1;

IF OBJECT_ID(N'main.dim_customer', N'U') IS NULL
    THROW 52002, 'Create dim_customer first.', 1;

IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 52003, 'Create dim_currency first.', 1;

IF OBJECT_ID(N'main.dim_market', N'U') IS NULL
    THROW 52004, 'Create dim_market first.', 1;

IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
    THROW 52005, 'Create dim_date first.', 1;

-- 3. Create the fact table
IF OBJECT_ID(N'main.fact_payment_intent', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_payment_intent (
        -- Business identifiers
        intent_id BIGINT NOT NULL,
        merchant_id BIGINT NOT NULL,
        customer_id BIGINT NULL,

        -- Analytical surrogate keys
        merchant_sk BIGINT NOT NULL,
        customer_sk BIGINT NULL,
        created_date_key INT NOT NULL,

        -- Checkout attributes
        created_at DATETIME2(6) NOT NULL,
        buyer_country VARCHAR(2) NULL,
        checkout_channel VARCHAR(50) NOT NULL,
        presentment_currency VARCHAR(3) NOT NULL,
        final_outcome VARCHAR(20) NOT NULL,

        -- Payment lifecycle timestamps
        closed_at DATETIME2(6) NULL,
        captured_at DATETIME2(6) NULL,

        -- Local-currency major-unit amounts
        amount_major DECIMAL(19,4) NOT NULL,
        captured_settlement_major DECIMAL(19,4) NULL,

        -- Durations in seconds
        payment_resolution_time DECIMAL(20,3) NULL,
        time_to_capture DECIMAL(20,3) NULL,

        -- USD reporting amounts
        amount_major_usd DECIMAL(28,8) NULL,
        captured_settlement_major_usd DECIMAL(28,8) NULL,

        -- Primary key
        CONSTRAINT PK_fact_payment_intent
            PRIMARY KEY CLUSTERED (intent_id),

        -- Dimension relationships
        CONSTRAINT FK_fact_intent_merchant
            FOREIGN KEY (merchant_sk)
            REFERENCES main.dim_merchant(merchant_sk),

        CONSTRAINT FK_fact_intent_customer
            FOREIGN KEY (customer_sk)
            REFERENCES main.dim_customer(customer_sk),

        CONSTRAINT FK_fact_intent_created_date
            FOREIGN KEY (created_date_key)
            REFERENCES main.dim_date(date_key),

        CONSTRAINT FK_fact_intent_currency
            FOREIGN KEY (presentment_currency)
            REFERENCES main.dim_currency(currency_code),

        CONSTRAINT FK_fact_intent_buyer_market
            FOREIGN KEY (buyer_country)
            REFERENCES main.dim_market(country_code),

        -- Required identifiers
        CONSTRAINT CK_fact_intent_ids
            CHECK (
                intent_id > 0
                AND merchant_id > 0
                AND (customer_id IS NULL OR customer_id > 0)
                AND (
                    (customer_id IS NULL AND customer_sk IS NULL)
                    OR
                    (customer_id IS NOT NULL AND customer_sk IS NOT NULL)
                )
            ),

        -- Currency and country formats
        CONSTRAINT CK_fact_intent_codes
            CHECK (
                DATALENGTH(presentment_currency) = 3
                AND presentment_currency
                    COLLATE Latin1_General_100_BIN2
                    LIKE '[A-Z][A-Z][A-Z]'

                AND (
                    buyer_country IS NULL
                    OR (
                        DATALENGTH(buyer_country) = 2
                        AND buyer_country
                            COLLATE Latin1_General_100_BIN2
                            LIKE '[A-Z][A-Z]'
                    )
                )
            ),

        -- Checkout and outcome rules
        CONSTRAINT CK_fact_intent_attributes
            CHECK (
                DATALENGTH(TRIM(checkout_channel)) > 0
                AND final_outcome IN (
                    'succeeded',
                    'failed',
                    'abandoned',
                    'pending'
                )
            ),

        -- Monetary validity
        CONSTRAINT CK_fact_intent_amounts
            CHECK (
                amount_major > 0

                AND (
                    captured_settlement_major IS NULL
                    OR captured_settlement_major >= 0
                )

                AND (
                    amount_major_usd IS NULL
                    OR amount_major_usd >= 0
                )

                AND (
                    captured_settlement_major_usd IS NULL
                    OR captured_settlement_major_usd >= 0
                )
            ),

        -- Lifecycle consistency
        CONSTRAINT CK_fact_intent_outcome
            CHECK (
                (
                    final_outcome = 'succeeded'
                    AND captured_at IS NOT NULL
                    AND closed_at IS NOT NULL
                    AND captured_settlement_major > 0
                )
                OR
                (
                    final_outcome <> 'succeeded'
                    AND captured_at IS NULL
                    AND (
                        captured_settlement_major IS NULL
                        OR captured_settlement_major = 0
                    )
                    AND (
                        captured_settlement_major_usd IS NULL
                        OR captured_settlement_major_usd = 0
                    )
                )
            ),

        CONSTRAINT CK_fact_intent_pending
            CHECK (
                final_outcome <> 'pending'
                OR closed_at IS NULL
            )
    );

    -- Merchant-level payment analysis
    CREATE NONCLUSTERED INDEX
        IX_fact_intent_merchant_date
    ON main.fact_payment_intent (
        merchant_sk,
        created_date_key
    )
    INCLUDE (
        final_outcome,
        amount_major_usd,
        captured_settlement_major_usd
    );

    -- Customer-level analysis (registered customers only)
    CREATE NONCLUSTERED INDEX
        IX_fact_intent_customer
    ON main.fact_payment_intent (
        customer_sk,
        created_at
    )
    WHERE customer_sk IS NOT NULL;

    -- Time-series reporting
    CREATE NONCLUSTERED INDEX
        IX_fact_intent_created_date
    ON main.fact_payment_intent (
        created_date_key,
        final_outcome
    )
    INCLUDE (
        amount_major_usd,
        captured_settlement_major_usd
    );
END;
