# FinPay Global — Core Business Questions (v3.0)

**Owner:** CEO / Head of Analytics / PSP business leads  
**Updated:** 2026-11-04  
**Purpose:** Decision-led requirements for the SQL Server `main` warehouse and Power BI semantic model.  
**Dataset:** Fictional PSP; 60 months (2021-10-01 to 2026-09-30 UTC), 2,000 merchants, 100,000 registered customers plus guests, 12 markets, 10 settlement currencies, five fictional gateways, 14 source tables (six dimensions, eight facts). The 8–10M total-row target is not a guarantee of the deployed snapshot.

## 1. Executive intent and priorities

FinPay is a merchant-facing payment service provider (PSP). Its executive team must optimize **reliable payment completion, profitable processing, merchant growth, post-payment risk, and financial integrity**. Do not mistake merchant principal for PSP revenue; do not treat a gateway retry as another checkout; and do not treat a completed merchant payout as an operating expense.

**Priority codes:** P0 = must-have for first decision-ready release; P1 = important optimization; P2 = diagnostic/deeper investigation.  
**Availability:** A = supported by the documented modeled fields (subject to deployment verification); C = conditional on a data-quality fix, mapping, mature cohort, or complete FX; N = not defensibly measurable from this dataset.

| ID | Priority | Business question leadership should answer | Primary KPIs | Practical decision | Availability |
|---|---|---|---|---|---|
| BQ01 | P0 | How much captured payment volume are we processing, and where is growth coming from? | K01, K02, K03, K04 | Allocate account-management, growth and capacity resources across markets and industries | C: USD FX |
| BQ02 | P0 | How often do checkout attempts turn into successful captured payments? | K05, K06, K07, K08 | Fix shopper friction, route failures and retry strategy separately | A |
| BQ03 | P0 | Which merchants, markets, industries and pricing tiers generate sustainable processing contribution? | K09, K10, K11, K12 | Review pricing, contract renewal, merchant support and gateway cost exposure | C: FX and fee-type mapping |
| BQ04 | P0 | Are merchants activating, retaining and concentrating volume in a healthy way? | K13, K14, K15, K16 | Target onboarding support, retention programs and concentration mitigation | A |
| BQ05 | P0 | Which gateways and payment methods deliver the best reliability and latency? | K06, K17, K18, K19 | Diagnose routing and incident patterns without claiming causal routing uplift | A |
| BQ06 | P0 | Are disputes/refunds eroding our merchants' economics and adding operational work? | K20, K21, K22, K23, K24 | Improve merchant support and high-risk segment investigation | C: mature cohorts |
| BQ07 | P0 | Are merchant payouts timely and are balances exactly reconcilable? | K25, K26, K27, K28, K29 | Escalate missed payouts, reconcile the subledger and protect financial reporting | C: schedule-deviation fix |
| BQ08 | P0 | Do Domestic and Cross-border customer segments behave differently? | K30, K05, K06, K11, K20 | Prioritize segment-specific checkout and acceptance improvements | A; no FX-margin inference |
| BQ09 | P1 | Are retries recovering previously failed checkouts, and at what operational cost? | K07, K08, K31, K18 | Tune retry policy and monitor avoidable gateway cost/latency | A; uplift is observational |
| BQ10 | P1 | How do checkout channel and payment method affect completion and value? | K05, K17, K32 | Identify UX/method coverage opportunities | A; attribution rules required |
| BQ11 | P1 | How quickly do we complete captures, refunds and dispute handling? | K19, K23, K24, K33 | Set realistic service targets and staff support queues | A; exclude open cases from completed-duration distribution |
| BQ12 | P1 | Are revenue or volume changes due to merchants entering, existing merchants growing, or mix shifts? | K02, K13, K14, K15 | Separate acquisition from same-merchant performance | A; SCD2 history limitation |
| BQ13 | P1 | Which markets and gateways show abnormal failure or outage-like spikes? | K06, K18, K34 | Investigate anomalies and review vendor routing | A as incident proxy; not actual gateway uptime |
| BQ14 | P1 | How much merchant payable is outstanding and which merchants have negative balances? | K28, K29 | Resolve receivables and manage payout exposure | A local-currency; C for USD aggregation |
| BQ15 | P1 | How complete and trustworthy are historical USD analytics? | K35, K27 | Block/approve executive publication by currency and event class | A as quality control |
| BQ16 | P2 | Which acquisition channels bring customers who later complete payments? | K36, K05 | Refine channel targeting without asserting CAC/ROAS | A for observed counts; no campaign costs |
| BQ17 | P2 | Are there material differences in processing costs by payment method, gateway and merchant segment? | K10, K11, K18 | Investigate rate-card and routing trade-offs | C; processor-cost attribution through captured intent/attempt must be checked |
| BQ18 | P2 | What proportion of disputed cases do merchants win? | K22, K37 | Improve dispute operations for resolved cases | C: mature resolved cohorts |

## 2. Executive scorecard — first page

Show these headline measures with clear prior-period comparisons and coverage notes:

