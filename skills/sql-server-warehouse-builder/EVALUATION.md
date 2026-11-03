# Skill design evaluation

## Alternatives compared

A. **Single reusable prompt:** one long chat instruction, no package or reference files. Easy to copy, but brittle when users need different load modes or monetary logic.

B. **Single SKILL.md only:** discoverable and portable, but all patterns inline; higher context overhead and less detailed reusable implementation guidance.

C. **Modular Agent Skill (selected):** short discoverable manifest, task-specific references, SQL examples, independent-domain walk-through, offline validator and explicit scoring rubric.

## Weighted review (subjective design assessment, not empirical benchmarking)

Based on the rubric in `references/quality-and-delivery.md`, with category weights: contract 20%, SQL correctness 20%, integrity 20%, idempotence/safety 15%, reusability 10%, performance 5%, testability 5%, clarity 5%.

| Category | Weight | A prompt | B one-file | C modular |
|---|---:|---:|---:|---:|
| Data-contract fidelity | 20% | 8.8 | 9.4 | 9.9 |
| SQL Server correctness | 20% | 8.0 | 9.1 | 9.8 |
| Integrity / financial safety | 20% | 7.0 | 9.0 | 9.8 |
| Idempotence / transaction safety | 15% | 7.0 | 9.3 | 9.8 |
| Reusability | 10% | 8.1 | 9.2 | 9.9 |
| Performance proportionality | 5% | 8.0 | 8.8 | 9.6 |
| Testability / observability | 5% | 5.5 | 7.9 | 9.5 |
| Clarity / usability | 5% | 9.0 | 8.7 | 9.7 |
| **Weighted score / 10** | **100%** | **7.75** | **9.09** | **9.80** |

**Selected:** C. Its review score exceeds 9.5, but it is **not** proof that SQL will compile and run for every project. Database connectivity, real source samples, versions and integration tests are still required.

## Verification checklist

- Agent Skills-compatible `SKILL.md` with proper YAML `name`/`description`.
- Exact folder name `sql-server-warehouse-builder` matches frontmatter.
- All local reference links exist.
- SQL patterns show transaction rollback, locks and idempotent no-op behavior.
- SCD2 time semantics and historical fact join ambiguity are called out.
- Original money minor units, status taxonomy and source-provenance requirements are explicitly stated.
- Examples use an **unrelated** retail domain; no FinPay-only counts or status vocab in the skill's mandatory rules.
- Offline file/metadata/smoke check is available.
- Actual SQL Server integration tests: **not executed** (no SQL Server connection supplied).

## Next quality gate for production use

For each new project: inspect real staging metadata; adapt templates to the actual schema; run DDL/procedure in an isolated SQL Server database; test first load, same-data rerun, permissible change, rejected bad data, financial reconciliation, and rollback; record measured outcomes separately from this design review.
