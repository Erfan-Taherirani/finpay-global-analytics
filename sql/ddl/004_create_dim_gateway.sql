
-- ================================================
-- DDL: main.dim_gateway
-- Strategy: SCD Type 2
-- ================================================

-- 1. Ensure the main schema exists
IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- 2. Create the dimension table
IF OBJECT_ID(N'main.dim_gateway', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_gateway (
        gateway_sk BIGINT IDENTITY(1,1) NOT NULL,
        gateway_id INT NOT NULL,
        gateway_name NVARCHAR(150) NOT NULL,
        home_region NVARCHAR(100) NOT NULL,
        is_enabled BIT NOT NULL,

        valid_from DATETIME2(7) NOT NULL,
        valid_to DATETIME2(7) NOT NULL,
        is_current BIT NOT NULL,
        version_number INT NOT NULL,

        -- Unique identifier for each historical version
        CONSTRAINT PK_dim_gateway
            PRIMARY KEY CLUSTERED (gateway_sk),

        -- Business key and version validation
        CONSTRAINT CK_dim_gateway_key
            CHECK (gateway_id > 0),

        CONSTRAINT CK_dim_gateway_version
            CHECK (version_number > 0),

        CONSTRAINT CK_dim_gateway_required_text
            CHECK (
                DATALENGTH(TRIM(gateway_name)) > 0
                AND DATALENGTH(TRIM(home_region)) > 0
            ),

        -- Half-open validity intervals
        CONSTRAINT CK_dim_gateway_dates
            CHECK (valid_from < valid_to),

        -- Current rows must have an open-ended validity
        CONSTRAINT CK_dim_gateway_current
            CHECK (
                (is_current = 1 AND
                 valid_to = '9999-12-31T23:59:59.9999999')
                OR
                (is_current = 0 AND
                 valid_to < '9999-12-31T23:59:59.9999999')
            ),
    );
END;
