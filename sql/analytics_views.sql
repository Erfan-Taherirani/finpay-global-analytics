-- Execute after importing verified actual historical FX. This view does not invent FX.
SET search_path TO finpay;
CREATE OR REPLACE VIEW v_captured_payments AS
SELECT i.intent_id,i.merchant_id,i.customer_id,i.buyer_country,(i.captured_at AT TIME ZONE 'UTC')::date capture_date,
       i.presentment_currency currency_code,i.amount_minor, m.industry,m.pricing_tier,
       a.payment_method, a.gateway_id,
       (i.amount_minor::numeric / power(10,c.minor_units)) AS captured_major,
       CASE WHEN f.usd_per_major_unit IS NOT NULL
            THEN (i.amount_minor::numeric / power(10,c.minor_units))*f.usd_per_major_unit
            ELSE NULL END captured_usd
FROM fact_payment_intent i
JOIN dim_merchant m ON m.merchant_id=i.merchant_id
JOIN dim_currency c ON c.currency_code=i.presentment_currency
JOIN fact_payment_attempt a ON a.intent_id=i.intent_id AND a.outcome='succeeded'
LEFT JOIN fact_fx_rate f ON f.currency_code=i.presentment_currency AND f.rate_date=(i.captured_at AT TIME ZONE 'UTC')::date
WHERE i.final_outcome='succeeded';

CREATE OR REPLACE VIEW v_ledger_balances AS
SELECT merchant_id,currency_code,
       sum(signed_amount_minor) AS closing_balance_minor,
       sum(signed_amount_minor) FILTER(WHERE event_type='capture_credit') gross_captured_minor,
       -sum(signed_amount_minor) FILTER(WHERE event_type='merchant_fee_debit') merchant_fees_minor,
       -sum(signed_amount_minor) FILTER(WHERE event_type='refund_debit') refunds_minor,
       -sum(signed_amount_minor) FILTER(WHERE event_type='dispute_debit') lost_disputes_minor,
       -sum(signed_amount_minor) FILTER(WHERE event_type='dispute_fee_debit') dispute_fees_minor,
       -sum(signed_amount_minor) FILTER(WHERE event_type='payout_debit') completed_payouts_minor
FROM fact_merchant_ledger GROUP BY merchant_id,currency_code;
-- When filters encounter missing USD exchange rates, analysts must treat global
-- USD aggregates as UNAVAILABLE. SQL SUM skips NULL; do not use SUM alone without
-- confirming zero unmatched FX lookups.
