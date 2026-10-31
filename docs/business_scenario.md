# FinPay Global — Business Scenario & Operating Plan

**Version:** 2.0 · **Status:** Fictional training scenario · **Period:** 2021-10-01 to 2026-09-30 · **Audience:** BI analysts and hiring reviewers

## Executive summary

FinPay Global is a **fictional payment service provider (PSP)** offering an API, hosted checkout, payment routing, reconciliation and merchant payouts to digital businesses. Merchants integrate once and accept cards, digital wallets and bank debit through five fictional gateway partners. FinPay makes money by assessing merchant processing fees; it incurs separate third-party processor expenses. It is **not** a bank, deposit-taker, creditor or holder of actual customer funds in this simulation.

This project simulates the internal analytics of the PSP; all customers, merchants, gateways, events, pricing and failures are invented. **Historical reference FX is the only proposed real-data input** and is loaded separately, with provenance and daily observation timestamps. No operational transactions or risk rates are real.

## Products and customer value proposition

1. **Unified Checkout:** one API / hosted page supporting three payment methods and merchant-local prices.
2. **Smart Gateway Routing:** five fictional processors; conditional authorization outcomes and optional retries. Merchant- and market-level route performance is measurable.
3. **Merchant Console:** TPV, approval trends, payment disputes, refunds and payout status.
4. **Financial Operations:** monthly or weekly merchant payout elections, a signed merchant-payable subledger, fees and costs, and period reconciliation.
5. **Analytics:** merchant cohorts, volume concentration, pricing/margin segmentation, dispute exposure, gateway reliability and payout SLAs.

## Customers, markets and product boundaries

- **Merchants:** 2,000 fictional accounts across US, UK, Germany, France, Canada, Australia, Japan, China, Iran, Russia, Mexico and Egypt.
- **Buyers:** 100,000 fictional registered customers, plus anonymous guest checkouts.
- **Transaction currencies:** USD, EUR, GBP, CAD, AUD, JPY, CNY, RUB, MXN and EGP. Germany and France share EUR.
- **Iran handling:** The 10-currency limit excludes IRR. Iranian merchant records are **sandbox / what-if entities with USD-denominated fictional activity**; these are not claims of cross-border payment service availability, authorization, settlement arrangements or regulatory permission. Russian activity is also an abstract fictional domestic scenario, not a claim that global providers legally route these payments. The data must never be used as compliance guidance.
- **Payment methods:** card, wallet, bank_debit. The data does not model instant transfers, BNPL, stablecoins, full issuer authorization states, FX spreads, taxes, or real fraud scoring.
- **Local-currency processing:** A purchase is presented and settled in the merchant's single configured currency, which avoids inventing FX quotes for financial posting. USD reporting *requires* a real historical USD rate series via `src/fetch_fx.py`.

## Business model and unit economics

**Revenue engine:** Merchant fees = percentage of captured local amount + a fixed local-currency component, by merchant pricing tier. A lost dispute can trigger an additional assessed dispute fee. Failed authorizations do not themselves generate merchant revenue in v2.

**Variable costs:** Each captured payment creates one processing-cost record, with assumed method-based cost. Cost is a **platform expense**, not a debit against merchant payable.

**Profitability proxy:** Processing contribution = merchant fees + dispute fees − processor costs; excludes payroll, compliance, operations, taxes, bank fees not modeled, funding costs and other overhead. It is not accounting net profit.

**Merchant payable:** Credits from captures; debits from merchant fees, successful refunds, lost dispute principal, dispute fees and completed payouts. Payouts cannot exceed the positive available merchant balance at initiation. Disputes after payouts can cause deficits, recorded as receivables.

## Fictional five-year evolution

| Stage | Period | Strategy | Designed analysis opportunity |
|---|---|---|---|
| Foundation | 2021-10 to 2022-09 | First merchants, mostly cards, early integration | Acquisition cohorts and setup frictions |
| Scale-up | 2022-10 to 2023-09 | Merchant acquisition and regional traffic increase | Merchant segmentation and success by region |
| Reliability | 2023-10 to 2024-09 | Routing improvement; temporary provider disturbances | Retry effectiveness, incident analysis |
| Product expansion | 2024-10 to 2025-09 | Wallet share grows, larger enterprises sign up | Payment method mix, revenue concentration |
| Efficiency | 2025-10 to 2026-09 | Optimize gateway economics, pricing and payouts | Contribution margins, cost leakage, reliability |

The generator simulates time trends rather than hard-coding exact business KPI results. These phases are a storyline, **not a historical account**.

## Operating workflows

**Merchant onboarding → checkout intent → payment attempt(s) → exactly one capture or no capture → assessed merchant/processor fees → optional refund or dispute → payout schedule → ledger/reconciliation.** A payment intent is not a payment attempt; unsuccessful retries do not generate additional captured transactions.

Finance monitors merchant balances and payout aging. Product monitors conversion and wallets. Payment operations monitors gateway declines, latency and incidents. Account management monitors merchant growth and retention. Risk monitors refund/dispute cohorts with maturity windows.

## Operating principles and analytical guardrails

- **Reporting timezone:** UTC for stored events and global dashboards; local dates only when the report explicitly changes basis.
- **Money:** integer minor units; explicit `dim_currency.minor_units` (JPY = 0), no binary floats in money amounts. No summation of unlike currencies.
- **Revenue versus volume:** TPV is not FinPay revenue; gross captured TPV includes amounts later refunded.
- **Approval versus conversion:** attempt success and intent success use different denominators.
- **Temporal integrity:** only historical events through 2026-09-30; delayed refunds/disputes beyond cutoff aren't backfilled into the snapshot.
- **Risk:** the financial model is deliberately simplified; especially disputes, failed payouts, beneficiary bank charges, settlement reserves, taxes and regulation.

## Stakeholders and decisions

| Stakeholder | Decision supported | Evidence |
|---|---|---|
| COO / Payments lead | Route traffic away from unreliable gateways | Failure by gateway × region × method; p95 latency |
| VP Product | Offer more wallet or bank-debit options | Payment mix, conversion trends, cohorts |
| VP Sales | Retain high-value merchants; identify potential upsell | Merchant TPV, margin and retention |
| CFO | Identify negative margins, reconcile payables | Fee and cost facts, merchant payable ledger |
| Head of Risk | Investigate merchants with abnormal chargebacks | Mature capture cohorts and disputes |
| Treasury / Operations | Reduce payout delays | SLA, failed payouts, merchant balance |

## Success criteria for the portfolio project

Provide reproducible generator, 8–10 million rows including dimensions and facts, documented PK/FK/metric grain, PostgreSQL DDL and tests, proof of exact local-currency ledger reconciliation, honest FX provenance, and a Power BI star-model-ready semantic layer. Recommendations should include limitations and the effect of data-generation assumptions.
