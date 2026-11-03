
-- ============================================
-- DDL: main.dim_market
-- Strategy: SCD Type 1
-- ============================================

-- 1. Ensure main schema exists
IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- 2. Verify prerequisite dimension
IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 51001, 'Load dim_currency first.', 1;

-- 3. Create the market dimension
IF OBJECT_ID(N'main.dim_market', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_market (
        country_code VARCHAR(2) NOT NULL,
        market_name NVARCHAR(150) NOT NULL,
        currency_code VARCHAR(3) NOT NULL,
        [timezone] VARCHAR(100) NOT NULL,

        CONSTRAINT PK_dim_market
            PRIMARY KEY CLUSTERED (country_code),

        CONSTRAINT CK_dim_market_country
            CHECK (
                DATALENGTH(country_code) = 2
                AND country_code COLLATE Latin1_General_100_BIN2
                    LIKE '[A-Z][A-Z]'
            ),

        CONSTRAINT CK_dim_market_currency
            CHECK (
                DATALENGTH(currency_code) = 3
                AND currency_code COLLATE Latin1_General_100_BIN2
                    LIKE '[A-Z][A-Z][A-Z]'
            ),

        CONSTRAINT CK_dim_market_required_text
            CHECK (
                DATALENGTH(TRIM(market_name)) > 0
                AND DATALENGTH(TRIM([timezone])) > 0
            ),

        CONSTRAINT FK_dim_market_currency
            FOREIGN KEY (currency_code)
            REFERENCES main.dim_currency(currency_code)
    );
END;
