# Standalone SQL query and reporting patterns

Use when the user wants a `SELECT`, CTE, view, QA query or reporting query instead of designing new DDL and ETL.

## Checklist before writing a query

1. Confirm database engine and exact tables, columns and metric definitions from the current project.
2. Declare result grain: one row per order, seller/day, currency/month, etc.
3. Identify whether each join is truly 1:many or many:many, especially when joining multiple facts or SCD2 dimensions.
4. Filter with documented lifecycle statuses, currencies, time zones and snapshot cutoffs.
5. Avoid implicit date conversion and row-by-row `CAST` on indexed columns; use half-open timestamp bounds.
6. Use explicit `JOIN`, `GROUP BY`, CTE or subquery semantics; avoid hiding duplicated facts with `DISTINCT`.
7. For financial reports, group original amounts by currency or use verified date-specific USD conversion.
8. Return a concise explanation of the query's grain, assumptions and performance considerations. Add test SQL only when useful or requested.

## Example: seller's daily shipped order count

Illustrative retail schema: `main.fact_order(order_id, seller_sk, placed_at, order_status, order_total_minor, currency_code)` and SCD2 `main.dim_seller(seller_sk, seller_id, display_name, ...)`.

```sql
DECLARE @StartUTC DATETIME2(6) = '2026-01-01T00:00:00';
DECLARE @EndUTC   DATETIME2(6) = '2026-02-01T00:00:00';

SELECT
    d.seller_id,
    CONVERT(DATE, f.placed_at) AS order_date_utc,
    f.currency_code,
    COUNT_BIG(*) AS shipped_orders,
    SUM(CONVERT(DECIMAL(38,0), f.order_total_minor)) AS shipped_minor_units
FROM main.fact_order AS f
JOIN main.dim_seller AS d
    ON d.seller_sk = f.seller_sk
WHERE f.placed_at >= @StartUTC
  AND f.placed_at < @EndUTC
  AND f.order_status = 'shipped'
GROUP BY d.seller_id, CONVERT(DATE, f.placed_at), f.currency_code;
```

This query **does not convert different local currencies**: values are grouped by `currency_code`. A specific amount's minor-unit magnitude still depends on that currency; convert using `dim_currency.minor_units` before comparing across currencies. This example's status `shipped` is **fictional** and must be replaced by the project's actual enum.

## Prevent multi-fact fanout

- Do not join detailed orders directly to detailed refunds and fees and then sum all three; this multiplies rows whenever an order has multiple refunds or fees.
- Preaggregate each fact to a common business grain using separate CTEs before joining them; or use semantic-model measures that aggregate each fact independently.
- When SCD2 dimension versions are needed, join facts using already-resolved `*_sk` when correct. Joining an event to `dim_entity` on `entity_id` without `is_current`/as-of selection duplicates events across history.
- Name measures by role (gross volume, net settled, authorized/captured, liabilities) and document any status filters and date meanings.

## Performance review

- Inspect actual query plans for large workloads before creating redundant indexes.
- Use indexed key columns and sargable filters. Avoid applying `YEAR()`, `CAST()` or `FORMAT()` to a filtered indexed timestamp when a range predicate can do the job.
- Check row-count and distinct-key expectations before/after joins.
- For Power BI, prefer dimensional modeling and source SQL views for common stable transformations; don't hardcode a different date/currency logic into each report.
