# FinPay Global — Canonical KPI Definitions (v3.0)

**Owner:** Data Analytics + Finance + Payment Operations  
**Updated:** 2026-11-04  
**Status:** Business-approved *proposed measurement contract*; exact SQL Server column names, enumeration values and FX completeness require live verification. This is not a declaration that all queries have been executed.  
**Companion:** [core_business_questions.md](core_business_questions.md) for questions, owners and Power BI report pages.

## 1. Non-negotiable measurement conventions

### 1.1 Business grains and identifiers

| Business object | Table | One row represents | Count key |
|---|---|---|---|
| Checkout / payment | `main.fact_payment_intent` | One initiated checkout, whether attempted or abandoned | `intent_id` |
| Gateway request | `main.fact_payment_attempt` | One attempted payment, including retry | `attempt_id` |
| Financial assessment | `main.fact_fee` | One fee or processor-cost posting | `fee_id` |
| Refund | `main.fact_refund` | One refund request, whether approved/completed or failed/pending | `refund_id` |
| Dispute | `main.fact_dispute` | One case, possibly still open | `dispute_id` |
| Merchant payout | `main.fact_settlement` | One payout instruction, regardless of its execution status | `settlement_id` |
| Merchant balance posting | `main.fact_merchant_ledger` | One positive/negative local-currency ledger event | `entry_id` |
| Currency observation | `main.fact_fx_rate` | One UTC date × local currency | (`rate_date`, `currency_code`) |

Maintain distinct row counts, preferably from separate fact tables or grain-safe SQL aggregations. A flat join from intents to attempts AND fees/refunds/ledger multiplies rows and produces false denominators and sums.

### 1.2 Financial, temporal and filtering rules

- **Date boundary:** all reporting timestamps UTC, inclusive `2021-10-01T00:00:00Z` and exclusive `2026-10-01T00:00:00Z` for the present fixed snapshot. Declare the date role for every measure (created, started, captured, assessed, requested, resolved, scheduled, completed, posted).
- **Statuses:** define canonical business status mapping from the actual staging/warehouse enum domains before implementing measures. Below, `succeeded`, `failed`, `pending`, `abandoned`, `completed`, `open`, `won`, `lost` are *logical categories* rather than guarantees of exact text values.
- **Money:** store exact source amounts in local currency minor units for ledger/reconciliation. Convert to local major with `amount_minor / POWER(10, dim_currency.minor_units)` using decimal arithmetic. `JPY` may use 0 minor digits; never assume divide by 100 for every currency.
- **FX:** `local_major × fact_fx_rate.usd_per_major_unit` at the approved fact-specific reporting date; no missing-rate replacement with 1 (except real USD identity). Present rates as non-tradable historic reference rates. USD sums are **blocked/flagged** whenever relevant non-USD observation coverage is incomplete.
- **Event-date standard for new metrics:** capture volume by `captured_at`; fee accounting by `assessed_at`; refund cash impact by `completed_at`; dispute cash impact by `resolved_at`; payout cash impact by `completed_at`; ledger balance by `posted_at`. The older preprocessing uses a mixed FX-date policy (for intent USD values, `created_at`); existing stored USD columns must not silently be relabeled as capture-date-FX metrics. See addendum.
- **Cohorts vs booked events:** an event-time report is not the same as a capture-cohort report. For take rates, loss incidence, gateway outcomes and comparisons, use a common captured/created cohort where specified, or present a clearly named separately booked-event measure.
- **Maturity:** report refund/dispute rates over capture cohorts old enough to have a meaningful observation period. Define a configurable *illustrative* 90-day maturity cutoff, then test 30/60/120/180-day sensitivities; no claim that 90 days equals a network-rule window. Exclude immature cohorts and label the choice.
- **SCD2 slicing:** connect fact foreign keys to the appropriate `merchant_sk`/`gateway_sk`/`customer_sk` row by fact event time where available. `valid_from`/`valid_to` are ETL observations, not true original history.
- **Zero denominator:** return blank / `NULL`, never 0% when denominator is 0. Use weighted global ratios (`SUM(num)/SUM(den)`), never the average of merchant percentages unless specifically labeled unweighted merchant mean.

## 2. CEO volume and checkout success

