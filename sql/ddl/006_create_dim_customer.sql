
-- ====================================================
-- DDL: main.dim_customer
-- Strategy: SCD Type 2
-- ====================================================

-- 1. Ensure the main schema exists
IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- 2. Verify prerequisite dimension
IF OBJECT_ID(N'main.dim_market', N'U') IS NULL
    THROW 51001, 'Create dim_market first.', 1;

-- 3. Create the dimension
IF OBJECT_ID(N'main.dim_customer', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_customer (
        -- Surrogate primary key
        customer_sk BIGINT IDENTITY(1,1) NOT NULL,

        -- Source business attributes
        customer_id BIGINT NOT NULL,
        signed_up_at DATETIME2(6) NOT NULL,
        country_code VARCHAR(2) NOT NULL,
        acquisition_channel NVARCHAR(100) NOT NULL,
        is_verified BIT NOT NULL,

        -- SCD Type 2 history
        valid_from DATETIME2(7) NOT NULL,
        valid_to DATETIME2(7) NOT NULL,
        is_current BIT NOT NULL,
        version_number INT NOT NULL,

        CONSTRAINT PK_dim_customer
            PRIMARY KEY CLUSTERED (customer_sk),

        CONSTRAINT CK_dim_customer_id
            CHECK (customer_id > 0),

        CONSTRAINT CK_dim_customer_country
            CHECK (
                DATALENGTH(country_code) = 2
                AND country_code COLLATE Latin1_General_100_BIN2
                    LIKE '[A-Z][A-Z]'
            ),

        CONSTRAINT CK_dim_customer_channel
            CHECK (
                DATALENGTH(TRIM(acquisition_channel)) > 0
            ),

        CONSTRAINT CK_dim_customer_version
            CHECK (version_number >= 1),

        CONSTRAINT CK_dim_customer_validity
            CHECK (valid_from < valid_to),

        CONSTRAINT CK_dim_customer_current
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
