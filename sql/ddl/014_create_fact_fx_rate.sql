
-- ============================================
-- DDL: main.fact_fx_rate
-- Strategy: Daily FX Reference Fact
-- ============================================

IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
    THROW 59001, 'Create dim_currency first.', 1;

IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
    THROW 59002, 'Create dim_date first.', 1;

IF OBJECT_ID(N'main.fact_fx_rate', N'U') IS NULL
BEGIN
    CREATE TABLE main.fact_fx_rate (
        rate_date DATE NOT NULL,
        currency_code VARCHAR(3) NOT NULL,

        usd_per_major_unit DECIMAL(28,12) NULL,
        observation_date DATE NULL,
        provider NVARCHAR(100) NULL,
        rate_status NVARCHAR(40) NOT NULL,

        rate_date_key INT NOT NULL,

        CONSTRAINT PK_fact_fx_rate
            PRIMARY KEY CLUSTERED (
                rate_date,
                currency_code
            ),

        CONSTRAINT FK_fx_currency
            FOREIGN KEY (currency_code)
            REFERENCES main.dim_currency(currency_code),

        CONSTRAINT FK_fx_date
            FOREIGN KEY (rate_date_key)
            REFERENCES main.dim_date(date_key),

        CONSTRAINT CK_fx_rate_positive
            CHECK (
                usd_per_major_unit IS NULL
                OR usd_per_major_unit > 0
            ),

        CONSTRAINT CK_fx_usd_identity
            CHECK (
                currency_code <> 'USD'
                OR usd_per_major_unit IS NULL
                OR usd_per_major_unit = 1
            ),

        CONSTRAINT CK_fx_observation_date
            CHECK (
                observation_date IS NULL
                OR observation_date <= rate_date
            ),

        CONSTRAINT CK_fx_rate_status
            CHECK (
                DATALENGTH(TRIM(rate_status)) > 0
            ),

        CONSTRAINT CK_fx_date_key
            CHECK (
                rate_date_key =
                    YEAR(rate_date) * 10000
                    + MONTH(rate_date) * 100
                    + DAY(rate_date)
            )
    );

    -- Efficient history lookups by currency
    CREATE NONCLUSTERED INDEX IX_fx_currency_date
        ON main.fact_fx_rate (
            currency_code,
            rate_date
        )
        INCLUDE (
            usd_per_major_unit,
            observation_date,
            rate_status
        );
END;
