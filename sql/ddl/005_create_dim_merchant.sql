
-- ===================================================
-- DDL: main.dim_merchant
-- Strategy: SCD Type 2
-- ===================================================

-- 1. Ensure the main schema exists
IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- 2. Verify prerequisite dimensions
IF OBJECT_ID(N'main.dim_market', N'U') IS NULL
    THROW 51001, 'Create dim_market first.', 1;

IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 51002, 'Create dim_currency first.', 1;

-- 3. Create the SCD Type 2 dimension
IF OBJECT_ID(N'main.dim_merchant', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_merchant (
        -- Surrogate key
        merchant_sk BIGINT IDENTITY(1,1) NOT NULL,

        -- Source business attributes
        merchant_id BIGINT NOT NULL,
        merchant_name NVARCHAR(200) NOT NULL,
        country_code VARCHAR(2) NOT NULL,
        industry NVARCHAR(100) NOT NULL,
        onboarded_at DATETIME2(3) NOT NULL,
        settlement_currency VARCHAR(3) NOT NULL,
        pricing_tier VARCHAR(30) NOT NULL,
        payout_frequency VARCHAR(30) NOT NULL,
        account_status VARCHAR(30) NOT NULL,

        -- Historical version tracking
        valid_from DATETIME2(7) NOT NULL,
        valid_to DATETIME2(7) NOT NULL,
        is_current BIT NOT NULL,
        version_number INT NOT NULL,

        CONSTRAINT PK_dim_merchant
            PRIMARY KEY CLUSTERED (merchant_sk),

        CONSTRAINT CK_dim_merchant_id
            CHECK (merchant_id > 0),

        CONSTRAINT CK_dim_merchant_country
            CHECK (
                DATALENGTH(country_code) = 2
                AND country_code COLLATE Latin1_General_100_BIN2
                    LIKE '[A-Z][A-Z]'
            ),

        CONSTRAINT CK_dim_merchant_currency
            CHECK (
                DATALENGTH(settlement_currency) = 3
                AND settlement_currency COLLATE Latin1_General_100_BIN2
                    LIKE '[A-Z][A-Z][A-Z]'
            ),

        CONSTRAINT CK_dim_merchant_required_text
            CHECK (
                DATALENGTH(TRIM(merchant_name)) > 0
                AND DATALENGTH(TRIM(industry)) > 0
                AND DATALENGTH(TRIM(pricing_tier)) > 0
                AND DATALENGTH(TRIM(payout_frequency)) > 0
                AND DATALENGTH(TRIM(account_status)) > 0
            ),

        CONSTRAINT CK_dim_merchant_version
            CHECK (version_number >= 1),

        CONSTRAINT CK_dim_merchant_validity
            CHECK (valid_from < valid_to),

        CONSTRAINT CK_dim_merchant_current
            CHECK (
                (
                    is_current = 1
                    AND valid_to =
                        '9999-12-31T23:59:59.9999999'
                )
                OR
                (
                    is_current = 0
                    AND valid_to <
                        '9999-12-31T23:59:59.9999999'
                )
            ),
    );
END;
