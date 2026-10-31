#!/usr/bin/env bash
# Usage: bash sql/load.sh 'postgresql://user:password@localhost:5432/finpay'
set -euo pipefail
: "${1:?Pass a PostgreSQL DSN as first argument}"
DB="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
psql "$DB" -v ON_ERROR_STOP=1 -f "$ROOT/sql/schema.sql"
for table in dim_currency dim_market dim_gateway dim_merchant dim_customer dim_date fact_fx_rate fact_payment_intent fact_payment_attempt fact_dispute fact_fee fact_refund fact_settlement fact_merchant_ledger; do
 echo "Loading $table"
 gzip -cd "$ROOT/data/${table}.csv.gz" | psql "$DB" -v ON_ERROR_STOP=1 -c "\copy finpay.${table} FROM STDIN WITH (FORMAT csv, HEADER true, NULL '')"
done
psql "$DB" -v ON_ERROR_STOP=1 -f "$ROOT/sql/analytics_views.sql"
echo 'Imported operational tables. Verify FX coverage before reporting global USD metrics.'
