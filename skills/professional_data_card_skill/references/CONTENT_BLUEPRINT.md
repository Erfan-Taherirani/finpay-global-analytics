# Dataset Card Content Blueprint

This reference defines what **every completed card** should contain. Only omit conditional sections if clearly irrelevant to the dataset; do not omit any attached table.

## Hierarchy

1. **Header visual**: horizontal image, descriptive alt text, dataset name, subtitle.
2. **Title/overview metadata**: dataset name, domain, scope/time range, snapshot date if known, owner/version if known, tables, central business purpose. Neutral dataset-type metadata where relevant.
3. **Interactive TOC**: collapsible `<details open>` with nested links to main sections and individual table anchors. A blank line follows `<summary>` for dependable GitHub rendering.
4. **Executive overview**: what a row/event represents overall, population, audience, business questions, approved usage, key metrics.
5. **Dataset inventory**: all tables, dimension/fact/reference grouping, grain, PK, row count **only if measured**, analytical purpose.
6. **Process/lifecycle**: explain the event flow and the business meaning of parent/child records; highlight 0:N or 1:N multiplicity and edge cases.
7. **Relationship map**: diagram plus a machine-readable-style mapping table listing `child column`, `parent table.column`, optionality, cardinality, relationship meaning, join risk.
8. **Dimension tables**: a full subsection for each dimension.
9. **Fact, bridge and reference tables**: a full subsection for each; document facts at exact event grain and financial units.
10. **Categorical value dictionary**: each bounded category: `table.column`, value, plain-language meaning, null handling, whether values are complete. A category label is not a business definition.
11. **Measurement conventions**: timestamps, time zones, calendars, key formats, money decimal/minor scaling, FX conventions, amount signs, snapshot censoring, if relevant.
12. **Quality controls and known limitations**: PK uniqueness, FK orphans, duplicate handling, impossible time ordering, accounting consistency, missingness, schema drift, source availability, known interpretive restrictions.
13. **Analytical use cases**: example KPIs, segmentation/cohorts, caveats about denominator and join fanout.
14. **Reproduction and change control**: folder layout, refresh steps, version date, transformations and reproducibility.

## Per-table entry: mandatory

- Table heading with stable anchor, business description, role, **one-row grain** and primary/composite key.
- One preview PNG using the shared visual style, with **genuine source rows or unavailable state**.
- Full column dictionary: `Column | Type | Meaning | Constraints / keys / transformation` (add `Nullable`, `Unit` where supported).
- Relationship notes, including physical and logical links and optionality.
- Categorical values with definitions (either immediately below or deep-linked to central dictionary).
- Business measures, allowed values, event conditions or status transitions as applicable.
- Data-quality or ambiguity notes only where substantively relevant.
- `Back to contents` anchor.

## Accuracy requirements

- Do not infer schema types from only sampled values without marking them inferred.
- Distinguish source-native raw fields and computed/prepared fields.
- A missing record count is `Not measured`, never 0.
- If CSV/Parquet is inaccessible, the preview remains visibly unavailable. No fictional rows as data previews.
- No false precision in dates, category counts, exchange rates, monetary amounts or validation status.
- When aggregating facts, check one-to-many joins, null keys, sign semantics, status denominators and date-of-record.

## Markdown navigation pattern

```markdown
<a id="table-of-contents"></a>
<details open>
<summary><strong>Navigate the dataset</strong></summary>

- [Overview](#overview)
- [Inventory](#inventory)
- [Dimensions](#dimensions)
  - [dim_customer](#dim_customer)
- [Facts](#facts)
  - [fact_transaction](#fact_transaction)

</details>

<a id="dim_customer"></a>
### `dim_customer` — Customer dimension

[↑ Back to contents](#table-of-contents)
```
