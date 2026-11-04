# FinPay — Analytical Data Dictionary and New-Column Addendum (v3.0)

**Updated:** 2026-11-04  
**Scope:** Field-level analytical additions/changes observed in available FinPay preprocessing and SQL Server design notes. This is an **addendum**, not a verified dump of `INFORMATION_SCHEMA.COLUMNS` from a live warehouse.

## 1. Provenance legend

- **Documented preprocessing** = visible in the available Python/Polars `load_data()` logic that constructs processed CSVs.
- **Documented main ETL** = described in the SQL Server warehouse notes or the confirmed recent `fact_payment_intent` design change. The actual deployed table/column has **not** been inspected.
- **Recommended correction** = proposed here; it must not be treated as already implemented.

## 2. Fields enabling new/expanded business questions

| Table | Column | Definition and calculation | KPI relevance | Status |
|---|---|---|---|---|
| `main.fact_payment_intent` | `transaction_market_type` | `Domestic` if `buyer_country = merchant.country_code`, else `Cross-border` in the earlier ETL; propose `Unknown` for null | BQ08, K30, K05 segment | Documented main ETL extension, verify deployment |
| `fact_payment_intent` | `checkout_channel` | Checkout entry/channel dimension; source categorical | K32 | Documented source/processed |
| `fact_payment_intent` | `amount_major` | Requested amount converted from local integer minor units using `dim_currency.minor_units` | Checkout requested volume diagnostics | Documented preprocessing |
| `fact_payment_intent` | `captured_settlement_major` | Captured merchant principal expressed in local major units | K02, local reconciliation bridge | Documented preprocessing |
| `fact_payment_intent` | `amount_major_usd` | Requested amount in USD using FX joined on `created_at` UTC date | Requested-value diagnostics | Documented preprocessing; FX gate |
| `fact_payment_intent` | `captured_settlement_major_usd` | Captured principal normalized with FX joined on **created-at date** in visible code, not capture date | K01 only with clearly labeled FX-day convention | Documented preprocessing; needs reporting-policy review |
| `fact_payment_intent` | `time_to_capture` | `captured_at - created_at` in seconds | K33 | Documented preprocessing |
| `fact_payment_intent` | `payment_resolution_time` | `closed_at - created_at` in seconds | Checkout resolution diagnostic | Documented preprocessing |
| `fact_payment_attempt` | `attempt_number`, `payment_method`, `outcome`, `failure_reason`, `started_at`, `finished_at` | Routing sequence, payment method, result and timestamps | K06–K08, K17–K19, K31, K34 | Documented source; live exact outcomes to verify |
| `fact_fee` | `settlement_currency`, `amount_settlement_major`, `amount_settlement_major_usd` | Fee/cost amount localized and normalized at `assessed_at` FX date | K09–K12 | Documented preprocessing; fee_type enum mapping required |
| `fact_refund` | `minutes_to_refund` | `completed_at - requested_at` in minutes | K23 | Documented preprocessing |
| `fact_refund` | `amount_major`, `settlement_debit_major` | Refund requested vs actual successful merchant debit, local major units | K20–K21 | Documented preprocessing; status filter required |
| `fact_refund` | `amount_major_usd`, `settlement_debit_major_usd` | Normalization uses `completed_at` FX and may fall back to `requested_at` FX if missing | K21, finance | Documented preprocessing; mixed event date needs guardrail |
| `fact_dispute` | `minutes_to_resolve` | `resolved_at - opened_at` in minutes | K24 | Documented preprocessing |
| `fact_dispute` | `disputed_amount_major`, `settlement_debit_major` | Disputed principal vs actual merchant debit, local major units | K22, negative payable/impact | Documented preprocessing |
| `fact_dispute` | `disputed_amount_major_usd`, `settlement_debit_major_usd` | Normalization uses `resolved_at` FX; falls back to `opened_at` if missing | K22 / finance | Documented preprocessing; event-date policy review |
| `fact_settlement` | `time_to_scheduled_payout` | `scheduled_at - initiated_at` in **seconds** | Payout planned lead time | Documented preprocessing |
| `fact_settlement` | `payout_completion_time` | `completed_at - initiated_at` in **seconds** | Operations processing duration | Documented preprocessing |
| `fact_settlement` | `schedule_deviation` | Visible code is `scheduled_at - scheduled_at` in seconds: **always 0**, therefore invalid as actual lateness | K26 | **Known calculation defect; do not report** |
| `fact_settlement` | `amount_major`, `amount_major_usd` | Payout amount normalized by completed date with scheduled-date FX fallback | Payout exposure/operations | Documented preprocessing; mixed event date review |
| `fact_merchant_ledger` | `signed_amount_major`, `signed_amount_major_usd` | Local ledger posted signed amount, plus posted-date USD normalization | K27–K29 | Documented preprocessing; `main` reconstructs minor units |
| `dim_gateway` / `dim_merchant` / `dim_customer` | `valid_from`, `valid_to`, `is_current`, `version_number`; corresponding surrogate keys | ETL-observed historical versions; initial version does not recreate true 2021 attributes | Historical segment slicing | Documented main ETL design |
| `dim_date` | `date_key`, `date_utc`, `year`, `month`, `day_of_month`, `week`, `day_of_week`, `is_business_day`, `month_start`, `month_end`, `is_weekend` | UTC date dimension and analytic attributes | All dated KPIs | Documented preprocessing; match actual main DDL |

