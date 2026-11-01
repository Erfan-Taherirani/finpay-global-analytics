# Quality gate — 10-point rubric

A documented evaluation, not an automatic claim of excellence. A card can achieve 9.5+ **only when its underlying artifacts allow verification**.

| Criterion | Weight | Full-credit requirement |
|---|---:|---|
| Schema completeness | 2.0 | All source tables and all columns defined, including types, grains and keys |
| Business semantics | 1.5 | Clear entity / event definitions and meaningful, complete category explanations |
| Relationship accuracy | 1.5 | Verified logical/physical links, cardinality, optionality, join-fanout warnings |
| Visual consistency | 1.2 | Branded header, legible diagram, one matching image per table |
| Navigation & accessibility | 1.0 | Functional TOC/anchors, correct image paths, meaningful alt text |
| Factual integrity | 1.2 | No invented values or previews; observed vs unresolved distinctions correctly preserved |
| Quality / operational notes | 0.9 | Specific integrity checks, unit handling, limitations, reproducibility |
| Packaging / reproducibility | 0.7 | Clean ZIP structure and readable README; scripts run in smoke test |
| **Total** | **10.0** | |

A score over 9.5 requires at least 95% of the weighted checks to pass. If missing source data prevents true row previews or full category enumeration, the card may remain useful but should not be claimed to exceed 9.5 without caveat. Do not write a fabricated 9.8/10 in the user-facing response.

## Automated checks

1. ZIP opens and archive contents match paths in the README.
2. Images resolve relative to `data_card.md`.
3. Every table has its own heading and a PNG visual.
4. Every configured field appears in the table's dictionary.
5. Every TOC link resolves to an anchor.
6. There are no duplicate anchors.
7. No unexpected empty tables, missing relationships, or unresolved placeholders masquerading as observations.
8. The excluded stand-alone disclosures/banners do not appear.
9. Source files are never modified by visualization scripts.
10. Record counts, date coverage and FX completeness are labeled as measured only after measurement.
