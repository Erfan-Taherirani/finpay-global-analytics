# Lessons from a historical, multi-currency payments warehouse

These lessons are **cross-project guardrails**, not fixed assumptions to copy from the example project.

1. **Do not equate dimension ingestion time to historical truth.** ETL-time SCD2 cannot tell you what a merchant's pricing tier was years before the first data load. Require approved baseline or source history.
2. **Do not transform a status vocabulary by guesswork.** `succeeded` vs `completed` or `open` vs `pending` is an explicit business mapping. Validate against real distinct source values.
3. **Do not mistake a data-quality rule for database truth.** A `CHECK` with a nullable expression may pass because SQL Server treats UNKNOWN as allowed. Use `NOT NULL` and precise predicates.
4. **Do not overconstrain unique financial events.** `UNIQUE(intent_id, fee_type)` is valid only if exactly one of that fee type per intent is a documented rule. An event-grain fee fact normally keys by `fee_id`; multiple legitimate assessments must be modeled if they exist.
5. **Never convert minor amounts with a fixed divisor of 100 for every currency.** Use actual `minor_units` or source integer amounts and lossless fixed-point scaling.
6. **Do not leave financial flows only partially constrained.** Cross-event consistency belongs in a coordinated reconciliation after dependencies are loaded. A ledger is not correct just because all individual rows have the right signs.
7. **A polymorphic `source_id` does not support one ordinary FK.** Resolve expected origin table using `event_type`, and check row existence/amount/merchant/currency in the loader.
8. **Do not count processor cost as a merchant balance debit.** Processor cost is a platform expense, separate from merchant fee revenue.
9. **Use correct duration formulas.** A schedule deviation should be `completed_at - scheduled_at`, not a timestamp subtracted from itself. Unit and sign are part of the metric contract.
10. **A full-snapshot guard is dangerous for incremental/CDC loads.** Missing keys in a batch are expected. Choose mode before authoring row-count reconciliation.
11. **Don't force every external daily FX into an invented continuous series.** Holidays and data gaps require provenance/status and a consistent explicit carried-forward observation policy, if approved.
12. **Keep the final code proportional.** Lean ordinary-fact validations; comprehensive financial release reconciliation. Extensive repetitive ETL checks can increase error surface and cost.
13. **Do not let SQL normalization silently hide bad inputs.** Trimming, truncation and decimal rounding must be explicit and tested; `TRY_CONVERT` alone is insufficient.
14. **Defer cross-fact constraints honestly.** Loading fee rows before disputes may require delayed FK and reconciliation. Never claim the warehouse is fully verified while dependencies remain untested.
15. **Do not confuse SQL script delivery with deployment.** Executed, tested, provisioned, linted and proposed are different completion states.
