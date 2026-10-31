# FinPay Global — Data Dictionary and Relationships

**Version:** 2.0 · **Storage:** PostgreSQL / `.csv.gz` · **Convention:** `dim_` descriptive dimensions; `fact_` financial or operational events.

`PK` primary key; `FK` foreign key; `?` nullable; all dates/times are UTC, and monetary integers are denominated in the specified **local minor currency units**. Event IDs are `BIGINT` unless stated.

## Dimension tables

| Table | PK and columns | Grain / semantics |
|---|---|---|
| `dim_currency` | **`currency_code CHAR(3)` PK**, `minor_units SMALLINT`, `currency_name TEXT` | 1 currency; JPY minor_units=0, others=2 |
| `dim_market` | **`country_code CHAR(2)` PK**, `market_name TEXT`, `currency_code CHAR(3)` FK, `timezone TEXT` | 1 merchant domicile market; Iran is special sandbox-only USD market |
| `dim_gateway` | **`gateway_id SMALLINT` PK**, `gateway_name TEXT`, `home_region TEXT`, `is_enabled BOOLEAN` | 1 fictional gateway partner |
| `dim_merchant` | **`merchant_id BIGINT` PK**, `merchant_name TEXT`, `country_code CHAR(2)` FK, `industry TEXT`, `onboarded_at TIMESTAMPTZ`, `settlement_currency CHAR(3)` FK, `pricing_tier TEXT`, `payout_frequency TEXT`, `account_status TEXT` | 1 merchant account; industry is retail/electronics/travel/subscriptions/food/services |
| `dim_customer` | **`customer_id BIGINT` PK**, `signed_up_at TIMESTAMPTZ`, `country_code CHAR(2)` FK, `acquisition_channel TEXT`, `is_verified BOOLEAN` | 1 registered fictional buyer; no names/emails |
| `dim_date` | **`date_key INTEGER` PK** (`YYYYMMDD`), `date_utc DATE` UNIQUE, `year SMALLINT`, `month SMALLINT`, `year_month CHAR(7)`, `day_of_week SMALLINT`, `is_weekend BOOLEAN` | 1 calendar date over 60-month span |

## Operational event facts

### `fact_payment_intent` — one checkout

| Column | Type | Rule |
|---|---|---|
| `intent_id` | BIGINT | **PK**, one per checkout |
| `merchant_id` | BIGINT | **FK** `dim_merchant`, required |
| `customer_id` | BIGINT? | **FK** `dim_customer`; NULL means guest |
| `order_reference` | TEXT | Unique merchant order identifier (synthetic) |
| `created_at` | TIMESTAMPTZ | Checkout start UTC; >= merchant onboarding |
| `buyer_country` | CHAR(2) | **FK** `dim_market`, may differ from merchant domicile |
| `checkout_channel` | TEXT | web, mobile_web, app |
| `presentment_currency` | CHAR(3) | **FK** `dim_currency` |
| `amount_minor` | BIGINT | Positive requested presentment amount |
| `final_outcome` | TEXT | succeeded, failed, abandoned, pending |
| `closed_at` | TIMESTAMPTZ? | NULL for pending |
| `captured_at` | TIMESTAMPTZ? | Required exactly when succeeded |
| `captured_settlement_minor` | BIGINT? | Equals `amount_minor` on success in local-currency-only v2 |

### `fact_payment_attempt` — one payment request/retry

| Column | Type | Rule |
|---|---|---|
| `attempt_id` | BIGINT | **PK** |
| `intent_id` | BIGINT | **FK** payment intent |
| `gateway_id` | SMALLINT | **FK** `dim_gateway` |
| `attempt_number` | SMALLINT | 1, 2, 3; UNIQUE (`intent_id`, `attempt_number`) |
| `started_at` | TIMESTAMPTZ | Attempt sent at or after checkout creation |
| `finished_at` | TIMESTAMPTZ? | NULL for pending |
| `payment_method` | TEXT | card / wallet / bank_debit |
| `outcome` | TEXT | succeeded / failed / pending |
| `failure_reason` | TEXT? | Required for failed outcomes only |
| `latency_ms` | INTEGER? | Positive for finished attempts; NULL pending |

### `fact_fee` — one assessed merchant fee or processor cost

