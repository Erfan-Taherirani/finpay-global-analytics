# Professional Data Card — reusable skill

A portable, instruction-led skill for producing detailed, professionally styled, GitHub-ready data cards. It captures the visual and content pattern of the previously created FinPay card without importing FinPay facts into other datasets.

## What it produces

- A downloadable ZIP containing a Markdown data card, header, relationship map, one first-rows image per table, README and regeneration script.
- Collapsible, clickable table of contents with direct links to every dimension and fact table.
- Executive overview, inventory, lifecycle/grain, keys and relationships, full column-by-column schema, categories and their meaning, amount/time conventions, quality checks, use cases, and maintenance steps.
- Unified navy / teal / periwinkle imagery. Actual file rows are used for previews; where data is unavailable, the illustration clearly says the preview is unavailable.

## Use in a skills-capable AI environment

1. Extract `professional_data_card_skill.zip`.
2. Install the extracted **`professional_data_card_skill`** folder into your environment's agent skills directory, or provide its `SKILL.md` and supporting files in the conversation. The exact directory depends on the product. The skill is a portable file-based agent skill, not an automatically connected ChatGPT plugin.
3. Attach the new dataset's CSV/Parquet files, notebook, SQL schema or data dictionary.
4. Ask: **“Use the professional-data-card skill to create a full data card for this dataset. Return the Markdown and all images in a ZIP.”**

The assistant should inspect the supplied dataset, write an accurate table catalog, and generate the final artifacts. No other dataset's example values should be copied into the output.

## Offline generator (optional)

The bundled generator builds a complete initial document from a structured manifest and available data files:

```bash
pip install pillow pandas pyarrow
python scripts/generate_data_card.py \
  --manifest examples/manifest.example.json \
  --data-dir examples/data \
  --out /tmp/northstar_data_card \
  --scan-categories --count-rows --zip
python scripts/validate_data_card.py /tmp/northstar_data_card \
  --manifest examples/manifest.example.json
```

Install Graphviz (`dot`) for automated relationship image rendering; without it, the DOT file remains available and a neutral placeholder is generated.

The script does not infer nuanced business meanings of column names, statuses or monetary units. Document those in the manifest after examining the actual schema and business rules. The optional `--scan-categories` reads all available records for specifically marked bounded categories; this may be time-consuming on large datasets.

## Included reference materials

- `SKILL.md` — primary instructions for compatible assistants.
- `references/CONTENT_BLUEPRINT.md` — expected document structure and per-table specifications.
- `references/VISUAL_SYSTEM.md` — colors, imagery, typography and layout.
- `references/QUALITY_GATE.md` — 10-point acceptance rubric and checks.
- `references/FINPAY_STYLE_EXAMPLE.md` and `references/finpay_sample_assets/` — original visual/document structure as an example only.
- `scripts/generate_data_card.py` and `scripts/validate_data_card.py` — asset/document generator and validator.
- `examples/manifest.example.json`, `examples/data/*.csv` — runnable smoke-test fixture.

## Working with large datasets

Only a small prefix of each CSV/Parquet table is loaded for preview images. Full category enumeration, if enabled, scans bounded categorical columns in chunks. Use aggregated profiling or a representative sample for very large high-cardinality fields, and do not claim that a sample provides all possible values.
