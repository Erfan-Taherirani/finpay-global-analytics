from pathlib import Path

import polars as pl
import polars.selectors as cs


def load_data() -> dict:
	# Load source tables lazily; transformations execute when collected.
	# load data
	dim_currency = pl.scan_csv(source="../data/raw/dim_currency.csv")

	dim_market = pl.scan_csv(source="../data/raw/dim_market.csv")

	dim_gateway = pl.scan_csv(
		source="../data/raw/dim_gateway.csv",
		schema_overrides={
			"is_enabled": pl.Int64,
		}
	)

	dim_merchant = pl.scan_csv(
		source="../data/raw/dim_merchant.csv",
		schema_overrides={
			"country_code": pl.Categorical,
			"industry": pl.Categorical,
			"onboarded_at": pl.Datetime,
			"settlement_currency": pl.Categorical,
			"pricing_tier": pl.Categorical,
			"payout_frequency": pl.Categorical,
			"account_status": pl.Categorical
		}
	)

	dim_customer = pl.scan_csv(
		source="../data/raw/dim_customer.csv",
		schema_overrides={
			"signed_up_at": pl.Datetime,
			"country_code": pl.Categorical,
			"acquisition_channel": pl.Categorical,
			"is_verified": pl.Categorical,
		}
	)

	# Derive calendar fields for time-based reporting.
	dim_date = pl.scan_csv(
		source="../data/raw/dim_date.csv",
		schema_overrides={
			"date_utc": pl.Datetime
		}
	).select(
		pl.col('date_key'),
		pl.col('date_utc'),
		pl.col('date_utc').dt.year().alias('year'),
		pl.col('date_utc').dt.month().alias('month'),
		pl.col('date_utc').dt.day().alias('day_of_month'),
		pl.col('date_utc').dt.week().alias('week'),
		pl.col('date_utc').dt.weekday().alias('day_of_week'),
		pl.col('date_utc').dt.is_business_day().alias('is_business_day'),
		pl.col('date_utc').dt.month_start().alias('month_start'),
		pl.col('date_utc').dt.month_end().alias('month_end'),
		pl.col('is_weekend').cast(pl.Boolean)
	)

	# Load historical exchange rates used for USD conversions.
	fact_fx_rate = pl.scan_csv(
		source="../data/raw/fact_fx_rate.csv.gz",
		schema_overrides={
			"rate_date": pl.Datetime,
			"currency_code": pl.Categorical,
			"observation_date": pl.Datetime,
			"provider": pl.Categorical,
			"rate_status": pl.Categorical
		}
		)

	# calculate currencies that need to be fixed
	currencies_to_fix = dim_currency.collect().filter(
		pl.col('minor_units') == 2
		)['currency_code'].unique().to_list()

	# Calculate major-unit amounts, payment durations, and USD values.
	fact_payment_intent = pl.scan_csv(
		source="../data/raw/fact_payment_intent.csv",
		schema_overrides={
			"created_at": pl.Datetime,
			"buyer_country": pl.Categorical,
			"checkout_channel": pl.Categorical,
			"presentment_currency": pl.Categorical,
			"final_outcome": pl.Categorical,
			"closed_at": pl.Datetime,
			"captured_at": pl.Datetime,
			"captured_settlement_minor": pl.Int64,
		}
	).with_columns(
		# calculate the amount in major for currencies that need to be fixed
		pl.when(
			pl.col('presentment_currency').is_in(currencies_to_fix)
		).then(
			pl.col('amount_minor') / 100
		).otherwise(
			pl.col('amount_minor')
		).alias('amount_major'),
		pl.when(
			pl.col('presentment_currency').is_in(currencies_to_fix)
		).then(
			pl.col('captured_settlement_minor') / 100
		).otherwise(
			pl.col('captured_settlement_minor')
		).alias('captured_settlement_major'),
		# calculate the time differences
		(pl.col('captured_at') - pl.col('created_at')).dt.total_seconds().alias('time_to_capture'),
		(pl.col('closed_at') - pl.col('created_at')).dt.total_seconds().alias('payment_resolution_time')
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('created_at').dt.date(), pl.col('presentment_currency')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).select(
		pl.col('intent_id'),
		pl.col('merchant_id'),
		pl.col('customer_id'),
		pl.col('created_at'),
		pl.col('buyer_country'),
		pl.col('checkout_channel'),
		pl.col('presentment_currency'),
		pl.col('final_outcome'),
		pl.col('closed_at'),
		pl.col('captured_at'),
		pl.col('amount_major'),
		pl.col('captured_settlement_major'),
		pl.col('payment_resolution_time'),
		pl.col('time_to_capture'),
		(pl.col('amount_major') * pl.col('usd_per_major_unit')).alias("amount_major_usd"),
		(pl.col('captured_settlement_major') * pl.col('usd_per_major_unit')).alias("captured_settlement_major_usd")
	)

	# Load individual payment attempts with explicit column types.
	fact_payment_attempt = pl.scan_csv(
		source="../data/raw/fact_payment_attempt.csv",
		schema_overrides={
			"attempt_number": pl.Categorical,
			"started_at": pl.Datetime,
			"finished_at": pl.Datetime,
			"payment_method": pl.Categorical,
			"outcome": pl.Categorical,
			"failure_reason": pl.Categorical
		}
	)

	# Join fees to payment/merchant details; convert using assessment-date FX.
	fact_fee = pl.scan_csv(
		source="../data/raw/fact_fee.csv",
		schema_overrides={
			"dispute_id": pl.Int64,
			"assessed_at": pl.Datetime,
			"fee_type": pl.Categorical
		}
	).join(
		other=fact_payment_intent,
		on="intent_id",
		how="left"
	).join(
        other=dim_merchant,
        on="merchant_id",
        how="left"
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('assessed_at').dt.date(), pl.col('settlement_currency')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).select(
        pl.col('fee_id'),
        pl.col('intent_id'),
        pl.col('dispute_id'),
        pl.col('assessed_at'),
        pl.col('fee_type'),
		pl.col('settlement_currency'),
        pl.col('usd_per_major_unit'),
        pl.when(
			pl.col("settlement_currency").is_in(currencies_to_fix)
		).then(
			pl.col("amount_settlement_minor") / 100
		).otherwise(
			pl.col("amount_settlement_minor")
		).alias("amount_settlement_major")
	).select(
		pl.all().exclude('usd_per_major_unit'),
		(pl.col('amount_settlement_major') * pl.col('usd_per_major_unit')).alias("amount_settlement_major_usd")
	)

	# Compute refund durations and amounts; fall back to request-date FX.
	fact_refund = pl.scan_csv(
		source="../data/raw/fact_refund.csv",
		schema_overrides={
			"requested_at": pl.Datetime,
			"completed_at": pl.Datetime,
			"status": pl.Categorical,
			"reason": pl.Categorical
		}
	).join(
		other=fact_payment_intent,
		on="intent_id",
		how="left"
	).join(
        other=dim_merchant,
        on="merchant_id",
        how="left"
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('completed_at').dt.date(), pl.col('settlement_currency')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).select(
		cs.by_name('refund_id'),
		cs.by_name('intent_id'),
		cs.by_name('requested_at'),
		cs.by_name('completed_at'),
		(pl.col('completed_at') - pl.col('requested_at')).dt.total_minutes().alias("minutes_to_refund"),
		cs.by_name('status'),
		cs.by_name('reason'),
		cs.by_name('usd_per_major_unit'),
		cs.by_name('settlement_currency').alias("currency_code"),
		pl.when(
			pl.col("settlement_currency").is_in(currencies_to_fix)
		).then(
			pl.col("amount_minor") / 100
		).otherwise(
			pl.col("amount_minor")
		).alias("amount_major"),
		pl.when(
			pl.col("settlement_currency").is_in(currencies_to_fix)
		).then(
			pl.col("settlement_debit_minor") / 100
		).otherwise(
			pl.col("settlement_debit_minor")
		).alias("settlement_debit_major"),
	).select(
		pl.all().exclude('usd_per_major_unit'),
		(pl.col('amount_major') * pl.col('usd_per_major_unit')).alias("amount_major_usd"),
		(pl.col('settlement_debit_major') * pl.col('usd_per_major_unit')).alias("settlement_debit_major_usd")
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('requested_at').dt.date(), pl.col('currency_code')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).select(
        pl.all().exclude(
			'amount_major_usd',
            'rate_date',
			'currency_code_right',
			'usd_per_major_unit',
            'observation_date',
			'provider',
            'rate_status'
		),
        pl.when(
            pl.col('amount_major_usd').is_null(),
		).then(
            (pl.col('amount_major') * pl.col('usd_per_major_unit'))
		).otherwise(
            pl.col('amount_major_usd')
		).alias("amount_major_usd")
	)

	# Compute dispute durations and amounts; fall back to opening-date FX.
	fact_dispute = pl.scan_csv(
		source="../data/raw/fact_dispute.csv",
		schema_overrides={
			"opened_at": pl.Datetime,
			"resolved_at": pl.Datetime,
			"status": pl.Categorical,
			"reason": pl.Categorical
		}
	).join(
		other=fact_payment_intent,
		on="intent_id",
		how="left"
	).join(
        other=dim_merchant,
        on="merchant_id",
        how="left"
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('resolved_at').dt.date(), pl.col('settlement_currency')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).select(
		cs.by_name('dispute_id'),
		cs.by_name('intent_id'),
		cs.by_name('opened_at'),
		cs.by_name('resolved_at'),
		(pl.col('resolved_at') - pl.col('opened_at')).dt.total_minutes().alias("minutes_to_resolve"),
		cs.by_name('status'),
		cs.by_name('reason'),
		cs.by_name('settlement_currency').alias("currency_code"),
		cs.by_name('usd_per_major_unit'),
		pl.when(
			cs.by_name('settlement_currency').is_in(currencies_to_fix)
		).then(
			cs.by_name('disputed_amount_minor') / 100
		).otherwise(
			pl.col('disputed_amount_minor')
		).alias("disputed_amount_major"),
		pl.when(
			cs.by_name('settlement_currency').is_in(currencies_to_fix)
		).then(
			cs.by_name('settlement_debit_minor') / 100
		).otherwise(
			pl.col('settlement_debit_minor')
		).alias("settlement_debit_major")
	).select(
		pl.all().exclude('usd_per_major_unit'),
		(pl.col('disputed_amount_major') * pl.col('usd_per_major_unit')).alias("disputed_amount_major_usd"),
		(pl.col('settlement_debit_major') * pl.col('usd_per_major_unit')).alias("settlement_debit_major_usd")
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('opened_at').dt.date(), pl.col('currency_code')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).select(
        pl.all().exclude(
			'disputed_amount_major_usd',
            'rate_date',
			'currency_code_right',
			'usd_per_major_unit',
            'observation_date',
			'provider',
            'rate_status'
		),
        pl.when(
            pl.col('disputed_amount_major_usd').is_null(),
		).then(
            (pl.col('disputed_amount_major') * pl.col('usd_per_major_unit'))
		).otherwise(
            pl.col('disputed_amount_major_usd')
		).alias("disputed_amount_major_usd")
	)

	# Calculate payout timing and USD values; fall back to scheduled-date FX.
	fact_settlement = pl.scan_csv(
		source="../data/raw/fact_settlement.csv",
		schema_overrides={
			"currency_code": pl.Categorical,
			"initiated_at": pl.Datetime,
			"scheduled_at": pl.Datetime,
			"completed_at": pl.Datetime,
			"status": pl.Categorical,
			"failure_reason": pl.Categorical
		}
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('completed_at').dt.date(), pl.col('currency_code')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).with_columns(
		pl.when(
			cs.by_name('currency_code').is_in(currencies_to_fix)
		).then(
			pl.col('amount_minor') / 100
		).otherwise(
			pl.col('amount_minor')
		).alias("amount_major"),
		(pl.col('scheduled_at') - pl.col('initiated_at')).dt.total_seconds().alias("time_to_scheduled_payout"),
		(pl.col('completed_at') - pl.col('initiated_at')).dt.total_seconds().alias("payout_completion_time"),
		(pl.col('scheduled_at') - pl.col('scheduled_at')).dt.total_seconds().alias("schedule_deviation")
	).select(
		pl.col('settlement_id'),
		pl.col('merchant_id'),
		pl.col('currency_code'),
		pl.col('initiated_at'),
		pl.col('scheduled_at'),
		pl.col('completed_at'),
		pl.col('status'),
		pl.col('failure_reason'),
		pl.col('time_to_scheduled_payout'),
		pl.col('payout_completion_time'),
		pl.col('schedule_deviation'),
		pl.col('amount_major'),
		(pl.col('amount_major') * pl.col('usd_per_major_unit')).alias("amount_major_usd")
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('scheduled_at').dt.date(), pl.col('currency_code')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).select(
        pl.all().exclude(
			'amount_major_usd',
            'rate_date',
			'currency_code_right',
			'usd_per_major_unit',
            'observation_date',
			'provider',
            'rate_status'
		),
        pl.when(
            pl.col('amount_major_usd').is_null(),
		).then(
            (pl.col('amount_major') * pl.col('usd_per_major_unit'))
		).otherwise(
            pl.col('amount_major_usd')
		).alias("amount_major_usd")
	)

	# Preserve signed ledger values and convert them using posting-date FX.
	fact_merchant_ledger = pl.scan_csv(
		source="../data/raw/fact_merchant_ledger.csv",
		schema_overrides={
			"currency_code": pl.Categorical,
			"posted_at": pl.Datetime,
			"event_type": pl.Categorical
		}
	).with_columns(
		pl.when(
			pl.col('currency_code').is_in(currencies_to_fix)
		).then(
			pl.col('signed_amount_minor') / 100
		).otherwise(
			pl.col('signed_amount_minor')
		).alias("signed_amount_major")
	).join(
		other=fact_fx_rate,
		left_on=[pl.col('posted_at').dt.date(), pl.col('currency_code')],
		right_on=[pl.col('rate_date').dt.date(), pl.col('currency_code')],
		how="left"
	).select(
		pl.all().exclude(
			'signed_amount_minor',
			'currency_code_right',
			'rate_date',
			'usd_per_major_unit',
			'observation_date',
			'provider',
			'rate_status'
		),
		(pl.col('signed_amount_major') * pl.col('usd_per_major_unit')).alias('signed_amount_major_usd')
	)

	# Expose each prepared table for saving or downstream analysis.
	print("Data loaded")
	return {
		"dim_currency": dim_currency,
		"dim_market": dim_market,
		"dim_gateway": dim_gateway,
		"dim_merchant": dim_merchant,
		"dim_customer": dim_customer,
		"dim_date": dim_date,
		"fact_payment_intent": fact_payment_intent,
		"fact_payment_attempt": fact_payment_attempt,
		"fact_fee": fact_fee,
		"fact_refund": fact_refund,
		"fact_dispute": fact_dispute,
		"fact_settlement": fact_settlement,
		"fact_merchant_ledger": fact_merchant_ledger,
		"fact_fx_rate": fact_fx_rate
	}

