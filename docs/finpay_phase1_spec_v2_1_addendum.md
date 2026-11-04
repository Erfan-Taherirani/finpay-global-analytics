# FinPay Global — Phase 1 Data Contract v2.1 (Business-Analytics Addendum)

**Date:** 2026-11-04  
**Applies to:** Original `finpay_phase1_spec.md` v2.0.  
**Change type:** Analytics contract extension/clarification. **Not** a claim that raw data generation, deployed SQL DDL or stored procedures have been re-run.

The original v2.0 dataset scope and synthetic payment lifecycle are **preserved**. Read this as an explicit addendum overriding the indicated analytical interpretation, not an unverified replacement of the original technical specification.

## A. Unchanged global dataset settings

| Field | Contract |
|---|---|
| Dataset | 60 calendar months, 2021-10-01 through 2026-09-30, cutoff 2026-10-01 00:00:00 UTC |
| Scale | 100,000 registered customers plus guests, 2,000 merchants, 1,620,000 checkout intents in the design contract; approx. 8–10M rows total |
| Markets | US, GB, DE, FR, CA, AU, JP, CN, IR, RU, MX, EG |
| Transaction currencies | USD, EUR, GBP, CAD, AUD, JPY, CNY, RUB, MXN, EGP |
| Methods | card, wallet, bank_debit |
| Gateways | Five fictional providers |
| Financial currency | Merchant payments and payouts are in the merchant settlement currency; USD conversions exist for reporting only |
| Financial invariants | Exactly one captured-intent credit, corresponding merchant fee and processor cost; only actual refunds/lost disputes/completed payouts debit merchant payable as documented |
| Sensitive country caveat | Iran is modeled USD-only; no real-world service, regulatory or payment-corridor availability claims |

## B. Technical warehouse contract — supersedes original PostgreSQL implementation narrative

The **current project pipeline** is:

```text
Synthetic raw data -> Python/Polars processing -> data/processed/*.csv
    -> Microsoft SQL Server stg.<table> (full snapshot)
    -> dbo.usp_Load... transactional table-level ETL
    -> Microsoft SQL Server main.<table>
    -> Power BI semantic model -> DAX -> T-SQL reconciliation
```

**14 tables:** six dimensions (`dim_currency`, `dim_market`, `dim_date`, `dim_gateway`, `dim_merchant`, `dim_customer`) and eight facts (`fact_payment_intent`, `fact_payment_attempt`, `fact_fee`, `fact_refund`, `fact_dispute`, `fact_settlement`, `fact_merchant_ledger`, `fact_fx_rate`). The historical `sql/schema.sql` PostgreSQL references in original v2.0 reflect initial design and **do not define current authoritative deployment**.

**SCD behavior:** `dim_currency` and `dim_market` stable reference/Type 1; `dim_date` static; `dim_gateway`, `dim_merchant`, `dim_customer` SCD Type 2 with warehouse surrogate versions and ETL execution-time validity bounds. Facts are not SCD2. Fact versions must be matched without false historical reconstruction.

## C. New analytic segment — applies to intent grain

`main.fact_payment_intent.transaction_market_type` is a **warehouse-derived** market relationship tag:

- `Domestic`: `buyer_country = merchant.country_code`.
- `Cross-border`: valid buyer/merchant country codes differ.
- `Unknown`: recommended for missing country values (prior documented CASE maps null to Cross-border; correct or reject null input before publishing).

This tag is not a measure of foreign-exchange conversion or true acquiring-network cross-border fees. Value-normalized market analytics need verified USD rates, and results should be compared at *intent grain*.

## D. Updated headline business/KPI requirements — replaces v2 §6 reporting summary

The definitive KPI catalog is [`kpi_definitions.md`](kpi_definitions.md), referenced by [`core_business_questions.md`](core_business_questions.md). Mandatory leadership dimensions:

