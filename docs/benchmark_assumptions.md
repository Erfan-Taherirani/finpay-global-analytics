# FinPay Global — External Benchmarks and Synthetic Calibration

**Purpose:** Distinguish *measured published evidence* from assumptions used to create training data.

## Source-backed observations

| Topic | Publicly reported observation | Source | Modeling treatment |
|---|---|---|---|
| Global online wallet trend | Wallets represented **49%** of global e-commerce *value* in 2022. | Worldpay 2023 report: https://www.worldpay.com/en/press-releases/account-account-payments-set-revolutionize-shopping-e-commerce | Direction of time trend only, not a merchant-specific rate |
| Global online wallet trend | Wallets represented **53%** of global e-commerce *value* in 2024. | Worldpay 2025: https://www.worldpay.com/en-AU/press-releases/10-years-of-cash-cards-and-crypto-worldpays-global-payments-report | Direction / approximate order of magnitude; dataset only includes three method types |
| Global online wallet trend | Wallets represented **56%** of e-commerce *value* in 2025. | Worldpay 2026: https://www.worldpay.com/en/insights/articles/gpr-2026-trend-3 | Check value-weighted share *after* generation, not transaction-count equality |
| Example US merchant card fee | US standard cards **2.9% + USD 0.30** successful transaction (with additional international / conversion fees). | Stripe US pricing: https://stripe.com/pricing | Illustrative starter-tier inspiration **only**; not a global rate card |
| Authorization success | Visa states a **96.3% global average** for its particular Intelligent Authorization solution. | https://www.visa.co.uk/about-visa/newsroom/press-releases.3438503.html | Product-specific, **not** global PSP success benchmark; no forced 96.3% |
| Industry focus | Revenue, success, costs, chargebacks and settlement are monitored by industry practitioners. | Visa Acceptance 2025 report: https://www.visaacceptance.com/content/dam/documents/campaign/fraud-report/global-fraud-report-2025.pdf | Justifies dashboard metric selection, not conversion rates |

Sources checked 2026-10-21. These third-party findings reflect their own definitions, respondents, geographies and periods and must not be treated as universal or directly comparable.

## Explicit synthetic modeling choices

| Parameter | Simulation rule (not observed evidence) | Why useful |
|---|---|---|
| Annual demand | Gradual rise over five years, more activity in Nov/Dec and less Jan/Feb | Trend decomposition and seasonal forecasts |
| Merchant TPV | Lognormal traffic propensity, higher for enterprise tier | Pareto concentration and merchant segmentation |
| Checkout channels | Web / mobile web / app distribution drawn by seed | Channel comparisons |
| Buyer segments | 27% guest attempts, heterogeneous frequency among registered buyers | Conversion by identifiable customers |
| Authorization success | Conditional probabilities using method, merchant geography, gateway, simulated incident dates | Multivariate gateway failure investigations |
| Gateway disturbances | Fictional bursts on selected 2023, 2025 and 2026 dates | Detectable incident/root-cause analysis |
| Wallet method selection | Rising usage over time with region-level differences | Product mix analysis; **not calibrated exactly to Worldpay** |
| Merchant processing fee | Tiered % + local-currency fixed component, starter 2.9% plus local nominal equivalent of 0.25 USD | Pricing and small-ticket margin analysis |
| Processing costs | Method-related % + local fixed charge | Merchant unit economics |
| Refunds | Merchandising-sector-dependent probability; later events; full / partial | Operational and cohort analysis |
| Disputes | Rare, card-specific, later events; open/won/lost outcome | Maturity adjustment and risk monitoring |
| Payouts | Fictional monthly payout batch simulation irrespective of merchant's weekly preference | Simplified balances; **weekly SLA not actually implemented** |
| FX | **Real daily reference FX only; no synthetic rates** | Avoid fictitious USD reporting |

All synthetic settings are editable and seeded. The generator records realized data distributions; do not relabel them as sourced benchmarks.

## Known simplifications

- Simulates local-currency merchant capture and settlement only (no live FX spreads and no cross-currency settlement).
- Method selection follows a broad trend, not 12 independently validated regional distributions.
- Business growth is platform-level, not independent merchant survival analysis.
- Merchant payout preference is stored but the current generator uses a monthly settlement batch and does not implement actual weekly payouts.
- The fee model approximates economics but is not compliant accounting, card-network pricing or a regulatory statement.