1. Captured TPV (USD) **only if FX completeness passes**; otherwise currency-specific TPV.
2. Checkout success rate at **intent grain**.
3. Attempt success rate at **attempt grain** (never label as card-network authorization rate).
4. Processing contribution (USD), processing contribution margin and processing fee take rate (FX-gated).
5. Monthly active merchants and merchant retention.
6. Mature-cohort refund incidence and dispute incidence for **captured payments**.
7. Completed payout on-time rate plus completed payout rate.
8. Unexplained merchant-ledger reconciliation variance (must be exactly zero in local minor units).

Add an information strip: data freshness/cutoff, excluded pending payments, maturity window, FX coverage, and currency/conversion convention.

## 3. Recommended Power BI report structure

The goal is not literally one report page for every row above. Organize related questions into **seven decision-focused report pages**, each with drill-through to its BQ IDs. This avoids 18 sparsely used dashboards and keeps the executive experience coherent.

| Page | Scope | Linked BQs | Useful slicing / diagnostics |
|---|---|---|---|
| 1. CEO Overview | Growth, success, contribution, risk, controls | 01–08 | Date, market, merchant industry; current vs prior month/year |
| 2. Acceptance & Checkout | Funnel, abandonments, retries, time to capture | 02, 09, 10 | Checkout channel, method, Domestic/Cross-border, market |
| 3. Gateway & Routing | Attempt reliability, failure reasons, latency | 05, 09, 13 | Gateway, attempt number, method, UTC date/hour |
| 4. Revenue & Unit Economics | Fee income, cost, contribution, take rate | 03, 17 | Merchant, pricing tier, market, currency, method |
| 5. Merchant Portfolio | Activation, retention, concentration, cohorts | 04, 12, 16 | Onboard month, industry, country, pricing tier |
| 6. Risk & Servicing | Refunds, dispute cases, resolution | 06, 11, 18 | Capture cohort, method, reason, merchant |
| 7. Payouts & Finance Quality | Payout timeliness, balances, reconciliation, FX | 07, 14, 15 | Merchant, currency, scheduled/completed date |

**Drill-through rule:** Use a compact merchant detail page, gateway detail page, and incident day detail rather than creating many redundant top-level dashboards. Distinguish *what happened* from *why it happened*; observed segment differences do not establish causation.

## 4. Modeling and interpretation guardrails

- **Three grains:** one `intent_id` is a checkout; one `attempt_id` is a gateway request; one `fee_id` is a financial assessment. Never count joined attempts or fee rows as distinct checkouts without a grain-safe intermediate table/measure.
- **Domestic vs Cross-border** is defined only as `buyer_country = merchant.country_code` vs not equal; it is a **buyer-vs-merchant location proxy**, not proof of cross-border card settlement, issuer country, FX conversion, cross-border interchange or network routing.
- **USD is an analytical normalization**, not a settlement transaction or merchant FX margin. Local settlement amounts and exact integer ledger postings remain authoritative for reconciliation.
- **SCD Type 2** (`dim_gateway`, `dim_merchant`, `dim_customer`) captures ETL-observed changes; it does not recreate historical changes before first load. Filter via event-resolved surrogate keys, not only `is_current=1`, for historically sliced facts.
- **Cohort lag:** refunds/disputes may occur long after capture. Label whether a trend uses outcome-event month or capture cohort; avoid declaring recent capture cohorts fully mature.
- **Event-date and stock-date:** payment volumes are flows by capture date; ledger balance is a stock at the reporting cutoff. Never sum monthly closing balances as if they were monthly revenue.
- **Nonobservable business concepts:** real fraud rate, fraud loss, chargeback-network compliance ratio, customer acquisition cost (CAC), net retention by contracted merchant revenue, realized gateway savings from optimization, actual gateway uptime and PSP net income require data not present here.

## 5. Business ownership and operating cadence

| Cadence | Owner | Decision |
|---|---|---|
| Daily | Payment Operations | Detect abnormal failure spikes, stuck payouts and reconciliation exceptions |
| Weekly | Head of Payments + Merchant Success | Review acceptance by segment, retry diagnostics, servicing backlogs |
| Monthly | CEO + CFO + Commercial | Review TPV, contribution, merchant portfolio, concentration and FX completeness |
| Monthly with lag | Risk / Merchant Operations | Review matured disputes, refunds and recovery outcomes |
| Quarterly | CEO + Partnerships | Review gateway dependencies, pricing tiers and high-concentration accounts |

## 6. Release gates before answering the questions

BQ01/03/15/17 require verified historical FX availability and currency-aware conversion. BQ06/11/18 require the published cohort maturity window. BQ07 requires a verified or corrected schedule-deviation formula. All BQs require known `fee_type`, `final_outcome`, `outcome`, refund/dispute `status`, and payment-method domains; validate those codes against `main` before finalizing DAX.

**Cross-references:** [`kpi_definitions.md`](kpi_definitions.md), [`business_scenario.md`](business_scenario.md), [`data_dictionary_addendum.md`](data_dictionary_addendum.md), [`finpay_phase1_spec_v2_1_addendum.md`](finpay_phase1_spec_v2_1_addendum.md).