| Column | Type | Rule |
|---|---|---|
| `fee_id` | BIGINT | **PK** |
| `intent_id` | BIGINT | **FK** successful intent |
| `dispute_id` | BIGINT? | **FK** dispute only for dispute_fee |
| `assessed_at` | TIMESTAMPTZ | Fee event time |
| `fee_type` | TEXT | merchant_fee, processor_cost, dispute_fee |
| `amount_settlement_minor` | BIGINT | Nonnegative assessed local-currency amount; processor costs are off-ledger |

### `fact_refund` — one full or partial refund request

| Column | Type | Rule |
|---|---|---|
| `refund_id` | BIGINT | **PK** |
| `intent_id` | BIGINT | **FK** captured intent |
| `requested_at` | TIMESTAMPTZ | After capture |
| `completed_at` | TIMESTAMPTZ? | NULL if pending |
| `status` | TEXT | succeeded, failed, pending |
| `reason` | TEXT | customer_request / product_return / service_issue / duplicate |
| `amount_minor` | BIGINT | Positive requested local currency amount |
| `settlement_debit_minor` | BIGINT? | Populated on successful refund only |

### `fact_dispute` — one cardholder dispute

| Column | Type | Rule |
|---|---|---|
| `dispute_id` | BIGINT | **PK** |
| `intent_id` | BIGINT | UNIQUE, **FK** captured card intent |
| `opened_at` | TIMESTAMPTZ | 10–90 days after captured transaction in simulation |
| `resolved_at` | TIMESTAMPTZ? | NULL for open |
| `status` | TEXT | open, won, lost |
| `reason` | TEXT | fraud, product_not_received, unrecognized, duplicate |
| `disputed_amount_minor` | BIGINT | Positive, at most captured payment |
| `settlement_debit_minor` | BIGINT? | Filled for lost disputes |

### `fact_settlement` — one payout instruction

| Column | Type | Rule |
|---|---|---|
| `settlement_id` | BIGINT | **PK** |
| `merchant_id` | BIGINT | **FK** merchant |
| `currency_code` | CHAR(3) | **FK** currency, merchant's settlement currency |
| `initiated_at` | TIMESTAMPTZ | Payout sent |
| `scheduled_at` | TIMESTAMPTZ | Merchant payout SLA date |
| `completed_at` | TIMESTAMPTZ? | Present for completed status only |
| `status` | TEXT | completed, pending, failed |
| `amount_minor` | BIGINT | Positive local-currency amount |
| `failure_reason` | TEXT? | Required on failed instruction |

### `fact_merchant_ledger` — one immutable balance posting

| Column | Type | Rule |
|---|---|---|
| `entry_id` | BIGINT | **PK** |
| `merchant_id` | BIGINT | **FK** merchant |
| `currency_code` | CHAR(3) | **FK** currency; must equal merchant settlement currency |
| `posted_at` | TIMESTAMPTZ | Effective posting time |
| `event_type` | TEXT | capture_credit, merchant_fee_debit, refund_debit, dispute_debit, dispute_fee_debit, payout_debit |
| `source_id` | BIGINT | Event identifier interpreted by `event_type`: intent, fee, refund, dispute, fee, settlement |
| `signed_amount_minor` | BIGINT | Positive credit, negative debit; no zero amounts |

## Market FX reference fact

### `fact_fx_rate` — currency × date

| Column | Type | Rule |
|---|---|---|
| `rate_date` | DATE | Composite **PK**, report-effective UTC day |
| `currency_code` | CHAR(3) | Composite **PK**, **FK** currency |
| `usd_per_major_unit` | NUMERIC(24,12) | Positive USD value of one major currency unit (source data; **not hypothetical**) |
| `observation_date` | DATE | Actual source observation date; <= `rate_date` |
| `provider` | TEXT | `identity` for USD or `frankfurter_v2_central_bank_blend` |
| `rate_status` | TEXT | identity, observed or carried_forward |

**Important:** The generated FX file initially includes **only 1,826 USD identity rows**. All other 9×1,826 FX rows require an online historical-rate import. Do not render global USD KPIs before the import completes. Avoid mixing ECB and CBR rates without recording provenance. A last-published reference rate carried forward to weekend/holiday is not an actual observation on that day.

## Analytics star schema

Use separate fact tables as shown above; join facts to `dim_merchant`, `dim_customer`, `dim_gateway`, `dim_market`, `dim_date`, and `dim_currency` through an explicitly selected role-playing date / currency. **Avoid many-to-many fact-to-fact joins.** For Power BI, create a thin capture fact with the successful attempt's method and gateway joined one-to-one; aggregate fee/ledger/refund facts separately. Each SQL staging view should have one unique row per stated fact grain.
