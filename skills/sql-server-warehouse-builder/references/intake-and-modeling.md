# Project intake and warehouse modeling

Read this when initializing a new project, choosing dimensions/facts, or mapping SCD2 keys into facts.

## Minimum viable project contract

Capture these properties, accepting **unknown** explicitly rather than guessing:

| Area | Information required | Defaults only when approved |
|---|---|---|
| Platform | SQL Server version, deployment (local/managed), database, SQL compatibility | SQL Server 2019+ patterns |
| Schemas | Staging, target, ETL procedure schema | `stg`, `main`, `dbo` |
| Sources | Exact table and column names/types, source file contracts, sample/nulls, data dictionary | Never assume fields |
| Grain/IDs | Table grain, stable business PK, uniqueness, relationships, cardinality | No assumed uniqueness |
| Capture mode | Full snapshot, changes-only, append-only, or mixed; source deletion policy | Never infer full snapshot |
| Time | Time zone, window, cutoff, event timestamp, SCD validity origin | UTC only when specified |
| History | Which attributes need past states; how past versions are known | SCD1 unless justified |
| Financials | Unit (minor/major), minor digits per currency, rate direction, rate timestamp, correction policy | Missing FX = NULL |
| Workload | Power BI Import/DirectQuery, table size, refresh cadence, SLAs | No arbitrary indexes |
| Output | One table or all; script packaging, number of code blocks, execution permission | One table, two scripts |

Ask only for fields that affect correctness of the present work. If the user supplied full details or authorized a plan, proceed without repeating intake questions.

## Classify table and load mode first

| Class | Grain | Typical key | Recommended history/load |
|---|---|---|---|
| Static reference dimension | Country/currency/date | Stable natural key | SCD0 or SCD1, no arbitrary SCD2 |
| Mutable descriptive dimension | Merchant/customer/vendor | Business ID + optional version surrogate | SCD1 for nonhistorical columns; SCD2 for tracked attributes |
| Transaction/event fact | Fee/posting/attempt | Event ID or documented composite | Append-only or audited corrections; no SCD2 |
| Accumulating snapshot | Checkout/claim/order workflow | One lifecycle/business ID | Insert + permitted status updates; no SCD2 |
| Periodic snapshot | Daily balance/inventory | Entity + period | Snapshot replacement or load by partition, documented policy |
| External reference fact | FX rate by currency/date | Composite currency/date | Version/audit corrections as agreed; store provenance |

Avoid one generic upsert for all: mutable customer status and irreversible financial postings require different policies.

## SCD2 design contract

If needed, add `entity_sk BIGINT IDENTITY PRIMARY KEY`, keep `entity_id` as the source business key, and add:

- `valid_from DATETIME2(7) NOT NULL`
- `valid_to DATETIME2(7) NOT NULL` (exclusive)
- `is_current BIT NOT NULL`
- `version_number INT NOT NULL`

Use `(entity_id, version_number)` unique, optionally `(entity_id, valid_from)` unique, and `UNIQUE INDEX ... (entity_id) WHERE is_current=1`. Use source-tracked attribute comparison and **one** effective timestamp for a given load. Current rows have a documented far-future end sentinel; expired rows have `valid_to` equal to their successor's `valid_from`. If source timestamps are trusted and available, a source-effective-time history may be appropriate; if history is based on `SYSUTCDATETIME()`, it tracks when the warehouse first observed a value, *not when it truly changed historically*.

For facts preceding the first observed SCD2 record, choose one of:

1. **Unknown historical state**: link a true unknown member or nullable surrogate (loss of prior-state attributes is honest).
2. **Earliest observed baseline**: assign version 1 to earlier facts **only after explicit approval**; label it a proxy, not as-of truth.
3. **Source backfill**: use historical snapshots/effective timestamps when supplied to reconstruct valid prior versions.

An SCD2 fact join must be at most one match per fact. Validate uniqueness and completeness. Use half-open intervals `[valid_from,valid_to)` and ensure boundary equality maps to the newer version. Do not fan out facts by joining directly to every historical row sharing a business key.

For current-state analytics, consider separate current-dimension views; do not silently rekey historical facts to today's surrogate because a dimension changed later.

## Schema and load ordering

1. Base/static dimensions such as currency, market, date.
2. Mutable dimensions such as gateway, customer, merchant.
3. Core parent facts such as order/checkout/payment intent.
4. Dependent facts such as attempts, fees, refunds, disputes, settlements.
5. Ledger/reconciliation fact after source financial facts.
6. Reference FX can be loaded earlier if desired; stored USD amounts should be reconciled to it after arrival.

A dependency graph decides the real order. **Do not apply the example ordering to a project whose graph differs.** Nullable or polymorphic references may require deferred validations; document a concrete follow-up migration rather than inserting fictitious FK values.

## Power BI relationship guidance

- One dimension surrogate key -> many fact rows; use a unique key on the one-side.
- Link facts to date dimensions by integer YYYYMMDD keys when beneficial, with explicit UTC/calendar semantics.
- Avoid bidirectional relationships and fact-to-fact links that cause ambiguity; use a bridge or a clearly documented shared dimension when needed.
- Model currency and transaction amounts consistently. Local currency sums are meaningful only inside a single currency; USD conversion needs a dated, trustworthy rate.
- Define data-grain and time-role relationships (created/closed/captured) explicitly and decide active vs inactive date links.
