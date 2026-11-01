
IF OBJECT_ID(N'main.dim_currency', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_currency (
        currency_code VARCHAR(3) NOT NULL,
        minor_units TINYINT NOT NULL,

        CONSTRAINT PK_dim_currency
            PRIMARY KEY CLUSTERED (currency_code),

        CONSTRAINT CK_dim_currency_minor_units
            CHECK (minor_units BETWEEN 0 AND 4)
    );
END;
