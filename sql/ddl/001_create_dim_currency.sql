
-- ============================================
-- DDL: main.dim_currency
-- Strategy: SCD Type 1
-- ============================================

-- 1. Create the main schema if necessary
IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- 2. Create the dimension table
IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_currency (
        currency_code VARCHAR(3) NOT NULL,
        minor_units TINYINT NOT NULL,
        currency_name NVARCHAR(100) NOT NULL,

        CONSTRAINT PK_dim_currency
            PRIMARY KEY CLUSTERED (currency_code),

        CONSTRAINT CK_dim_currency_code
            CHECK (
                DATALENGTH(currency_code) = 3
                AND currency_code COLLATE Latin1_General_100_BIN2
                    LIKE '[A-Z][A-Z][A-Z]'
            ),

        CONSTRAINT CK_dim_currency_minor_units
            CHECK (minor_units BETWEEN 0 AND 4),

        CONSTRAINT CK_dim_currency_name
            CHECK (
                DATALENGTH(TRIM(currency_name)) > 0
            )
    );
END;
