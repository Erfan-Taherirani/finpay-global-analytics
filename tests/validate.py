#!/usr/bin/env python3
"""Source-to-ledger reconciliation and table/data quality checks, streaming CSV chunks."""
import argparse,json,collections
from pathlib import Path
import pandas as pd

def scan(directory,name,cols=None):
    path=directory/(name+'.csv.gz')
    for x in pd.read_csv(path,usecols=cols,chunksize=250000,low_memory=False):yield x

def check(folder):
    manifest=json.loads((folder/'manifest.json').read_text())
    counts={}
    for name in manifest['row_counts']:
        counts[name]=sum(len(c) for c in scan(folder,name))
        assert counts[name]==manifest['row_counts'][name],(name,counts[name],manifest['row_counts'][name])
    assert counts['dim_customer']==100000 and counts['dim_merchant']==2000
    if manifest['row_counts']['fact_payment_intent']==1620000:
        assert 8000000<=sum(counts.values())<=10000000,('Volume outside target',sum(counts.values()))
    balances=collections.defaultdict(int); types=collections.Counter()
    source=collections.Counter()
    merchant_ccy=pd.read_csv(folder/'dim_merchant.csv.gz',usecols=['merchant_id','settlement_currency']).set_index('merchant_id')['settlement_currency'].to_dict()
    for chunk in scan(folder,'fact_merchant_ledger',['merchant_id','currency_code','event_type','signed_amount_minor']):
        assert chunk['signed_amount_minor'].ne(0).all()
        assert (chunk.loc[chunk.event_type=='capture_credit','signed_amount_minor']>0).all()
        assert (chunk.loc[chunk.event_type!='capture_credit','signed_amount_minor']<0).all()
        assert (chunk['currency_code'].to_numpy()==chunk['merchant_id'].map(merchant_ccy).to_numpy()).all()
        for (m,c),x in chunk.groupby(['merchant_id','currency_code']).signed_amount_minor.sum().items(): balances[(m,c)]+=int(x)
        for et,x in chunk.groupby('event_type').signed_amount_minor.sum().items():types[et]+=int(x)
    for chunk in scan(folder,'fact_payment_intent',['final_outcome','captured_settlement_minor']):
        mask=chunk.final_outcome=='succeeded'
        assert chunk.loc[mask,'captured_settlement_minor'].notna().all()
        assert chunk.loc[~mask,'captured_settlement_minor'].isna().all()
        source['capture_credit']+=int(chunk.captured_settlement_minor.fillna(0).sum())
    for chunk in scan(folder,'fact_fee',['fee_type','amount_settlement_minor']):
        x=chunk.loc[chunk.fee_type=='merchant_fee','amount_settlement_minor'].sum();source['merchant_fee_debit']-=int(x)
        x=chunk.loc[chunk.fee_type=='dispute_fee','amount_settlement_minor'].sum();source['dispute_fee_debit']-=int(x)
    for chunk in scan(folder,'fact_refund',['status','settlement_debit_minor']):
        source['refund_debit']-=int(chunk.loc[chunk.status=='succeeded','settlement_debit_minor'].sum())
    for chunk in scan(folder,'fact_dispute',['status','settlement_debit_minor']):
        source['dispute_debit']-=int(chunk.loc[chunk.status=='lost','settlement_debit_minor'].sum())
    for chunk in scan(folder,'fact_settlement',['status','amount_minor']):
        source['payout_debit']-=int(chunk.loc[chunk.status=='completed','amount_minor'].sum())
    for k in ['capture_credit','merchant_fee_debit','refund_debit','dispute_debit','dispute_fee_debit','payout_debit']:
        assert types[k]==source[k],(k,'ledger',types[k],'source',source[k])
    fx_ccy=set()
    for x in scan(folder,'fact_fx_rate',['currency_code']):fx_ccy.update(x.currency_code.unique())
    fx_complete=fx_ccy==set(manifest['currency_coverage'])
    report={'total_rows':sum(counts.values()),'tables':counts,'financial_event_source_vs_ledger':{k:{'source_minor':source[k],'ledger_minor':types[k],'delta_minor':source[k]-types[k]} for k in source},'merchant_currency_accounts':len(balances),'fx_complete':fx_complete,'usd_reporting_available':fx_complete,'data_status':'PASS_SOURCES_LEDGER_FX_PENDING' if not fx_complete else 'PASS'}
    (folder/'quality_report.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--data-dir',type=Path,default=Path('data'));a=p.parse_args();check(a.data_dir)