- **Sales throughput:** captured TPV USD/local, growth, average ticket; successful captures only.
- **Acceptance:** observed checkout success at unique-intent grain; gross attempt success at unique-attempt grain; first attempt and retry rescue separately.
- **Economics:** merchant processing revenue, processor cost, processing contribution and capture-cohort take rate; no payout-as-PSP-expense.
- **Merchant health:** monthly captured-active merchants, retention, activation within 30 days and TPV concentration.
- **Operational reliability:** attempt latency/failure pattern by gateway, method, time and Domestic/Cross-border market type.
- **Post-payment:** mature capture-cohort refund/dispute incidence and servicing-resolution times; distinguish open/pending cases.
- **Payout and integrity:** payout scheduled fulfillment, late-payout duration, payable stock, negative payable exposure and **zero** unexplained minor-unit ledger reconciliation variance.
- **Data quality:** event-grain uniqueness, SCD2 mapping, complete historical USD FX coverage and consistent date-role policies.

**Not supported:** PSP full profit/net income, real fraud rate/loss, contractual network dispute ratio, CAC, ROAS or true gateway uptime without supplemental sources.

## E. USD normalization and source-time choice

The verified earlier Python preprocessing calculates `fact_payment_intent.captured_settlement_major_usd` using **FX on `created_at`**, while the revised executive definition of captured TPV is a flow by **`captured_at`**. This is not a rounding nuance: if dates differ and FX changes, capture-date USD TPV differs from the stored amount. The business owner must choose and document the historical USD conversion convention before labeling/reporting TPV. This revision **recommends** capture-date FX for captured TPV; prior stored USD fields must be migrated/validated or clearly labeled created-date translated amounts.

Other recorded mixed-date fallbacks: completed refund → requested refund FX; resolved dispute → opened dispute FX; completed payout → scheduled payout FX. For finance, avoid silent mixed-date translation within one named metric. The canonical event date and missing-rate handling are specified in [`kpi_definitions.md`](kpi_definitions.md) and the dictionary addendum.

**Release gate:** no unrestricted multi-currency USD monetary totals until 100% of required date/currency rates are valid and the source provenance is verified. An earlier export had USD identity but missing non-USD FX; actual later import completion must be checked rather than assumed.

## F. Corrected payout deviation definition

The available preprocessor used `scheduled_at - scheduled_at`; the result cannot indicate lateness. **Required semantic rule:** for completed payouts, `schedule_deviation_seconds = completed_at - scheduled_at`. Positive indicates late; negative early; pending/failed should have null *actual completion deviation*. Alternative on-schedule fulfillment should use timestamps directly and all payouts already due as its denominator.

## G. Reconciliation and join safeguards

The exact merchant payable identity at a common cutoff remains:

```text
SUM(local ledger signed minor units) by (merchant_id, currency_code)
  = Captured principal credits
  - Merchant processing fee debits
  - Successful refund principal debits
  - Lost dispute principal debits
  - Lost dispute fee debits
  - Completed payout debits
```

Processor cost is excluded from merchant balance (platform expense). Do not aggregate the payable stock across different currencies without an explicit **as-of** translation method. Duplicate source events, multi-fact fanout, unexpected SCD2 joins, and silent minor-unit rounding must fail validation.

## H. Compatibility/change-management checklist

- Confirm `stg` snapshot columns and row counts against `data/processed` before running ETL.
- Confirm `main.fact_payment_intent.transaction_market_type` is actually deployed and populated correctly.
- Verify precise fee/status values and source timestamps rather than relying on example string labels.
- Test reconciliation on merchant × currency × cutoff; no balancing plugs.
- QA captured-TPV FX dates and the schedule-deviation correction.
- Re-run independent T-SQL checks for all P0 Power BI measures.
- Record whether each improvement is **proposed**, **implemented**, **tested**, or **published**. Documents here record business-contract updates; they do not change runtime pipelines.

**Related docs:** [`business_scenario.md`](business_scenario.md) · [`core_business_questions.md`](core_business_questions.md) · [`kpi_definitions.md`](kpi_definitions.md) · [`data_dictionary_addendum.md`](data_dictionary_addendum.md) · [`finpay_sql_server_etl_addendum.md`](finpay_sql_server_etl_addendum.md).