| ID / KPI | Canonical formula and denominator | Recommended date / scope | Source |
|---|---|---|---|
| **K01 Captured TPV (USD)** | `SUM(captured_settlement_major × valid USD FX)` for unique succeeded/captured intents; don't include requested volume, repeats, fees or payouts | `captured_at`, eligible successful intents; USD publication FX-gated | Intent + FX + currency |
| **K02 Captured TPV (local)** | `SUM(captured_settlement_major)` **separately by currency**, never sum EUR/JPY/USD into an unlabeled total | `captured_at`; local-currency fact | Intent + currency |
| **K03 TPV growth %** | `(TPV_current - TPV_comparable_prior) / TPV_comparable_prior × 100`, like-for-like period and identical currency/FX rules | Month-over-month or year-over-year, not a mixture | K01 or K02 |
| **K04 Average captured ticket (USD)** | `K01 / distinct count of successfully captured intents with valid FX` | `captured_at`; all eligible captured intents | Intent + FX |
| **K05 Checkout success / intent conversion %** | `COUNTDISTINCT(successful captured intent_id) / COUNTDISTINCT(created intent_id) × 100`; include abandoned and failed checkouts in denominator, keep pending visible separately | `created_at` cohort, outcomes observed by cutoff; don't equate to auth rate | Intent |
| **K06 Attempt success %** | `COUNT(successful terminal attempt_id) / COUNT(all terminal attempt_id) × 100`; report pending attempt count separately | `started_at`, attempt grain, all gateway requests including retries | Attempt |
| **K07 First-attempt success %** | `COUNT(successful attempt_number=1) / COUNT(terminal attempt_number=1) × 100` | First-attempt cohort (`started_at`) | Attempt |
| **K08 Retry rescue %** | `COUNT(intents with failed first attempt AND later successful attempt) / COUNT(intents with failed first attempt AND known resolved outcome) × 100` | Original first-attempt date, with observed completed retry sequence | Attempt→Intent |

