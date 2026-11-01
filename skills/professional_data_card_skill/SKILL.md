---
name: professional-data-card
description: Build a polished, comprehensive, GitHub-ready dataset card from uploaded data, notebooks, data dictionaries, SQL, and ETL scripts. Include an interactive Markdown table of contents, overview, table inventory, grain and relationship map, complete column dictionary, categorical meanings, consistent header and genuine table previews, quality checks, and a downloadable ZIP.
---

# Professional Data Card — reusable skill

## Trigger
Use for requests to create, regenerate, extend, or standardize a **data card, dataset dictionary, analytical dataset documentation, or data model catalog**, especially when the user wants the FinPay-style visual documentation.

## Required output
Produce **one complete downloadable ZIP** with this structure:

```text
<slug>_data_card/
├── data_card.md
├── README.md
├── assets/
│   ├── header.png
│   ├── relationship_map.png
│   ├── relationship_map.dot
│   └── <one-preview-for-every-table>.png
└── scripts/
    └── regenerate_assets.py  # where possible
```

Optionally provide `data_card.md` separately. Every relative Markdown image link must resolve within the ZIP.

## Workflow (follow in order)

1. **Inspect the evidence.** Read all attached data files, notebooks (including Markdown and cached outputs), DDL, ETL scripts, data dictionaries, and manifests. Prefer actual column metadata and actual first records. Determine physical vs derived columns. Do not silently reconcile contradictory definitions. Ask for essential absent materials only when unavoidable; otherwise continue and mark unavailable facts neutrally.
2. **Build the contract.** Identify every table and its role (dimension, fact, bridge, reference), row grain, primary/composite key, foreign keys, optional keys, and multi-table relationships. Separate physical FKs from logical relationships and prevent join fanout in analytics.
3. **Document every column.** For each: name, type (verified or inferred), precise business meaning, nullability if known, PK/FK/derived classification, unit or timestamp semantics, and important caveats. No column omissions. If a meaning cannot be established, write `Not specified` instead of guessing.
4. **Decode categories.** List the complete distinct values of bounded categorical columns when data is available; explain **each** value with a business-grounded meaning. For codes or statuses without a supplied definition, use `Meaning not defined` rather than inventing one. Distinguish null/unknown from an ordinary category. For high-cardinality fields, say so and provide a representative summary instead of an unhelpful exhaustive list.
5. **Write the document.** Use `references/CONTENT_BLUEPRINT.md` as the section contract and `references/FINPAY_STYLE_EXAMPLE.md` solely as a visual/structural benchmark. Cover overview, inventory, lifecycle, relationship map, grouped dimensions and facts, categorical dictionary, units/time/financial conventions where applicable, integrity tests, limitations, analytic uses, and reproducibility.
6. **Generate a cohesive image system.** Use the navy/teal/periwinkle palette in `references/VISUAL_SYSTEM.md`. Produce one horizontal branded hero image, a readable relationship diagram, and **one table image for every table** using 3–5 **actual** first rows. If real rows are missing, create a tasteful `Preview unavailable — data file not supplied` visual; never invent rows and present them as observations. Do not reuse FinPay branding for other datasets.
7. **Add working navigation.** Use a collapsible `<details open>` Markdown TOC, actual `<a id="...">` anchors, working relative links, and a return-to-contents link after each table. Ensure Markdown renders in GitHub and VS Code.
8. **Validate and deliver.** Verify every table and column is represented, categorical dictionaries are present where relevant, image paths work, relationships and grain agree with known sources, no placeholder claims are presented as verified, and ZIP opens successfully. Run `scripts/validate_data_card.py` or equivalent. Score with `references/QUALITY_GATE.md`; revise until at least 9.5/10 where supported. **Never report an unsupported score.** Link the ZIP in the final response.

## Document presentation exclusions

- **Do not include a dedicated origins/provenance/traceability/sourcing section or an introductory explanation of which files were inspected.** Keep the document focused on the data model and business understanding.
- **Do not add a conspicuous warning banner announcing that the dataset is not real commercial data.** State the dataset type accurately and neutrally in overview metadata if needed; never misrepresent generated values as actual transactions.
- Do not place repetitive image-authenticity captions under each table. A sourced preview should simply be labeled `First five records`. If no data file exists, the graphic itself must clearly say `Preview unavailable`.
- Do not fill missing values or categories by imagination; do not claim independently checked statistics without having checked them.

## How to use the bundled generator

The Python script is a **deterministic scaffold**, not a replacement for semantic analysis. For comprehensive quality, the agent should enrich its `manifest.json` with exact column meanings, categories and definitions, relationships, business narrative, and observed data quality findings.

```bash
python scripts/generate_data_card.py \
  --manifest /path/to/manifest.json \
  --data-dir /path/to/csv-or-parquet \
  --out /path/to/output_folder \
  --count-rows --scan-categories --zip
```

Requirements: Python 3.9+, `Pillow`, `pandas`; `pyarrow` or `polars` for Parquet; optional system Graphviz `dot` for diagrams. Use the included example manifest as a schema illustration only. When actual tables exist, always render table previews from them rather than a substitute.

## Supporting references

- `references/CONTENT_BLUEPRINT.md` — section order and per-table completeness.
- `references/VISUAL_SYSTEM.md` — unified visual theme and asset specifications.
- `references/QUALITY_GATE.md` — measurable 10-point acceptance criteria.
- `references/FINPAY_STYLE_EXAMPLE.md` — sanitized structural example from the FinPay card; **never transplant its numerical facts into unrelated projects**.
- `examples/manifest.example.json` — declarative schema for the generator.
