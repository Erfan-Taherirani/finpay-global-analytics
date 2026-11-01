# FinPay-style visual system — applied generically

## Palette

| Role | Hex |
|---|---|
| Deep navy hero / heading bands | `#081B32` |
| Dark indigo | `#102742` |
| Bright cyan accent | `#20A7E8` |
| Teal dimension accent | `#0F9C92` |
| Periwinkle fact accent | `#748BD4` |
| Light canvas | `#F6FBFF` |
| Alternate row | `#EAF3F8` |
| Muted copy | `#617B91` |
| White | `#FFFFFF` |

## Asset composition

- `header.png`: 1800×460; abstract finance/data-network motifs, visible title and subtitle; never include original dataset's name when generating a different project.
- `relationship_map.png`: group dimension and fact nodes into soft-colored regions; left-to-right flow; distinguish optional relationships using dashed arrows if supported. Favor readability over decorative linework.
- `<table>.png`: 1600×650; dark navy band with table name, teal/periwinkle accent depending on role; top 3–5 genuine records; top 6 columns maximum for legibility and footer noting visible subset. No fabricated values.
- Consistent fonts, spacing, row heights, background and headings across every asset; use high contrast and single accent palette.
- Tables with sensitive identifiers or personal fields: explicitly omit/obfuscate those fields in previews using `preview_exclude` and document the limitation neutrally.
- Diagrams must show only verified/inferred-flagged relationships; no edge inferred solely from similarly named columns.

## Markdown styling

- One `#` title, `##` main sections, `###` table subsections.
- Use compact metadata tables and one comprehensive dictionary per table.
- Prefer highly informative explanatory paragraphs over verbose marketing prose.
- A TOC that works in GitHub, with stable explicit anchors.
- Avoid empty decorations, giant tables with unbounded category values and screenshots of text that belongs in Markdown.