**Important:** A captured payment is not merely an authorized card transaction; this dataset does not record a full issuer/network authorization state machine. K06 is an observed **gateway-attempt success rate**, not necessarily the card-network authorization rate. Distinguish gross attempt rate and net checkout success. [Adyen: authorization vs conversion](https://help.adyen.com/en_US/knowledge/payment-methods/manage-payment-methods/what-is-the-difference-between-authorization-and-conversion-rates), [Adyen: gross vs net measurement](https://www.adyen.com/en_GB/knowledge-hub/payment-acceptance-rate).

## 3. PSP monetization and unit economics

Before implementing K09–K12, map `fact_fee.fee_type` **actual source values** to three business classifications: `merchant_processing_revenue`, `processor_cost`, and `dispute_fee_revenue`. All source event amounts are nonnegative financial magnitudes; class determines business sign. This mapping is a QA prerequisite, not an assumption about literal enum spelling.

| ID / KPI | Canonical formula | Recommended date / scope | Source |
|---|---|---|---|
| **K09 Earned merchant fees (USD)** | `SUM(merchant processing fee revenue) + SUM(assessed dispute fee revenue)`; never add processor costs as revenue | `assessed_at`, fee-booked period; provide component breakdown | Fee + intent→merchant + FX |
| **K10 Processor expense (USD)** | `SUM(processor-cost assessments)` as positive expense | `assessed_at` (accounting) or captured-intent cohort (unit economics) | Fee + FX |
| **K11 Processing contribution (USD)** | `SUM(merchant processing fees) − SUM(processor costs)`; **excludes** dispute-fee income and all general overhead | Fee-accounting period for booked view; separately same-capture-cohort comparison with K01 | Fee + FX |
| **K12 Processing fee take rate %** | `merchant processing fees attributable to captured payments / captured TPV × 100`; use **same capture cohort** numerator and denominator, not mixed fee-assessed and capture months | `captured_at` cohort, FX-gated | Fee→Intent + FX |

**Supporting derivations:** `processing contribution margin % = K11 / merchant processing fee revenue × 100` (same booked period); `processing contribution per capture = K11 / captured count` for a same-event-cohort version; `processor expense / captured TPV` for a capture-cohort cost ratio. These are **transaction processing economics**, not full PSP gross profit, EBIT, net income or cash flow. `fact_settlement` is merchant-principal cash movement, not a PSP operating expense. A merchant-principal loss on a lost dispute is *debited to the merchant* in the modeled subledger; it is not by itself a realized PSP fraud-loss expense.

## 4. Merchant portfolio, pricing tiers and concentration

| ID / KPI | Canonical formula | Recommended date / scope | Source |
|---|---|---|---|
| **K13 Monthly active merchants** | `COUNTDISTINCT(merchant_id)` with ≥1 successfully captured intent during month | `captured_at` month; never count every merchant SCD2 version as a distinct merchant | Intent + merchant |
| **K14 Active-merchant retention %** | `# merchants captured in month M−1 AND M / # merchants captured in M−1 × 100` | Calendar months; merchant IDs rather than SCD2 rows | K13 merchant-month bridge |
| **K15 New merchant 30-day activation %** | `# merchants with first successful capture within 30 days after onboarded_at / # merchants onboarded in eligible cohort × 100` | `onboarded_at` month; exclude late cohort without 30 days of observation | Merchant + intent |
| **K16 Top-10 merchant TPV share %** | `captured TPV of top 10 merchants / all captured TPV × 100`; rank by same currency-normalized valid-FX window | `captured_at` and valid FX; if missing FX, calculate per currency instead | Intent + FX |

Retained active merchants are not the same as retained *revenue*. CAC, gross-revenue retention and contractual NRR cannot be claimed from this dataset without sales cost or contracted recurring-revenue data. Merchant onboard date is known, but older SCD2 version-1 dimensions do not prove the actual attributes for pre-first-ETL dates.

## 5. Methods, gateways, routing and latency

| ID / KPI | Canonical formula | Recommended date / scope | Source |
|---|---|---|---|
| **K17 Captured payment-method mix %** | `captured TPV from succeeded intents attributed to their **successful attempt's** method / total captured TPV × 100`; optional count-share variant, clearly labeled | `captured_at`; use unique successful attempt→intent mapping and FX gate for value | Intent + attempt + FX |
| **K18 Gateway failure rate %** | `failed terminal attempts for gateway / all terminal attempts for gateway × 100`; segment by `failure_reason`, method and attempt number | `started_at` and attempt grain | Attempt + gateway |
| **K19 Gateway attempt latency P95** | 95th percentile of `finished_at − started_at` among terminal attempts, in milliseconds/seconds; distinguish successful vs failed and gateway | `started_at`; exclude negative/null durations | Attempt |
| **K31 Retry attempts per initiated attempt chain** | `# attempts with attempt_number > 1 / # intents with first attempt`; count-weighted, not a customer-level rate | `started_at` cohort with final retries observed | Attempt |
| **K32 Checkout-channel success %** | Apply K05 separately by `checkout_channel` | `created_at`, same cohort and pending policy as K05 | Intent |
| **K33 Time-to-capture P50/P95** | Percentiles of `captured_at − created_at` over successfully captured intents; exclude missing/negative durations | Successful intent creation/capture as explicitly selected | Intent |
| **K34 Gateway failure anomaly** | Daily actual K18 minus a documented rolling baseline, or day-level failure count above a control threshold with minimum exposure | `started_at` UTC day, gateway × method | Attempt |

**Attribution trap:** Do not attribute the final succeeded checkout to every gateway that handled its earlier failed retries. For gateway conversion at intent grain, choose and label a **first-attempt gateway** or **final-successful gateway** attribution view; gateway K18 remains the unambiguous attempt-level comparison. K34 is an *outage-like proxy*, not true gateway uptime or SLA compliance without gateway availability logs.

## 6. Refund, dispute and servicing measures

| ID / KPI | Canonical formula | Cohort and conditions | Source |
|---|---|---|---|
| **K20 Mature captured-payment refund incidence %** | `# distinct captured intents with ≥1 successfully completed refund / # eligible captured intents × 100` | Capture cohorts old enough for chosen maturity window; not by refund month | Intent + refund |
| **K21 Refund amount ratio %** | `SUM(successful settlement_debit of refunds) / SUM(captured principal)` in same captured cohort and comparable currency/FX basis | Mature capture cohort, include partial refunds; avoid dividing by refund-request amount | Refund + intent + FX |
| **K22 Mature card-dispute incidence %** | `# card-captured intents with dispute opened / # eligible captured card intents × 100` | Mature capture cohorts; card-only denominator; internal cohort metric, **not a network-certified dispute ratio** | Dispute + attempt + intent |
| **K23 Refund handling time P50/P95** | Percentiles of `completed_at − requested_at` in minutes, **completed refunds only** | `completed_at` or request cohort, clearly label | Refund |
| **K24 Dispute resolution time P50/P95** | Percentiles of `resolved_at − opened_at` in minutes/days for `won` or `lost` cases | Resolved cases only, recent open cases separately | Dispute |
| **K37 Dispute win rate %** | `# resolved dispute cases status=won / # resolved dispute cases (won or lost) × 100` | Resolved case cohort, not all opened cases | Dispute |

**Different clocks:** For a service-team workload chart, count disputes by `opened_at` and refunds by `requested_at`. For recognized ledger cash impact, use refund `completed_at` and lost-dispute `resolved_at`. For comparably aged underlying payment quality, cohort by captured payment date. Data rules here allow up to one dispute per captured card intent and make successful refund vs dispute mutually exclusive—a **synthetic-model restriction**, not a universal PSP rule. Neither reported refund incidence nor dispute incidence proves fraudulent activity.

## 7. Merchant settlements, payable and financial integrity

| ID / KPI | Canonical formula | Date / special rules | Source |
|---|---|---|---|
| **K25 Payout completion rate %** | `# initiated payout instructions completed by reporting cutoff / # all payout instructions in eligible initiated cohort × 100` | `initiated_at`; consider age/maturation to prevent recent-pending bias | Settlement |
| **K26 Payout on-schedule fulfillment %** | `# payout instructions due by cutoff, status completed AND completed_at <= scheduled_at / # payout instructions due by cutoff × 100` | `scheduled_at ≤ cutoff`; pending/failed due counts as not on time; policy target is a proxy for SLA | Settlement |
| **K27 Ledger reconciliation variance (minor units)** | Per `(merchant_id,currency_code,cutoff)` `expected financial postings from source events − SUM(ledger.signed_amount_minor)`; **required exact 0** | Postings effective by cutoff; no mixing currencies or premature events | Intent + fees + refund + dispute + settlement + ledger |
| **K28 Closing merchant payable** | `SUM(ledger.signed_amount_minor)` up to cutoff by **merchant & currency**; show local major via currency precision | `posted_at ≤ cutoff`, as-of stock, not a monthly flow | Ledger + currency |
| **K29 Negative merchant-payable exposure** | `SUM(ABS(MIN(closing payable_minor,0)))` over merchant-currency balances; display by currency or convert as-of using separately specified FX | As-of cutoff, exact local first; not automatically recognized PSP loss | K28 |

**Data defect to correct before using stored schedule deviation:** the reviewed preprocessing computes `scheduled_at − scheduled_at`, identically zero. The correct signed actual deviation for completed payouts is `completed_at − scheduled_at` (positive = late). The K26 definition is based directly on timestamps and remains valid if populated fields are correct; **do not use the old `schedule_deviation` column**. `payout_completion_time = completed_at − initiated_at` is distinct from lateness; `time_to_scheduled_payout = scheduled_at − initiated_at` is the planned lead time. Currency-exact reconciliation requires converting the processed major-unit ledger to integer minor units without rounding ambiguity.

## 8. Domestic / Cross-border and customer segments

| ID / KPI | Canonical formula | Scope / limitation | Source |
|---|---|---|---|
| **K30 Cross-border captured TPV share %** | `cross-border captured TPV / total captured TPV × 100`; alternatively captured-intent count share, labeled separately | `transaction_market_type='Cross-border'` built from buyer vs merchant country; USD FX required for global value | Intent + merchant + FX |
| **K36 Acquired-customer channel contribution** | `distinct registered customers with first successful captured intent, grouped by dim_customer.acquisition_channel` | Customer with `customer_id` only; keep guests separate; not paid marketing ROI | Customer + intent |

A Domestic/Cross-border label is **not a pricing, fee or currency-conversion indicator** in this simulation. Payment presentment equals merchant settlement currency; no real-time transaction FX conversion, cross-border interchange or FX-spread revenue is modeled. Segment differences in rate or contribution do not establish causal effect of border status.

## 9. Data quality and publication controls

| ID / KPI | Canonical formula | Acceptance / scope | Source |
|---|---|---|---|
| **K35 Historical FX usable-row coverage %** | `# eligible monetary rows with validated USD FX at required fact date / # eligible monetary rows requiring FX × 100`; also coverage by date × currency | **100% required** for unrestricted global USD finance publication; for incomplete subsets show scoped provisional report only | All monetary facts + FX |

**Other non-scorecard release tests:** zero orphan IDs and duplicate grain; exactly one successful attempt per succeeded intent; no attempts after success; allowed status/timestamp order; no completed payout without completed timestamp; no negative/zero FX rates; one FX row per date-currency; zero reconciliation mismatch by merchant-currency; correct `transaction_market_type` derivation including explicit null policy; no negative time differences; no `schedule_deviation` all-zero artifact after fix; source/warehouse row-count and SCD2 version health; no duplicated financial measures after joining multi-fact tables.
