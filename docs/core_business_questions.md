****# FinPay Global — Core Business Questions

**Version:** 2.0 · **Owner:** Analytics / BI · **Scope:** Five-year fictional PSP business · **Data as-of:** 2026-10-01 UTC

Questions below are linked to metrics, fact grains, dimensions and concrete decisions. **No target is a real industry baseline unless separately cited in `benchmark_assumptions.md`.**

| ID | Stakeholder | Core business question | Required metrics | Slice / drill down | Expected business decision |
|---|---|---|---|---|---|
| BQ01 | Leadership | Is payment volume growing sustainably? | Gross TPV USD, successful captures, AOV, YoY/MoM | Month, merchant market, sector | Choose growth markets and verticals |
| BQ02 | Payments | Where and why do payments fail? | Attempt success/failure rate, distinct failure reasons, retry recovery | Gateway, method, country, day/hour | Tune routing or address outages |
| BQ03 | Product | Are customers successfully completing checkout? | Intent conversion, abandonment, retries per intent | Checkout channel, customer cohort, merchant | Improve checkout flow |
| BQ04 | Product | Is the wallet shift helping conversion and volume? | Wallet payment value share, method success, TPV | Year, market, merchant sector | Prioritize supported methods |
| BQ05 | Sales | Which merchants drive volume and which are declining? | Merchant TPV, TPV growth, retention, concentration | Pricing tier, acquisition cohort, market, sector | Retention and account planning |
| BQ06 | Finance | Is revenue growing faster than processor expenses? | Merchant fee revenue, processor cost, contribution, contribution margin | Month, method, tier, merchant | Pricing and vendor negotiation |
| BQ07 | Finance | Which merchant/method combinations are unprofitable? | Contribution per captured payment, contribution per merchant | Ticket-size bands, method, pricing tier | Change commercial terms or routing |
| BQ08 | Risk | Which sectors have abnormal post-payment losses? | Mature-cohort refund incidence/value, dispute incidence and lost dispute value | Industry, market, merchant cohort | Escalate anomalous merchants |
| BQ09 | Operations | Are payouts reliable and predictable? | Payout on-time rate, late duration, failed payouts, outstanding payable | Month, settlement currency, merchant tier | Improve payout process and SLAs |
| BQ10 | Finance | Do source events reconcile to merchant balances? | Opening balance + signed ledger movements − payouts = closing payable | Merchant, currency, as-of month | Audit exceptions and control gaps |
| BQ11 | BI | Are observed trends real or artifacts of FX and cohort definition? | Local currency versus USD measures, FX impact, stable-cohort metrics | Currency, market, vintage | Avoid false growth conclusions |
| BQ12 | Leadership | What unusual changes merit investigation? | Daily success-rate anomalies, TPV change, latency and refund spikes | Incident day, gateway, merchant | Root-cause investigations |

## Definition of a well-answered business question

Every analysis must identify (1) decision owner, (2) explicit metric definition, (3) eligible population / fact grain, (4) time basis and currency, (5) meaningful comparison, (6) a competing explanation, (7) a proposed action and (8) validation or follow-up.

## Recommended dashboard pages

1. **Executive overview:** captured TPV in USD (only when real FX loaded), count of successful intents, merchant fee revenue, processing contribution, approval/conversion rates.
2. **Payment operations:** gateway/method waterfall, top failure reasons, retry recovery and outage investigation.
3. **Merchant economics:** TPV concentration, cohort retention, margin distribution and loss-leading merchant cohorts.
4. **Risk & servicing:** refund/dispute mature cohorts with source-event dates and 45/90-day maturity constraints.
5. **Payout & reconciliation:** available merchant balances by currency, overdue payouts, ledger control checks.

## Analytical caveats

- Merchant domicile is not payer domicile; the dataset records both.
- A customer identifier is NULL for guest checkout; do not equate buyer IDs with all humans served.
- Gateway failures belong at **attempt** grain, not intent grain. Gateway contribution to TPV should attribute capture to the successful attempt.
- Wallet share benchmark sources are generally **share of payment value**, not count of attempts.
- Losses and refunds should be measured against sufficiently mature **capture cohorts**, not same-calendar-month payments.
- A higher modeled decline rate in a market can reflect fictional sampling assumptions, not real fraud risk.
- The Iran USD sandbox segment and the hypothetical Russia scenario are not demonstrations of real-world operational capability.
