# FinPay Global — PSP Business Scenario and Executive Operating Model (v3.0)

**Updated:** 2026-11-04  
**Status:** Fictional portfolio scenario, aligned to revised analytics and SQL Server warehouse design.

## 1. Company and customer proposition

FinPay Global is a **fictional payment service provider (PSP)** offering a hosted checkout and orchestration layer to merchants operating across 12 modeled markets: US, GB, DE, FR, CA, AU, JP, CN, IR, RU, MX, and EG. Customers pay via card, digital wallet or bank debit. The platform routes payment attempts through five fictional gateway providers (AtlasFlow, BlueHarbor, OrbitRoute, NovaSwitch, PineBridge) and may retry failed attempts. It records completed captures, merchant processing fees, processor costs, post-payment refunds and disputes, merchant payouts, and a merchant-payable subledger.

This is a synthetic BI portfolio, **not** a claim that any company can legally or commercially service every modeled market. The Iran scenario is USD-only in the 10-currency dataset; the Russia scenario is fictional. No real merchant, customer, bank, fraud or authorization event is represented.

## 2. Data and product scope

| Category | Defined scope |
|---|---|
| Period | 60 calendar months: 2021-10-01 to 2026-09-30; UTC end exclusive 2026-10-01 |
| Portfolio | 2,000 merchants; 100,000 registered customers plus anonymous guest checkouts |
| Data volume | 8–10 million rows design target across six dimensions and eight facts |
| Gateway network | Five fictional payment gateways |
| Methods | `card`, `wallet`, `bank_debit` |
| Currency | USD, EUR, GBP, CAD, AUD, JPY, CNY, RUB, MXN, EGP |
| Reporting | Local settlement-currency principal; optional normalized USD based on verified historical daily FX observations |
| Storage | Processed CSV → SQL Server `stg` full snapshot → stored procedures → `main` analytical warehouse → Power BI |
| Historical dimensions | SCD Type 2 for merchant/customer/gateway; first ETL observation does not recreate earlier attribute history |

**Commercial model:** Merchants pay FinPay processing fees per captured transaction; FinPay incurs processor fees. The spread is **processing contribution before operating overhead**. Dispute fees, where assessed, are modeled separately. Merchant captured principal and payout flows are **merchant money**, not PSP revenue. The simulated business does not generate FX spread, real-time conversion revenue, interchange detail, fraud loss reserves, marketing expense, staffing overhead, or complete corporate P&L.

## 3. Lifecycle of a payment and its money

1. A buyer starts a checkout (`fact_payment_intent`) for one merchant; that checkout can be abandoned, pending, failed, or ultimately captured.
2. The buyer/payment method may generate zero to three attempts (`fact_payment_attempt`), each routed to a gateway. A retry is a new **attempt**, not a new **checkout**.
3. A successfully captured intent produces merchant captured principal and fee/cost assessments (`fact_fee`). Payment and fee timestamps may differ.
4. Post-capture, a merchant may process a partial/full refund or receive a dispute. The simplified synthetic model limits these cases and does not represent every real PSP outcome.
5. Successful refunds and lost disputes reduce the merchant-payable subledger. A dispute fee, if assessed, is another merchant debit. Processor expense never debits merchant payable.
6. Merchant payouts are instructions (`fact_settlement`). Only a completed payout reduces the payable ledger (`fact_merchant_ledger`); pending/failed ones do not.
7. The merchant's payable balance is the sum of signed local-currency ledger postings. Reconcile it at the `(merchant, currency)` level with exact integer minor units.

## 4. Why Domestic/Cross-border is now important

A newly introduced warehouse attribute, `main.fact_payment_intent.transaction_market_type`, is derived by comparing the **buyer country** with the **merchant country**:

```sql
CASE
    WHEN i.buyer_country IS NULL OR m.country_code IS NULL THEN 'Unknown'
    WHEN i.buyer_country = m.country_code THEN 'Domestic'
    ELSE 'Cross-border'
END
```

The earlier documented loader uses `CASE WHEN buyer_country = merchant.country_code THEN 'Domestic' ELSE 'Cross-border' END`, which would silently classify missing country values as Cross-border. **Recommendation:** validate non-null source countries or adopt explicit `Unknown`; this is a recommended contract correction and is not confirmed implemented.

This field supports segment analysis of checkout conversion, attempt failure, retry behavior, captured TPV, merchant concentration and processing contribution. It **does not** indicate the card's issuer country, international network fee, foreign-exchange trade, conversion fee, cross-border settlement, sanctions compliance, or a realized FX spread. In this synthetic model, presentment and merchant settlement currency are the same.

## 5. Leadership decisions and responsibilities

| Leadership | Primary concern | Decisions driven by the revised reporting |
|---|---|---|
| CEO | Sustainable portfolio growth + controlled risk | Which geographies, merchants and channels are growing profitably? |
| CFO / Finance | Transaction processing margin + balance integrity | Which fee/cost mix is healthy; do ledgers reconcile precisely; what payable exposure remains? |
| Head of Payments | End-to-end checkout and gateway performance | Where do first attempts fail, which retries rescue sales, and what patterns merit investigation? |
| Head of Merchant Success | Activation, retention and high-value relationships | Which merchant cohorts need activation and retention support? |
| Risk / Servicing | Refunds, disputes and processing backlog | Which captured cohorts and merchant segments create the most servicing load? |
| Operations | Payout throughput and SLA proxy | Which payouts are pending or late, and who needs escalation? |
| BI / Data Engineering | Publishable metric consistency | Are filters, amount types, date roles, SCD2 lookups and FX rates trustworthy? |

## 6. Financial boundaries — CEO interpretation

For a successfully captured payment of USD 100.00, a merchant processing fee of USD 3.00, a processor cost of USD 1.80, and a completed payout of USD 97.00:

- Captured TPV = USD 100.00.
- PSP processing fee revenue = USD 3.00.
- Processor cost = USD 1.80.
- **Modeled processing contribution = USD 1.20**, before labor, infrastructure, fraud exposure and other expenses.
- The completed USD 97.00 payout is settlement of a merchant payable, **not** USD 97.00 of PSP expense or a reduction to TPV.
- The merchant ledger returns to USD 0.00 if all modeled entries are posted correctly.

## 7. Important business limitations

- The dataset is deterministic and synthetic; gateway incidents, growth patterns and risk correlations are simulated, not external market estimates.
- Real FX status must be verified in the actual warehouse before unrestricted USD reporting; an earlier project export was incomplete for non-USD observations.
- The 12 markets do not mean 12 domestic currencies; IRR is not included.
- `onboarded_at`, customer signup and payment events do not identify campaign cost or ROI; **CAC/ROAS are unavailable**.
- The gateway attempt model does not capture every card-authorization substage or full network chargeback monitoring standards.
- A late dispute/refund may cause negative merchant payable; this is potential recoverable merchant exposure, **not automatically a recognized PSP loss**.
- The simulator batches monthly payouts despite an earlier merchant payout-frequency preference; do not claim the payout engine implements contractual weekly payout schedules.

**Next:** [`core_business_questions.md`](core_business_questions.md) is the management-question register, and [`kpi_definitions.md`](kpi_definitions.md) is the only canonical source of measure formulas. The data-dictionary addendum tracks newer derived fields and quality corrections.
