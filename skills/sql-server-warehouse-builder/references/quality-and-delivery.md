# Candidate selection, quality gate, and delivery

When generating a database script or building the skill itself, consider three levels:

- **A. Minimal DDL-only:** Quick but lacks automated ETL reliability; appropriate only for a demonstrably one-off schema exercise.
- **B. Balanced production pattern:** Correct DDL + transactional ETL + essential validations + post-load reconciliation; default for most analytics projects.
- **C. Financial/regulated extension:** Balanced plus posting-level audit, exact financial reconciliation, approved correction process and deployment controls; essential when moving or accounting for money.

Select B by default, or C where warranted. Never artificially inflate validation solely to look thorough. Give qualitative 0–10 ratings, then compute the weighted score below. Score **>9.5** to release; if below, revise. This is a quality-review heuristic, not a formal guarantee and not a claim of SQL execution.

| Category | Weight | A 10/10 means |
|---|---:|---|
| Data-contract fidelity | 20% | Every input/output column and grain is grounded; no invented fields/statuses |
| SQL Server correctness | 20% | Valid T-SQL batches, types, constraints, no hazardous syntax patterns |
| Data integrity / financial safety | 20% | Safe immutability, financial exactness, FK validity, correct time/Fx semantics |
| Idempotence / transaction safety | 15% | Repeatability, controlled updates, rollback, concurrency, no silent deletions |
| Reusability | 10% | No project-specific counts; parameterized and adapts to varied domains |
| Performance proportionality | 5% | Lean checks, indexes and batch size matched to actual data and workload |
| Testability / observability | 5% | Explicit QA cases and load audit/summary; no false test claims |
| Clarity / developer usability | 5% | Small coherent scripts and explanations, actionable error messages |

Weighted score = SUM(weight × category_score) / 100. A very high score cannot override a critical blocker: lost money, wrong financial sign, unsafe updates, broken SQL syntax, or invented source schema are **automatic fail** irrespective of numeric score.

## Output contract (for the established one-table interaction)

1. A short design decision: grain, SCD policy, original columns and type mappings, added technical columns, references, mode (full snapshot/CDC), assumptions.
2. **SQL script 1:** DDL, suitable for direct review in SSMS. If target already exists with an incompatible schema, stop/propose migration rather than silently returning success.
3. **SQL script 2:** `CREATE OR ALTER PROCEDURE`, and `GO` followed by `EXEC dbo.usp_Load...` in the **same script**. No third SQL code block. This contract is a user preference, not an SQL requirement.
4. Concise explanation of what is validated, what is deliberately not validated, and what the procedure returns.
5. State SQL was **not executed** if no SQL Server connection/test was performed. Provide the suggested next table/dependency and request confirmation only if needed.

If user asks for actual `.sql` files, write two files and link them. If asked for entire database, use dependency-ordered file names (`001_...` etc.) plus optional migration runner only if authorized.

## Revision and feedback loop

- Validate syntax and exact source columns first; scores are meaningless if a script cannot compile or invents data.
- If nonfinancial ETL is overvalidated, remove redundant checks and add succinct tests instead.
- If financial ETL underchecks, restore sign, source-event and balance controls.
- If SCD2 fact joins have undocumented baseline mapping, correct before release.
- If code includes hard-coded dates, counts, money scaling or status strings not in contract, parameterize or obtain source evidence.
- When runtime tests cannot be run, score only design/static evidence; explicitly record untested execution as a limitation.
