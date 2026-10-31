# Generated Dataset Profile — Five-Year Build

**Project:** FinPay Global · **Build:** version 2.0 · **Generation seed:** `20261021` · **Cutoff:** 2026-10-01 00:00 UTC

All counts and ratios below are **realized results from synthetic generated records**, not measured fintech industry performance.

## Build counts

| Table | Rows |
|---|---:|
| `dim_currency` | 10 |
| `dim_market` | 12 |
| `dim_gateway` | 5 |
| `dim_merchant` | 2,000 |
| `dim_customer` | 100,000 |
| `dim_date` | 1,826 |
| `fact_fx_rate` | 1,826 (USD identity ONLY) |
| `fact_payment_intent` | 1,620,000 |
| `fact_payment_attempt` | 1,665,396 |
| `fact_fee` | 2,872,140 |
| `fact_refund` | 45,503 |
| `fact_dispute` | 1,834 |
| `fact_settlement` | 85,169 |
| `fact_merchant_ledger` | 2,995,584 |
| **Total** | **9,391,305** |

## Payment outcomes and synthetic operating patterns

| Outcome | Count | Share of all intents |
|---|---:|---:|
| Succeeded / captured | 1,435,757 | 88.63% |
| Failed | 130,941 | 8.08% |
| Abandoned | 51,475 | 3.18% |
| Pending | 1,827 | 0.11% |

- Guest checkouts: **437,109** (26.98% of intents). Others refer to a previously signed-up fictional customer.
- Payment attempts by method: wallet **860,988**, card **504,303**, bank debit **300,105**. These are **attempt counts**, not payment-value share; do not compare them directly to Worldpay wallet-value reports.
- All 2,000 merchant accounts were included in the reconciled merchant balance audit.
- **Per-merchant, per-currency source-to-ledger reconciliation:** zero residual for captures, merchant fees, successful refunds, lost dispute principal, dispute fees, and completed payouts.
- **FX restriction:** Only USD=1 identity rows exist. `fact_fx_rate.csv.gz` is incomplete for nine non-USD currencies. Therefore USD-wide TPV, revenue, contribution, take rate and currency-converted merchant rankings are **not yet available**. Run `src/fetch_fx.py` with internet access and verify source provenance.

## Quality status

Automated validation: **PASS**, including row-count check, parent-child payment capture cardinality, successful-fee pairs, cumulative refund caps, no simultaneous successful-refund/dispute (v2), timestamps before cutoff, and exact merchant balance reconciliation. See `data/quality_report.json` and `data/strict_validation_report.json`.

**Known model limitation:** Merchant `payout_frequency` has monthly/weekly preferences, but actual generated settlements are batched monthly; this must be treated as a simulation limitation, not an implemented contract SLA.
