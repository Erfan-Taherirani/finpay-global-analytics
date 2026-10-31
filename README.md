# FinPay Global — Synthetic FinTech Analytics Portfolio

**A five-year synthetic international payment-service-provider dataset and reproducible generator.**

## Project contents

```text
docs/    Phase 1 contract, business plan, business questions, KPI definitions, dictionary, benchmark disclosures
src/     Python synthetic event generator and real historical FX importer
sql/     PostgreSQL schema, indexes and example analytics queries
tests/   Data validation and merchant ledger reconciliation
data/    Generated gzip CSV fact/dimension tables plus row-count and FX manifest
```

## Scale and assumptions

1,620,000 payment intents, approximately 1.7–1.9m gateway attempts, 100,000 registered customers, 2,000 merchants, 60 months, 12 markets, 10 transaction currencies, 5 invented providers and approximately 8–10 million aggregate rows. Every payment/event is **synthetic**. All local financial records are denominated in local minor units; US-dollar normalization requires real historical central-bank FX.

**Currency constraint:** 12 markets would imply 11 local currencies. We keep 10 currencies by excluding IRR; fictional Iranian merchant traffic is USD-only and explicitly a sandbox what-if. This does not claim service availability or legal payment routing. Russian market also hypothetical.

**FX availability:** Internet access to import real historical FX was unavailable in the generation environment. To avoid misrepresenting invented exchange rates as historical observations, the generated `fact_fx_rate.csv.gz` contains only the true USD identity rate. **Do not calculate or visualize non-USD TPV or global USD revenue until the historical FX importer has completed.**

## Quick start

```bash
python -m pip install -r requirements.txt
python src/generate.py --intents 1620000 --out data
# Requires Internet; will fail rather than silently invent missing rates:
python src/fetch_fx.py --data-dir data
python tests/validate.py --data-dir data
```

**Do not rerun the generator after importing FX**, because regeneration resets `fact_fx_rate` to USD identity. If you do regenerate, rerun the FX importer.

Import `*.csv.gz` with decompression and PostgreSQL `COPY` using `sql/schema.sql`. For Power BI create SQL views with separate facts and conformed dimensions as detailed in `docs/data_dictionary.md`. Monetary amounts are stored in currency *minor units*; JPY has zero decimals.

## Documentation index

- [Business scenario and plan](docs/business_scenario.md)
- [Core business questions](docs/core_business_questions.md)
- [Phase 1 contract and financial reconciliation](docs/finpay_phase1_spec.md)
- [Field-level data dictionary and relationships](docs/data_dictionary.md)
- [KPI contract](docs/kpi_definitions.md)
- [Benchmark evidence and synthetic assumptions](docs/benchmark_assumptions.md)

## Portfolio integrity

No real transaction data or identity information. Currency reference rates must be real if loaded, observed vs carried-forward dates must be distinguished, and industry benchmarks may inspire modeled patterns but never substantiate the fabricated company's results. There is no regulation, operational network support, tax or audited accounting guarantee.

## PostgreSQL import

Create an empty PostgreSQL database, then run:

```bash
bash sql/load.sh 'postgresql://USER:PASSWORD@localhost:5432/finpay'
```

The loader creates schema `finpay`, imports dimensions in dependency order, then event facts, then analytic views. For larger-than-GitHub projects, **keep generated 200 MB+ data out of normal Git history** (already covered by `.gitignore`), publish the release archive separately, and share the deterministic generator and manifest.
- [Generated dataset counts and QC profile](docs/generated_data_profile.md)
