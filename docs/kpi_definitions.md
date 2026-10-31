# FinPay Global — KPI Contract

**Version:** 2.0 · **Owner:** Business Intelligence · **Snapshot:** 2026-10-01T00:00:00Z · **Reporting timezone:** UTC · **Reporting currency:** USD, **ONLY after real FX coverage is loaded**

## Conventions

- Ratio denominators of zero return `NULL`/Power BI `BLANK()`.
- Payment counts at **intent** grain unless a KPI explicitly says **attempt** grain.
- `fact_payment_intent.created_at` is checkout cohort date; captured TPV uses the successful capture `captured_at`; attempt KPIs use `fact_payment_attempt.finished_at`.
- Currency amounts are integer *minor* units. Divide by `10^dim_currency.minor_units` before multiplying the historical `fact_fx_rate.usd_per_major_unit` for the **metric event date**.
- Cross-currency totals are **not defined** if any required non-USD FX rates are missing. Never silently treat them as 1.
- Monthly and yearly comparisons use the same date basis and amount grain.

## Executive & payments KPIs

| KPI ID | Metric | Formula | Primary grain | Date / denominator / notes |
|---|---|---|---|---|
| K01 | Gross TPV USD | `SUM(captured_amount_minor / 10^minor_units * usd_per_major_unit[capture_date, ccy])` | Successful intent | Capture date; gross before refunds or disputes; FX required |
| K02 | Successful captured payments | `COUNT(intents WHERE final_outcome='succeeded')` | Intent | Capture event date |
| K03 | Average Order Value USD | `K01 / K02` | Intent | Matched capture cohort |
| K04 | Intent conversion | `succeeded intents / (succeeded + failed + abandoned intents)` | Intent | Intent creation cohort, exclude pending |
| K05 | Attempt success | `successful attempts / (successful + failed attempts)` | Attempt | Attempt finish date; exclude pending |
| K06 | Gateway failure | `failed attempts / (failed + successful attempts)` | Attempt | Filter gateway and attempt date |
| K07 | Checkout abandonment | `abandoned intents / resolved intents` | Intent | Intent creation date |
| K08 | Retry recovery rate | `intents succeeding on attempt 2 or 3 / intents with failed attempt 1 and >= 1 retry` | Intent after attempt join | If no retries, NULL |
| K09 | P95 processing latency | `PERCENTILE_CONT(.95) WITHIN GROUP (ORDER BY latency_ms)` | Finished attempt | Never sum/average p95 across groups |
| K10 | Wallet share of TPV | `captured wallet TPV USD / all captured TPV USD` | Successful intent joined to its successful attempt | Measure **value**, not attempts |

## Commercial & finance KPIs

| KPI ID | Metric | Formula | Primary grain | Notes |
|---|---|---|---|---|
| K11 | Merchant fee revenue USD | USD value of `fact_fee` where `fee_type='merchant_fee'` | Fee entry | Source assessed date; not TPV |
| K12 | Dispute fee revenue USD | USD value of `fact_fee` where `fee_type='dispute_fee'` | Fee entry | Only assessed on lost disputes in simulation |
| K13 | Processor cost USD | USD value of `fact_fee` where `fee_type='processor_cost'` | Fee entry | Platform cost, not ledger debit |
| K14 | Processing contribution USD | `K11 + K12 − K13` | Aggregated fee entries | Excludes overhead, tax, bank charges |
| K15 | Contribution margin | `K14 / (K11 + K12)` | Aggregated fee entries | Not net profit |
| K16 | Effective take rate | `merchant fee revenue / gross TPV` | Cohort of successful payments | Align FX valuation and cohort before division |
| K17 | Monthly active merchants | Distinct `merchant_id` with >=1 successful capture in month | Merchant × month | Capture month |
| K18 | Merchant monthly retention | Active in month t and t−1 / active in month t−1 | Merchant × month | Excludes merchants without prior-month activity |
| K19 | Top-10 merchant TPV concentration | TPV of ten highest-TPV merchants / total TPV | Merchant × period | Use USD only after FX completion |

## Risk, refunds and settlements

| KPI ID | Metric | Formula | Primary grain | Notes |
|---|---|---|---|---|
| K20 | Refund incidence (45-day mature) | Captured intents with >=1 successful refund / all captured intents | Capture cohort | Only capture cohorts <= snapshot −45 days |
| K21 | Refund value rate (45-day mature) | Successful refunded presentment value converted at **original capture rate** / original captured TPV of same cohort | Capture cohort | Do not compare a month's refunds with that month's new sales |
| K22 | Dispute incidence (90-day mature) | Captured intents with dispute opened / captured intents | Capture cohort | Only capture cohorts <= snapshot −90 days |
| K23 | Lost disputed principal | Sum `dispute_debit` ledger entries converted at posting-date FX | Ledger | Distinct from dispute case count |
| K24 | Net retained captured value | `captured gross − successful refunds − lost dispute principal` | Matched currency-aware events | This is a cash-flow proxy, not merchant revenue |
| K25 | Settlement on-time | Completed payouts with `completed_at<=scheduled_at` / completed payouts due in chosen period | Settlement | Separately count pending overdue instructions |
| K26 | Overdue pending payouts | `COUNT(status='pending' AND scheduled_at<as_of)` | Settlement | Point-in-time, not a historical throughput rate |
| K27 | Closing merchant payable | `SUM(fact_merchant_ledger.signed_amount_minor)` | Merchant + currency + as-of | **Never** sum different currencies unconverted |
| K28 | Reconciliation residual | `Ledger closing payable − (captured gross − merchant fees − refunds − lost disputes − dispute fees − completed payouts)` | Merchant + currency + as-of | Must equal zero in integer minor units |

## Finance reconciliation (mandatory)

`closing merchant payable = sum(capture_credit) - sum(merchant_fee_debit magnitude) - sum(refund_debit magnitude) - sum(dispute_debit magnitude) - sum(dispute_fee_debit magnitude) - sum(payout_debit magnitude)`.

Processor costs **do not** debit merchant payable. A lost dispute principal should be posted **once**, after resolution. Pending or failed payouts have zero subledger impact. Reconciliation must be exact in minor units **per merchant and currency**; round each event first, not a cross-currency grand total.

## Semantic layer rules

- Dimensional joins are many-to-one (facts → dimensions), with a single-direction filter from dimensions to facts.
- DAX fact metrics are scoped to their own grain. Do not physically join fee entries onto payment intents before summing captured amounts.
- For captured wallet share, select only the successful attempt per intent.
- FX joins have composite keys (`date`, `currency_code`). Model as a factless lookup / bridge or pretranslate in SQL by event date and currency.
- For unobserved FX, `NULL` USD values are mandatory, with a visible data-quality warning rather than fabricated results.
