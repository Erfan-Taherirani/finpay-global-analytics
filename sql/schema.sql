-- FinPay Global PostgreSQL 14+ schema. Create tables in dependency order.
-- Values in *_minor fields are integer minor currency units, never USD unless currency_code='USD'.
CREATE SCHEMA IF NOT EXISTS finpay;
SET search_path TO finpay;

CREATE TABLE dim_currency (
 currency_code CHAR(3) PRIMARY KEY,
 minor_units SMALLINT NOT NULL CHECK (minor_units BETWEEN 0 AND 3),
 currency_name TEXT NOT NULL
);
CREATE TABLE dim_market (
 country_code CHAR(2) PRIMARY KEY,
 market_name TEXT NOT NULL,
 currency_code CHAR(3) NOT NULL REFERENCES dim_currency(currency_code),
 timezone TEXT NOT NULL
);
CREATE TABLE dim_gateway (
 gateway_id SMALLINT PRIMARY KEY,
 gateway_name TEXT NOT NULL UNIQUE,
 home_region TEXT NOT NULL,
 is_enabled BOOLEAN NOT NULL
);
CREATE TABLE dim_merchant (
 merchant_id BIGINT PRIMARY KEY,
 merchant_name TEXT NOT NULL,
 country_code CHAR(2) NOT NULL REFERENCES dim_market(country_code),
 industry TEXT NOT NULL CHECK (industry IN ('retail','electronics','travel','subscriptions','food','services')),
 onboarded_at TIMESTAMPTZ NOT NULL,
 settlement_currency CHAR(3) NOT NULL REFERENCES dim_currency(currency_code),
 pricing_tier TEXT NOT NULL CHECK(pricing_tier IN ('starter','growth','enterprise')),
 payout_frequency TEXT NOT NULL CHECK(payout_frequency IN ('weekly','monthly')),
 account_status TEXT NOT NULL CHECK(account_status IN ('active','paused','closed'))
);
CREATE TABLE dim_customer (
 customer_id BIGINT PRIMARY KEY,
 signed_up_at TIMESTAMPTZ NOT NULL,
 country_code CHAR(2) NOT NULL REFERENCES dim_market(country_code),
 acquisition_channel TEXT NOT NULL CHECK(acquisition_channel IN ('organic','paid_search','social','referral','partner')),
 is_verified BOOLEAN NOT NULL
);
CREATE TABLE dim_date (
 date_key INTEGER PRIMARY KEY,
 date_utc DATE NOT NULL UNIQUE,
 year SMALLINT NOT NULL,
 month SMALLINT NOT NULL CHECK(month BETWEEN 1 AND 12),
 year_month CHAR(7) NOT NULL,
 day_of_week SMALLINT NOT NULL CHECK(day_of_week BETWEEN 0 AND 6),
 is_weekend BOOLEAN NOT NULL
);
CREATE TABLE fact_payment_intent (
 intent_id BIGINT PRIMARY KEY,
 merchant_id BIGINT NOT NULL REFERENCES dim_merchant(merchant_id),
 customer_id BIGINT REFERENCES dim_customer(customer_id),
 order_reference TEXT NOT NULL UNIQUE,
 created_at TIMESTAMPTZ NOT NULL,
 buyer_country CHAR(2) NOT NULL REFERENCES dim_market(country_code),
 checkout_channel TEXT NOT NULL CHECK(checkout_channel IN ('web','mobile_web','app')),
 presentment_currency CHAR(3) NOT NULL REFERENCES dim_currency(currency_code),
 amount_minor BIGINT NOT NULL CHECK(amount_minor>0),
 final_outcome TEXT NOT NULL CHECK(final_outcome IN ('succeeded','failed','abandoned','pending')),
 closed_at TIMESTAMPTZ,
 captured_at TIMESTAMPTZ,
 captured_settlement_minor BIGINT,
 CHECK ((final_outcome='succeeded')=(captured_at IS NOT NULL AND captured_settlement_minor IS NOT NULL)),
 CHECK ((final_outcome='pending')=(closed_at IS NULL)),
 CHECK (captured_at IS NULL OR captured_at>=created_at),
 CHECK (captured_settlement_minor IS NULL OR captured_settlement_minor=amount_minor)
);
CREATE TABLE fact_payment_attempt (
 attempt_id BIGINT PRIMARY KEY,
 intent_id BIGINT NOT NULL REFERENCES fact_payment_intent(intent_id),
 gateway_id SMALLINT NOT NULL REFERENCES dim_gateway(gateway_id),
 attempt_number SMALLINT NOT NULL CHECK(attempt_number BETWEEN 1 AND 3),
 started_at TIMESTAMPTZ NOT NULL,
 finished_at TIMESTAMPTZ,
 payment_method TEXT NOT NULL CHECK(payment_method IN ('card','wallet','bank_debit')),
 outcome TEXT NOT NULL CHECK(outcome IN ('succeeded','failed','pending')),
 failure_reason TEXT,
 latency_ms INTEGER,
 UNIQUE(intent_id,attempt_number),
 CHECK ((outcome='pending')=(finished_at IS NULL)),
 CHECK ((outcome='failed')=(failure_reason IS NOT NULL)),
 CHECK ((outcome='pending')=(latency_ms IS NULL)),
 CHECK (latency_ms IS NULL OR latency_ms>=0)
);
CREATE TABLE fact_dispute (
 dispute_id BIGINT PRIMARY KEY,
 intent_id BIGINT NOT NULL UNIQUE REFERENCES fact_payment_intent(intent_id),
 opened_at TIMESTAMPTZ NOT NULL,
 resolved_at TIMESTAMPTZ,
 status TEXT NOT NULL CHECK(status IN ('open','won','lost')),
 reason TEXT NOT NULL CHECK(reason IN ('fraud','product_not_received','unrecognized','duplicate')),
 disputed_amount_minor BIGINT NOT NULL CHECK(disputed_amount_minor>0),
 settlement_debit_minor BIGINT,
 CHECK ((status='open')=(resolved_at IS NULL)),
 CHECK ((status='lost')=(settlement_debit_minor IS NOT NULL)),
 CHECK (resolved_at IS NULL OR resolved_at>=opened_at)
);
CREATE TABLE fact_fee (
 fee_id BIGINT PRIMARY KEY,
 intent_id BIGINT NOT NULL REFERENCES fact_payment_intent(intent_id),
 dispute_id BIGINT REFERENCES fact_dispute(dispute_id),
 assessed_at TIMESTAMPTZ NOT NULL,
 fee_type TEXT NOT NULL CHECK(fee_type IN ('merchant_fee','processor_cost','dispute_fee')),
 amount_settlement_minor BIGINT NOT NULL CHECK(amount_settlement_minor>=0),
 CHECK ((fee_type='dispute_fee')=(dispute_id IS NOT NULL))
);
CREATE TABLE fact_refund (
 refund_id BIGINT PRIMARY KEY,
 intent_id BIGINT NOT NULL REFERENCES fact_payment_intent(intent_id),
 requested_at TIMESTAMPTZ NOT NULL,
 completed_at TIMESTAMPTZ,
 status TEXT NOT NULL CHECK(status IN ('succeeded','failed','pending')),
 reason TEXT NOT NULL CHECK(reason IN ('customer_request','product_return','service_issue','duplicate')),
 amount_minor BIGINT NOT NULL CHECK(amount_minor>0),
 settlement_debit_minor BIGINT,
 CHECK ((status='pending')=(completed_at IS NULL)),
 CHECK ((status='succeeded')=(settlement_debit_minor IS NOT NULL)),
 CHECK (completed_at IS NULL OR completed_at>=requested_at)
);
CREATE TABLE fact_settlement (
 settlement_id BIGINT PRIMARY KEY,
 merchant_id BIGINT NOT NULL REFERENCES dim_merchant(merchant_id),
 currency_code CHAR(3) NOT NULL REFERENCES dim_currency(currency_code),
 initiated_at TIMESTAMPTZ NOT NULL,
 scheduled_at TIMESTAMPTZ NOT NULL,
 completed_at TIMESTAMPTZ,
 status TEXT NOT NULL CHECK(status IN ('completed','pending','failed')),
 amount_minor BIGINT NOT NULL CHECK(amount_minor>0),
 failure_reason TEXT,
 CHECK ((status='completed')=(completed_at IS NOT NULL)),
 CHECK ((status='failed')=(failure_reason IS NOT NULL)),
 CHECK (scheduled_at>=initiated_at),
 CHECK (completed_at IS NULL OR completed_at>=initiated_at)
);
CREATE TABLE fact_merchant_ledger (
 entry_id BIGINT PRIMARY KEY,
 merchant_id BIGINT NOT NULL REFERENCES dim_merchant(merchant_id),
 currency_code CHAR(3) NOT NULL REFERENCES dim_currency(currency_code),
 posted_at TIMESTAMPTZ NOT NULL,
 event_type TEXT NOT NULL CHECK(event_type IN ('capture_credit','merchant_fee_debit','refund_debit','dispute_debit','dispute_fee_debit','payout_debit')),
 source_id BIGINT NOT NULL,
 signed_amount_minor BIGINT NOT NULL CHECK(signed_amount_minor<>0),
 CHECK ((event_type='capture_credit')=(signed_amount_minor>0))
);
CREATE TABLE fact_fx_rate (
 rate_date DATE NOT NULL,
 currency_code CHAR(3) NOT NULL REFERENCES dim_currency(currency_code),
 usd_per_major_unit NUMERIC(24,12) NOT NULL CHECK(usd_per_major_unit>0),
 observation_date DATE NOT NULL CHECK(observation_date<=rate_date),
 provider TEXT NOT NULL,
 rate_status TEXT NOT NULL CHECK(rate_status IN ('identity','observed','carried_forward')),
 PRIMARY KEY(rate_date,currency_code)
);
CREATE INDEX idx_intent_merchant_time ON fact_payment_intent(merchant_id,created_at);
CREATE INDEX idx_intent_capture ON fact_payment_intent(captured_at) WHERE final_outcome='succeeded';
CREATE INDEX idx_attempt_gateway_finish ON fact_payment_attempt(gateway_id,finished_at);
CREATE INDEX idx_attempt_intent ON fact_payment_attempt(intent_id);
CREATE INDEX idx_fee_intent ON fact_fee(intent_id);
CREATE INDEX idx_refund_intent ON fact_refund(intent_id);
CREATE INDEX idx_dispute_intent ON fact_dispute(intent_id);
CREATE INDEX idx_settlement_merchant_time ON fact_settlement(merchant_id,completed_at);
CREATE INDEX idx_ledger_merchant_posted ON fact_merchant_ledger(merchant_id,posted_at);
