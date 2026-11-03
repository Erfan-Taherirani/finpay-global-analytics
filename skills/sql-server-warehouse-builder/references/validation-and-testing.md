# Practical validation and integration tests

Default to **lean checks**. Choose more only when stakes, data contract, or evidence justify them. A "small number" of SQL checks can combine several related predicates.

## Minimum required checks by table

| Type | Required checks | Optional as needed |
|---|---|---|
| Static/SCD1 dimension | Key not NULL, unique keys, required attributes, parent FKs, snapshot reconciliation | Contractual reference count |
| SCD2 dimension | Same checks + exactly one current version, version continuity, valid intervals, no-op rerun | Source-history backfills, end-date conventions |
| Event fact | PK uniqueness, parent FK coverage, timestamps in valid order, amount/sign, correct load mode, row counts | Derived duration consistency |
| Accumulating fact | Same + allowed status transitions and immutable business identifiers | Cross-child completion counts |
| Financial ledger | Exact minor-unit signs, allowed event types, unique source posting, source-event matching, balance reconciliation | Currency/date reporting FX reconciliation |
| FX fact | Unique (date,currency), positive valid rate, USD identity, provenance/observation date, dates/FKs | Completeness for every actual reporting date |

## Non-negotiable test scenarios

1. **First load:** target expected row count; PKs and FK links valid.
2. **Same snapshot rerun:** zero inserts, zero unapproved updates, unchanged financial totals.
3. **One legitimate change:** Type 1 updates one row; SCD2 closes previous and inserts one version; accumulating fact transitions only under allowed workflow; immutable ledger rejects edits.
4. **Duplicate key:** rejected and transaction rolled back.
5. **Missing/invalid reference:** rejected or routed to a documented unknown key/rejection table, not silently dropped.
6. **Truncated/malformed/rounded input:** rejected, or accepted only with an explicit contract/tolerance.
7. **Partial/incomplete snapshot:** rejected in full-snapshot mode. In CDC mode, absence of other target records is normal.
8. **Failure midway:** no partial committed target changes.
9. **Boundary time:** timestamp exactly equal to an SCD2 transition belongs to the new version. Facts older than first version follow approved baseline policy, not accidental fanout.
10. **Null / zero / FX:** blank/invalid statuses are not treated as valid; NULL FX is not zero; signed amounts have the correct currency scale.

When a SQL Server test instance is available, run these in a disposable database or rollback-only transaction where possible, capturing before/after counts and exception messages. Don't mark "PASS" from code inspection alone.

## Short QA queries (adapt to actual contract)

```sql
-- Duplicate fact business key (should return zero rows)
SELECT event_id, COUNT_BIG(*) AS n
FROM main.fact_example
GROUP BY event_id
HAVING COUNT_BIG(*) > 1;

-- SCD2: multiple active versions (should return zero)
SELECT business_id, COUNT_BIG(*) AS current_versions
FROM main.dim_example
WHERE is_current = 1
GROUP BY business_id
HAVING COUNT_BIG(*) > 1;

-- Orphan FK (should return zero)
SELECT COUNT_BIG(*) AS missing_parent
FROM main.fact_example AS f
LEFT JOIN main.dim_example AS d ON d.example_sk = f.example_sk
WHERE d.example_sk IS NULL;
```

**QA queries above use illustrative names; adapt names, table contracts, and constraints first.**

## Ledger reconciliation requirement

Financial posting balance should be checked in original *minor units* (group by merchant + currency), using authoritative financial facts and documented source IDs:

`captures - merchant_fees - successful_refunds - lost_disputes - lost_dispute_fees - completed_payouts = SUM(ledger.signed_amount_minor)`

- Confirm the original source event exists, has the correct status, matching merchant/currency, and one posting of the expected event_type. Ignore processor costs in merchant payable.
- Compare expected and actual postings **both directions** to catch missing and extra ledger events.
- Avoid decimal or float rounding in exact financial controls. A zero *exact integer* balance difference is the financial release gate.
- Don't make a full-history reconciliation dependent on facts that have not yet been loaded; note the missing dependency and schedule the gate after it arrives. Don't silently bypass it.
- Reversals/adjustments require their own event types and explicit debit/credit rule; don't reinterpret old facts.

## Audit record

Recommended per-table release report: source count, target count, new/updated, unmatched FKs, rejected rows (if allowed), missing FX count, idempotence rerun result, balance diff (if financial), execution status, sample validation failures, time and code version.