**Source-derived vs physical names:** The staging and main loaders may rename/cast certain fields or derive extra keys. The table above describes the recorded analytical contract, not a guarantee that every column appears with exactly that name and type in all three layers (`raw`, `stg`, `main`). Confirm against real warehouse metadata before building the Power BI model.

## 3. Required corrections / decisions

| Priority | Problem | Proposed remedy | Verification |
|---|---|---|---|
| **Critical** | `schedule_deviation` always 0 | Compute `CASE WHEN status=completed THEN DATEDIFF_BIG(SECOND,scheduled_at,completed_at) ELSE NULL END`; signed seconds, positive late | A known late payout has positive seconds; early negative; pending null |
| **High** | Capture USD amount currently uses `created_at` FX rather than `captured_at` | Freeze/label the historical preprocessing convention or regenerate capture USD at `captured_at` for event-date TPV; do not silently change published history | Compare stored vs recomputed FX both ways; reconcile by month |
| **High** | Refund/dispute/payout USD can fall back to an **alternate event-date rate** | Decide one canonical value-date per metric and preserve FX missingness instead of quiet fallback for finance metrics; optionally provide both explicit USD-date variants | Null-rate coverage and row-by-row rate_date comparison |
| **High** | SQL CASE without null guard maps unknown buyer country to Cross-border | Validate null/missing country count; either disallow null or add `Unknown` category and update `CHECK` constraints | Null rows are not silently classified cross-border |
| **High** | `fee_type` and status literal values not independently verified | Inventory distinct values before encoding DAX/T-SQL KPI predicates; define a mapping | All values mapped, no unknown business classification |
| **High** | `fact_merchant_ledger` processed major values but accounting expected minor integer | Restore/store exact integer minor units and compare independently to source events by merchant/currency | Variance = 0 minor units, no floating-point rounding |
| **High** | FX historical coverage previously incomplete | Verify missing non-USD date/currency pairs, actual rates, provider provenance and applicable event dates; prohibit incomplete global USD aggregates | K35 = 100% eligible coverage |
| Medium | SCD2 history starts at ETL capture | Avoid asserting genuine historical pricing/account-status changes before first ETL; use event-linked version SKs | No multiple current records; no unresolvable historical FK |
| Medium | Payout schedule is not necessarily contractual merchant SLA | Label K26 'on-schedule fulfillment proxy' rather than a contractual SLA guarantee | Agree actual schedule meaning and deadlines |

## 4. Copy-ready schema and enumeration verification (SQL Server)

```sql
-- 1) What columns are actually available in the deployed MAIN schema?
SELECT TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE,
       NUMERIC_PRECISION, NUMERIC_SCALE, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'main'
ORDER BY TABLE_NAME, ORDINAL_POSITION;

-- 2) Confirm the new market-type field and its domain.
SELECT transaction_market_type, COUNT_BIG(*) AS row_count
FROM main.fact_payment_intent
GROUP BY transaction_market_type;

-- 3) Get exact source enum values before encoding business filters.
SELECT final_outcome, COUNT_BIG(*) AS n
FROM main.fact_payment_intent GROUP BY final_outcome;
SELECT outcome, COUNT_BIG(*) AS n
FROM main.fact_payment_attempt GROUP BY outcome;
SELECT fee_type, COUNT_BIG(*) AS n
FROM main.fact_fee GROUP BY fee_type;
SELECT status, COUNT_BIG(*) AS n
FROM main.fact_refund GROUP BY status;
SELECT status, COUNT_BIG(*) AS n
FROM main.fact_dispute GROUP BY status;
SELECT status, COUNT_BIG(*) AS n
FROM main.fact_settlement GROUP BY status;

-- 4) Catch the zero-by-construction schedule deviation problem.
SELECT COUNT_BIG(*) AS completed_payouts,
       SUM(CASE WHEN completed_at > scheduled_at THEN 1 ELSE 0 END) AS late_by_timestamps,
       SUM(CASE WHEN completed_at > scheduled_at AND schedule_deviation = 0 THEN 1 ELSE 0 END)
           AS suspicious_zero_deviation
FROM main.fact_settlement
WHERE completed_at IS NOT NULL;
```

## 5. Semantic-model recommended columns (NOT new raw generator requirements)

Preferred calculations in the **warehouse semantic layer** rather than Power BI repeated row-by-row DAX:

- `capture_date_key`, `attempt_date_key`, `assessed_date_key`, `requested_date_key`, `completed_date_key`, `resolved_date_key`, `posted_date_key`, as appropriate to the individual grain.
- Reliable warehouse `transaction_market_type` only after the null policy is decided.
- Canonical fee business class (`merchant_processing_revenue`, `processor_cost`, `dispute_fee_revenue`) mapped from actual `fee_type` enum.
- A validated `fx_rate_date_used` plus USD amount per money event, with a missing-rate indicator.
- Merchant/gateway/customer SCD2 surrogate keys correctly resolved to event time.
- A merchant-month activity bridge / aggregation only if query performance requires it; it should not change base transaction grain.

This addendum complements the original `data_dictionary.md`, which was not accessible as a complete source file in this review. It does not overwrite original field-level contracts beyond documented changes and explicitly recommended corrections.
