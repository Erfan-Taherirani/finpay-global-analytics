# Example: unrelated retail analytics project

**Purpose:** Show transferability. These are **illustrative columns and rules only**; never assume they exist in the user's real project.

Scenario: A retailer imports full daily snapshots of sellers and orders into SQL Server. Sources include:

- `stg.dim_seller`: `seller_id`, `display_name`, `region_code`, `account_status`.
- `stg.fact_order`: `order_id`, `seller_id`, `placed_at`, `shipped_at`, `order_status`, `order_total_minor`, `currency_code`.

Proposed decisions to confirm:

1. `dim_seller` has one business ID per seller. If the user needs seller-region history, use SCD2 (`seller_sk`, `valid_from`, `valid_to`, `is_current`, `version_number`). If not, SCD1 is simpler. Load snapshot with source completeness validation.
2. `fact_order` has one row per order, an accumulating snapshot updated from placed to shipped. Do not use SCD2; keep immutable order key/principal and permit only defined transitions. Link `seller_sk` to the seller version **at order event time**, handling older pre-ETL records honestly.
3. Choose money units: use source `order_total_minor` as authoritative. Convert to major using currency's minor-units count only for reporting. Avoid mixed-currency sums.
4. DDL dependency: currency and seller dimensions before orders. Key constraints and only query-driven indexes.
5. Loader behavior: full snapshot means rows missing from staging should be flagged, not silently deleted. If later switching to CDC, replace full-snapshot completeness checks with watermark logic.

Example prompt:
> Using sql-server-warehouse-builder, create `main.dim_seller` from the four source columns above. Tell me whether SCD1 or SCD2 is justified and produce two scripts. The source is a full snapshot, and seller-region history is required. Use the simplest safe validation.

**Expected design sketch:** `seller_sk` surrogate, original four fields, SCD2 version metadata, unique current version by `seller_id`, and transactional loader closing only materially changed current rows. The first load creates one current version per seller; unchanged reload creates none. No amount of SQL can reconstruct pre-load region changes unless prior source history exists.
