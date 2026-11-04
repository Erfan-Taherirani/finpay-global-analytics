# FinPay — SQL Server Staging/ETL Documentation Addendum (v3.0)

**Date:** 2026-11-04  
**Applies to:** `finpay_sql_server_staging_etl_documentation.md` (2026-11-03 edition). The architecture, 14 source tables, full-staging snapshots and SCD2 design are retained.

## 1. New business attribute: `transaction_market_type`

The previous `fact_payment_intent` loader addition derives this field by comparing the buyer country with merchant domicile. Treat this as an **intent-grain derived attribute** from `stg.fact_payment_intent.buyer_country` plus the correct merchant lookup. The prior implementation:

```sql
CASE WHEN s.buyer_country = m.country_code
     THEN 'Domestic' ELSE 'Cross-border' END
```

maps `NULL` buyer or merchant country to Cross-border. Before production BI, either guarantee both source country codes are non-null or add a third `Unknown` value consistently in the DDL check, ETL and semantic layer. Confirm result counts and source-country mapping independently.

## 2. Date roles, FX convention and derived amount fields

| Monetary fact / amount | Observed preprocessing date used for USD | Recommended canonical event basis for reporting |
|---|---|---|
| Intent requested amount | `created_at` | `created_at` |
| Intent **captured** principal | **`created_at`** | Prefer `captured_at` for captured-TPV flow; existing stored result must be labeled/migrated |
| Fee and processor cost | `assessed_at` | `assessed_at`; optionally captured-intent cohort for unit economics |
| Refund requested principal / settlement debit | `completed_at`, fallback `requested_at` | `requested_at` for requested; `completed_at` for actual successful debit; no hidden fallback |
| Dispute disputed principal / settlement debit | `resolved_at`, fallback `opened_at` | `opened_at` for disputed case amount; `resolved_at` for lost cash impact; no hidden fallback |
| Payout amount | `completed_at`, fallback `scheduled_at` | `completed_at` for completed merchant payable debit; `scheduled_at` for due instructions; no hidden fallback |
| Merchant ledger signed posting | `posted_at` | `posted_at` for historical flows; as-of stock uses cutoff |

The *recommended* convention is not described as deployed. All finance metrics must store/report `fx_rate_date_used`, or be reproducible from the event timestamp and FX source; missing required FX remains null and gates publication. Keep local minor-unit originals for exact accounting.

## 3. Required correction to payout schedule deviation

The reviewed Polars source used:

```python
(pl.col('scheduled_at') - pl.col('scheduled_at')).dt.total_seconds().alias('schedule_deviation')
```

This is zero by construction. Proposed corrected SQL Server derivation (adapt table/column types to the actual warehouse):

```sql
CASE
    WHEN status = 'completed' AND completed_at IS NOT NULL
    THEN DATEDIFF_BIG(SECOND, scheduled_at, completed_at)
    ELSE NULL
END AS schedule_deviation_seconds
```

Use `scheduled_at` as the **scheduled fulfillment target**, not proof of a contractual SLA. Keep `payout_completion_time` (`completed_at - initiated_at`) and `time_to_scheduled_payout` (`scheduled_at - initiated_at`) separate. A late completed payout has positive deviation; an early one negative; unresolved instructions have null *actual* deviation and can still count as overdue in a separately computed metric.

**Release-blocking test:** compare completed payout rows whose `completed_at > scheduled_at` to any stored `schedule_deviation=0`; if any exist, do not publish deviation metrics until corrected.

## 4. Payment and dimension keys

- SCD2 dimensions remain `dim_gateway`, `dim_merchant`, `dim_customer`, using observed ETL UTC validity; `dim_currency`, `dim_market` are stable reference dimensions; `dim_date` is static.
- Fact keys should point to the version relevant to the **fact event date**, while acknowledging unknown history before the first observed SCD2 change. Never join a fact to every historical dimension version by business key.
- When translating merchant attributes for `transaction_market_type`, use a precisely documented country policy; the initial version baseline may differ from a merchant's true past state.
- Keep distinct `intent_id` and `attempt_id` measures, not a denormalized multiplied transaction count.
- Joining fee to merchant (through intent) or dispute to successful attempts must be group-safe. Processor costs remain platform expense, not ledger debit.

## 5. Validation priority order before Power BI connection

1. Source import fidelity: counts, schema, distinct enums and date boundaries (`stg` vs processed CSV).
2. Exact event grain, parent-child integrity and legitimate lifecycle transitions in `main`.
3. Historical SCD2 correctness and fact surrogate-key resolution; no multiple current versions.
4. Exact financial posting reconciliation in reconstructed **integer minor units** for each merchant and currency.
5. FX coverage, positive rate values, date/currency uniqueness, USD precision, and date-role consistency.
6. New market segment population and null policy.
7. Correct payout schedule deviation, including early/late/pending examples.
8. DAX measures tied to independent T-SQL validations at the same filter/context and cohort.

**Do not claim ETL has been run or tested** from this document alone. The existing main ETL notes report designed implementations and caveats, not a verified deployment log.

## 6. Suggested acceptance matrix

| Change | Unit test | Status in this documentation |
|---|---|---|
| Market type | Buyer and merchant country same/different/missing | Documented design; null handling needs decision |
| Captured TPV date role | Capture after creation with non-flat daily FX | Date-role discrepancy identified; fix proposed |
| Fee classification | Distinct source fee types map to allowed business classes | Needs warehouse query |
| SCD2 | Changed/unchanged full snapshots produce expected version counts | Needs connected integration test |
| Refund/dispute lag | Mature capture cohorts vs event-date totals clearly differ | Definition added; test needed |
| Payout deviation | Early/late/on-time/pending outcomes; no zero-by-bug | Defect identified; correction proposed |
| Ledger | Exact amount/sign/reconciliation by local minor units | Invariant preserved; test needed |
| FX | Valid daily source rates across all reported currencies | Needs source and warehouse verification |

**Companion:** [`data_dictionary_addendum.md`](data_dictionary_addendum.md), [`kpi_definitions.md`](kpi_definitions.md).
