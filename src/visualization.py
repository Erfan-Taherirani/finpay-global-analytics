import numpy as np
import polars as pl
import matplotlib.pyplot as plt
import seaborn as sns


def plot_total_attempts_by_payment_method_analysis(fact_payment_attempt):
    # calculating parameters
    total_bank_debit_attempts = fact_payment_attempt.filter(
        pl.col("payment_method") == "bank_debit"
    ).shape[0]

    total_card_attempts = fact_payment_attempt.filter(
        pl.col("payment_method") == "card"
    ).shape[0]

    total_wallet_attempts = fact_payment_attempt.filter(
        pl.col("payment_method") == "wallet"
    ).shape[0]

    fact_payment_attempt_debit = fact_payment_attempt.filter(
        pl.col('payment_method') == 'bank_debit'
    ).group_by("outcome").agg(
        (pl.len() / total_bank_debit_attempts * 100).alias("percent")
    )

    fact_payment_attempt_card = fact_payment_attempt.filter(
        pl.col('payment_method') == 'card'
    ).group_by("outcome").agg(
        (pl.len() / total_card_attempts * 100).alias("percent")
    )

    fact_payment_attempt_wallet = fact_payment_attempt.filter(
        pl.col('payment_method') == 'wallet'
    ).group_by("outcome").agg(
        (pl.len() / total_wallet_attempts * 100).alias("percent")
    )

    total_attempts_by_payment_method_pcn = {}
    for payment_method in ["bank_debit", "card", "wallet"]:
        total_attempts_by_payment_method_pcn[payment_method] = fact_payment_attempt.group_by(
            "payment_method"
            ).agg(
                (pl.col('attempt_id').count() / fact_payment_attempt.shape[0] * 100).alias("percent")
            ).filter(
                pl.col('payment_method') == payment_method
            )['percent'].to_list()[0]

    outcomes_pcn = {}
    for payment_method in ["bank_debit", "card", "wallet"]:
        for outcome in ["succeeded", "failed", "pending"]:
            outcomes_pcn[f"{payment_method}_{outcome}"] = fact_payment_attempt.filter(
                pl.col('payment_method') == payment_method
            ).group_by(
                "outcome"
                ).agg(
                    (pl.col('attempt_id').count() / fact_payment_attempt.filter(
                        pl.col('payment_method') == payment_method
                    ).shape[0] * 100).alias("percent")
                ).filter(
                    pl.col('outcome') == outcome
                )['percent'].to_list()[0]

    fig = plt.figure(figsize=(10, 10))

    fig.add_subplot(211)
    sns.countplot(
		data=fact_payment_attempt.to_pandas(),
		x="payment_method",
		stat="percent"
	)
    
    plt.text(0, 22, f"{total_attempts_by_payment_method_pcn['bank_debit']:.2f}%", ha="center", va="center")
    plt.text(1, 34, f"{total_attempts_by_payment_method_pcn['card']:.2f}%", ha="center", va="center")
    plt.text(2, 56, f"{total_attempts_by_payment_method_pcn['wallet']:.2f}%", ha="center", va="center")
    
    plt.ylim(0, 100)
    plt.title("Total Attempts by Payment Method")
    plt.xlabel("Payment Method")
    plt.ylabel("Percentage")
    plt.grid(True, axis="y", linestyle="--", alpha=0.3)
    plt.tight_layout()
    
    fig.add_subplot(234)
    sns.barplot(
		fact_payment_attempt_debit.to_pandas(),
		x="outcome",
		y="percent",
		color="green"
	)
    
    plt.text(0, 86, f"{outcomes_pcn['bank_debit_succeeded']:.2f}%", ha="center", va="center")
    plt.text(1, 22, f"{outcomes_pcn['bank_debit_failed']:.2f}%", ha="center", va="center")
    plt.text(2, 4, f"{outcomes_pcn['bank_debit_pending']:.2f}%", ha="center", va="center")
    
    plt.ylim(0, 100)
    plt.title("Bank Debit by Outcome")
    plt.xlabel("Outcome")
    plt.ylabel("Percentage")
    plt.grid(True, axis="y", linestyle="--", alpha=0.3)
    plt.tight_layout()
    
    fig.add_subplot(235)
    sns.barplot(
		fact_payment_attempt_card.to_pandas(),
		x="outcome",
		y="percent",
		color="orange"
	)
    
    plt.text(0, 87, f"{outcomes_pcn['card_succeeded']:.2f}%", ha="center", va="center")
    plt.text(1, 19, f"{outcomes_pcn['card_failed']:.2f}%", ha="center", va="center")
    plt.text(2, 4, f"{outcomes_pcn['card_pending']:.2f}%", ha="center", va="center")
    
    plt.ylim(0, 100)
    plt.title("Card by Outcome")
    plt.xlabel("Outcome")
    plt.ylabel("Percentage")
    plt.grid(True, axis="y", linestyle="--", alpha=0.3)
    plt.tight_layout()
    
    fig.add_subplot(236)
    sns.barplot(
		fact_payment_attempt_wallet.to_pandas(),
		x="outcome",
		y="percent",
		color="black"
	)
    
    plt.text(0, 93, f"{outcomes_pcn['wallet_succeeded']:.2f}%", ha="center", va="center")
    plt.text(1, 15, f"{outcomes_pcn['wallet_failed']:.2f}%", ha="center", va="center")
    plt.text(2, 4, f"{outcomes_pcn['wallet_pending']:.2f}%", ha="center", va="center")
    
    plt.ylim(0, 100)
    plt.title("Wallet by Outcome")
    plt.xlabel("Outcome")
    plt.ylabel("Percentage")
    plt.grid(True, axis="y", linestyle="--", alpha=0.3)
    plt.tight_layout()
