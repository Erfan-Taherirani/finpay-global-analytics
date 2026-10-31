#!/usr/bin/env python3
"""Rigorous lifecycle, PK/FK, cutoff, and per-merchant/currency source-ledger checks.

Memory footprint scales with INTENT and merchant count, not the 9M total rows.
"""
from pathlib import Path
from collections import Counter
import argparse, json
import numpy as np
import pandas as pd

NAMES=['fact_payment_intent','fact_payment_attempt','fact_fee','fact_refund','fact_dispute','fact_settlement','fact_merchant_ledger']
EVENTS=['capture_credit','merchant_fee_debit','refund_debit','dispute_debit','dispute_fee_debit','payout_debit']

def chunks(folder,t,cols=None):
    return pd.read_csv(folder/f'{t}.csv.gz',usecols=cols, chunksize=180000,low_memory=False)

def main(data):
    conf=json.loads((data/'manifest.json').read_text()); n=conf['row_counts']['fact_payment_intent'];m=2000; cutoff=pd.Timestamp('2026-10-01T00:00:00Z')
    as_merchant=np.zeros(n+1,dtype=np.int32); success=np.zeros(n+1,dtype=np.int8); amount=np.zeros(n+1,dtype=np.int64)
    guest_count=0;status_counts=Counter(); sample=[]
    for ch in chunks(data,'fact_payment_intent',['intent_id','merchant_id','customer_id','final_outcome','amount_minor','captured_settlement_minor','created_at','captured_at']):
        z=ch.intent_id.to_numpy(dtype=np.int64)
        assert np.all((z>=1)&(z<=n))
        assert np.all(as_merchant[z]==0),'duplicate payment intent id'
        as_merchant[z]=ch.merchant_id.to_numpy(dtype=np.int32)
        assert np.all((as_merchant[z]>=1)&(as_merchant[z]<=m))
        success[z]=(ch.final_outcome=='succeeded').to_numpy(dtype=np.int8)
        amount[z]=ch.amount_minor.to_numpy(dtype=np.int64)
        assert np.all(amount[z]>0)
        assert np.all(ch.created_at.ge('2021-10-01T00:00:00Z') & ch.created_at.lt('2026-10-01T00:00:00Z'))
        assert ch.loc[ch.final_outcome=='succeeded','captured_settlement_minor'].notna().all()
        assert ch.loc[ch.final_outcome!='succeeded','captured_settlement_minor'].isna().all()
        assert np.array_equal(ch.loc[ch.final_outcome=='succeeded','amount_minor'].to_numpy(dtype='int64'), ch.loc[ch.final_outcome=='succeeded','captured_settlement_minor'].to_numpy(dtype='int64'))
        for key,val in ch.final_outcome.value_counts().items():status_counts[key]+=int(val)
        guest_count+=int(ch.customer_id.isna().sum())
    assert np.count_nonzero(as_merchant)==n
    attempts=np.zeros(n+1,dtype=np.int8); won=np.zeros(n+1,dtype=np.int8); afail=np.zeros(n+1,dtype=np.int8); pending=np.zeros(n+1,dtype=np.int8)
    gateways=np.zeros(6,dtype=np.int64); method_counts=Counter()
    for ch in chunks(data,'fact_payment_attempt',['attempt_id','intent_id','gateway_id','attempt_number','outcome','payment_method','started_at','finished_at','failure_reason']):
        ids=ch.intent_id.to_numpy(dtype=np.int64);assert np.all((ids>=1)&(ids<=n))
        np.add.at(attempts,ids,1)
        np.add.at(won,ids,(ch.outcome=='succeeded').to_numpy(dtype=np.int8))
        np.add.at(afail,ids,(ch.outcome=='failed').to_numpy(dtype=np.int8))
        np.add.at(pending,ids,(ch.outcome=='pending').to_numpy(dtype=np.int8))
        assert (ch.attempt_number.between(1,3)).all()
        assert ch.loc[ch.outcome=='failed','failure_reason'].notna().all()
        assert ch.loc[ch.outcome!='failed','failure_reason'].isna().all()
        assert ch.loc[ch.outcome=='pending','finished_at'].isna().all()
        assert ch.loc[ch.outcome!='pending','finished_at'].notna().all()
        for key,val in ch.payment_method.value_counts().items():method_counts[key]+=int(val)
        for key,val in ch.gateway_id.value_counts().items():gateways[int(key)]+=int(val)
    assert np.all(attempts<=3) and np.all(won<=1)
    assert np.array_equal(won,success),'successful attempts != captured intents'
    assert np.all(attempts[success==1]>=1)
    assert int(np.count_nonzero(attempts[1:]==0))==status_counts['abandoned']
    assert int(np.count_nonzero(pending))==status_counts['pending']
    # Captures and fee source values by merchant, all in local minor units
    local_src={ev:np.zeros(m+1,dtype=np.int64) for ev in EVENTS}
    np.add.at(local_src['capture_credit'],as_merchant[success==1],amount[success==1])
    fee_a=np.zeros(n+1,dtype=np.int8);fee_b=np.zeros(n+1,dtype=np.int8)
    for ch in chunks(data,'fact_fee',['intent_id','fee_type','amount_settlement_minor']):
        ids=ch.intent_id.to_numpy(dtype=np.int64)
        assert np.all(success[ids]==1)
        merch=as_merchant[ids]
        for t,k,b in [('merchant_fee','merchant_fee_debit',fee_a),('processor_cost',None,fee_b),('dispute_fee','dispute_fee_debit',None)]:
            mask=ch.fee_type.to_numpy()==t
            if b is not None:np.add.at(b,ids[mask],1)
            if k:np.add.at(local_src[k],merch[mask],-ch.amount_settlement_minor.to_numpy(dtype=np.int64)[mask])
    assert np.array_equal(fee_a,success) and np.array_equal(fee_b,success)
    refunded=np.zeros(n+1,dtype=np.int64)
    for ch in chunks(data,'fact_refund',['intent_id','status','settlement_debit_minor','amount_minor']):
        ids=ch.intent_id.to_numpy(dtype=np.int64);assert np.all(success[ids]==1)
        succ=ch.status=='succeeded'
        vals=ch.loc[succ,'settlement_debit_minor'].to_numpy(dtype=np.int64)
        assert np.all(vals>0)
        np.add.at(refunded,ids[succ],vals)
        np.add.at(local_src['refund_debit'],as_merchant[ids[succ]],-vals)
    assert np.all(refunded<=amount)
    dispute_found=np.zeros(n+1,dtype=np.int8)
    for ch in chunks(data,'fact_dispute',['intent_id','status','settlement_debit_minor']):
        ids=ch.intent_id.to_numpy(dtype=np.int64);assert np.all(success[ids]==1)
        np.add.at(dispute_found,ids,1)
        lost=ch.status=='lost';vals=ch.loc[lost,'settlement_debit_minor'].to_numpy(dtype=np.int64)
        np.add.at(local_src['dispute_debit'],as_merchant[ids[lost]],-vals)
    assert np.all(dispute_found<=1) and not np.any((dispute_found>0)&(refunded>0))
    for ch in chunks(data,'fact_settlement',['merchant_id','status','amount_minor']):
        done=ch.status=='completed'
        np.add.at(local_src['payout_debit'],ch.loc[done,'merchant_id'].to_numpy(dtype=np.int64),-ch.loc[done,'amount_minor'].to_numpy(dtype=np.int64))
    local_ledger={ev:np.zeros(m+1,dtype=np.int64) for ev in EVENTS};balances=np.zeros(m+1,dtype=np.int64)
    for ch in chunks(data,'fact_merchant_ledger',['merchant_id','event_type','signed_amount_minor','posted_at']):
        assert ch.posted_at.lt('2026-10-01T00:00:00Z').all()
        merch=ch.merchant_id.to_numpy(dtype=np.int64);v=ch.signed_amount_minor.to_numpy(dtype=np.int64)
        np.add.at(balances,merch,v)
        for ev in EVENTS:
            mask=ch.event_type==ev
            np.add.at(local_ledger[ev],merch[mask],v[mask])
    for ev in EVENTS:
        assert np.array_equal(local_ledger[ev],local_src[ev]),'per-merchant reconciliation failed '+ev
    assert np.array_equal(balances,np.sum(np.stack(list(local_src.values())),axis=0))
    report={'status':'PASS','intents':n,'intent_outcomes':dict(status_counts),'guests':guest_count,'payment_method_attempts':dict(method_counts),'gateway_attempts':gateways[1:].tolist(),'ledger_events':{ev:int(local_ledger[ev].sum()) for ev in EVENTS},'all_2000_merchant_account_currency_balances_reconciled':True,'all_successful_intents_have_one_successful_attempt':True,'fee_entry_cardinality':True,'refund_caps':True,'disputes_unique_and_not_refunded':True,'temporal_cutoff_pass':True,'usd_fx_ready':conf['row_counts']['fact_fx_rate']==18260}
    (data/'strict_validation_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--data-dir',type=Path,default=Path('data'));a=p.parse_args();main(a.data_dir)