def save_processed_data(tables: dict) -> None:
	# Materialize each lazy table before writing it to Parquet.
	output_dir = Path("../data/processed")
	output_dir.mkdir(parents=True, exist_ok=True)

	tables["dim_currency"].collect().write_parquet(output_dir / "dim_currency.parquet")
	tables["dim_market"].collect().write_parquet(output_dir / "dim_market.parquet")
	tables["dim_gateway"].collect().write_parquet(output_dir / "dim_gateway.parquet")
	tables["dim_merchant"].collect().write_parquet(output_dir / "dim_merchant.parquet")
	tables["dim_customer"].collect().write_parquet(output_dir / "dim_customer.parquet")
	tables["dim_date"].collect().write_parquet(output_dir / "dim_date.parquet")
	tables["fact_payment_intent"].collect().write_parquet(output_dir / "fact_payment_intent.parquet")
	tables["fact_payment_attempt"].collect().write_parquet(output_dir / "fact_payment_attempt.parquet")
	tables["fact_fee"].collect().write_parquet(output_dir / "fact_fee.parquet")
	tables["fact_refund"].collect().write_parquet(output_dir / "fact_refund.parquet")
	tables["fact_dispute"].collect().write_parquet(output_dir / "fact_dispute.parquet")
	tables["fact_settlement"].collect().write_parquet(output_dir / "fact_settlement.parquet")
	tables["fact_merchant_ledger"].collect().write_parquet(output_dir / "fact_merchant_ledger.parquet")
	tables["fact_fx_rate"].collect().write_parquet(output_dir / "fact_fx_rate.parquet")
