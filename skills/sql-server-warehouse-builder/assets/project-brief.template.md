# New SQL Server Warehouse Project — Intake

Fill known values only. Do not invent missing facts. The assistant should ask for a missing item only when it changes the current table's correctness.

## Project
- Project name:
- Business questions and KPIs:
- SQL Server edition/version:
- Staging schema (e.g. stg):
- Target schema (e.g. main):
- ETL procedure schema (e.g. dbo):
- Power BI mode (Import/DirectQuery/unknown):
- Dataset dates + source time zone:
- Staging mode (FULL SNAPSHOT / INCREMENTAL / CDC / MIXED):
- Expected dataset size / refresh frequency:
- Financial data? Currency and monetary units:
- Existing tables / loading order:

## Table being implemented
- Source table:
- Target table:
- Grain (what one row means):
- Source business key and uniqueness:
- All **original columns and real types** (attach source DDL/data dictionary or paste names):
- Nullable columns and allowed values:
- Reference dimension/fact tables and join keys:
- Type (static dimension / mutable dimension / event fact / accumulating snapshot / ledger / FX):
- History policy (Type 1, Type 2, immutable, approved correction, etc.):
- SCD effective time (source vs ETL UTC) if Type 2:
- Full snapshot completeness expectation if contractual:
- Backfill strategy for historical facts and SCD2 versions:
- Immutable vs mutable attributes:
- FX direction/date / reporting currency if applicable:
- Desired validation level (lean / financial controls):
- Output format (two scripts, SQL files, full project):
- Permission to execute DDL/ETL on a database (NO unless explicitly granted):
