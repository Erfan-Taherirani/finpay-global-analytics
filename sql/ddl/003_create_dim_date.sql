
-- ============================================
-- DDL: main.dim_date
-- Strategy: Static Calendar Dimension
-- ============================================

-- 1. Ensure the main schema exists
IF SCHEMA_ID(N'main') IS NULL
    EXEC(N'CREATE SCHEMA main');

-- 2. Create the date dimension
IF OBJECT_ID(N'main.dim_date', N'U') IS NULL
BEGIN
    CREATE TABLE main.dim_date (
        date_key INT NOT NULL,
        date_utc DATE NOT NULL,
        [year] SMALLINT NOT NULL,
        [month] TINYINT NOT NULL,
        day_of_month TINYINT NOT NULL,
        [week] TINYINT NOT NULL,
        day_of_week TINYINT NOT NULL,
        is_business_day BIT NOT NULL,
        month_start DATE NOT NULL,
        month_end DATE NOT NULL,
        is_weekend BIT NOT NULL,

        CONSTRAINT PK_dim_date
            PRIMARY KEY CLUSTERED (date_key),

        CONSTRAINT UQ_dim_date_date_utc
            UNIQUE NONCLUSTERED (date_utc),

        CONSTRAINT CK_dim_date_calendar
            CHECK (
                date_key =
                    YEAR(date_utc) * 10000
                    + MONTH(date_utc) * 100
                    + DAY(date_utc)

                AND [year] = YEAR(date_utc)
                AND [month] = MONTH(date_utc)
                AND day_of_month = DAY(date_utc)

                AND [week] = DATEPART(ISO_WEEK, date_utc)

                AND day_of_week =
                    DATEDIFF(
                        DAY,
                        CONVERT(DATE, '19000101', 112),
                        date_utc
                    ) % 7 + 1

                AND month_start =
                    DATEFROMPARTS(
                        YEAR(date_utc),
                        MONTH(date_utc),
                        1
                    )

                AND month_end = EOMONTH(date_utc)
            ),

        CONSTRAINT CK_dim_date_business_days
            CHECK (
                is_weekend =
                    CASE
                        WHEN day_of_week IN (6, 7) THEN 1
                        ELSE 0
                    END

                AND is_business_day =
                    CASE
                        WHEN day_of_week BETWEEN 1 AND 5 THEN 1
                        ELSE 0
                    END
            )
    );
END;
