
-- Run once, before the stored procedure.
-- Requires the main schema and main.dim_currency.

IF OBJECT_ID(N'main.dim_merchant', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_merchant (
        merchant_id BIGINT NOT NULL,
        merchant_name NVARCHAR(200) NOT NULL,
        country_code VARCHAR(2) NOT NULL,
        industry NVARCHAR(100) NOT NULL,
        onboarded_at DATETIME2(3) NOT NULL,
        settlement_currency VARCHAR(3) NOT NULL,
        pricing_tier VARCHAR(30) NOT NULL,
        payout_frequency VARCHAR(30) NOT NULL,
        account_status VARCHAR(30) NOT NULL,

        CONSTRAINT PK_dim_merchant
            PRIMARY KEY CLUSTERED (merchant_id),

        CONSTRAINT CK_dim_merchant_id
            CHECK (merchant_id > 0),

        CONSTRAINT CK_dim_merchant_name
            CHECK (LEN(TRIM(merchant_name)) > 0),

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

        CONSTRAINT FK_dim_merchant_currency
            FOREIGN KEY (settlement_currency)
            REFERENCES main.dim_currency(currency_code)
    );
END;
