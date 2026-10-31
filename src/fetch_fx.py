#!/usr/bin/env python3
"""Import ACTUAL historical central-bank reference daily FX into fact_fx_rate.

Fail closed: never fabricate or interpolate observed FX. Business-day carry-forward
is marked, and original observation dates are preserved.
Usage: python src/fetch_fx.py --data-dir data
Requires internet, requests, pandas, numpy.
"""
from __future__ import annotations
import argparse, json, gzip, time
from pathlib import Path
import requests
import pandas as pd

CURRENCIES=['USD','EUR','GBP','CAD','AUD','JPY','CNY','RUB','MXN','EGP']
FROM='2021-10-01';TO='2026-09-30'
API='https://api.frankfurter.dev/v2/rates'

def main(data_dir):
    target=Path(data_dir); target.mkdir(parents=True,exist_ok=True)
    started=pd.Timestamp(FROM)-pd.Timedelta(days=14)
    frames=[]
    for y in range(started.year,pd.Timestamp(TO).year+1):
        lo=max(started,pd.Timestamp(f'{y}-01-01')).date().isoformat()
        hi=min(pd.Timestamp(TO),pd.Timestamp(f'{y}-12-31')).date().isoformat()
        params={'from':lo,'to':hi,'base':'USD','quotes':','.join([x for x in CURRENCIES if x!='USD'])}
        r=requests.get(API,params=params,timeout=90);r.raise_for_status()
        payload=r.json()
        if not isinstance(payload,list):raise ValueError(f'Unexpected FX response {y}: {str(payload)[:300]}')
        frames.append(pd.DataFrame(payload))
        print('downloaded',lo,hi,'rows',len(payload),flush=True)
        time.sleep(.3)
    raw=pd.concat(frames,ignore_index=True)
    if len(raw)==0:raise RuntimeError('No FX observations downloaded; will not generate fake rates')
    raw=raw.rename(columns={'date':'observation_date','quote':'currency_code','rate':'quote_per_usd'})
    raw=raw[raw.currency_code.isin(CURRENCIES)].dropna(subset=['quote_per_usd','observation_date'])
    raw['observation_date']=pd.to_datetime(raw.observation_date)
    raw['quote_per_usd']=pd.to_numeric(raw.quote_per_usd,errors='coerce')
    raw=raw[raw.quote_per_usd>0].sort_values('observation_date').drop_duplicates(['currency_code','observation_date'],keep='last')
    alldays=pd.date_range(FROM,TO,freq='D')
    res=[]
    for cc in CURRENCIES:
        if cc=='USD':
            res.append(pd.DataFrame({'rate_date':alldays.strftime('%Y-%m-%d'),'currency_code':'USD','usd_per_major_unit':1.0,'observation_date':alldays.strftime('%Y-%m-%d'),'provider':'identity','rate_status':'identity'}));continue
        sub=raw.loc[raw.currency_code==cc,['observation_date','quote_per_usd']].set_index('observation_date').sort_index()
        if sub.empty:raise RuntimeError(f'Missing entire 5-year {cc} series: cannot invent FX')
        expanded=sub.reindex(pd.date_range(started,pd.Timestamp(TO),freq='D')).ffill().loc[alldays]
        if expanded.quote_per_usd.isna().any():raise RuntimeError(f'Unfilled FX dates for {cc}')
        # actual publication date backfilled using the observations, never forward-looking
        obs=pd.Series(sub.index,index=sub.index).reindex(pd.date_range(started,pd.Timestamp(TO),freq='D')).ffill().loc[alldays]
        if (alldays.to_series(index=alldays)-obs).dt.days.max()>14: raise RuntimeError(f'{cc} has >14-day gap in real observed FX source; investigate provider coverage')
        res.append(pd.DataFrame({'rate_date':alldays.strftime('%Y-%m-%d'),'currency_code':cc,'usd_per_major_unit':(1/expanded.quote_per_usd.to_numpy()).round(12),'observation_date':obs.dt.strftime('%Y-%m-%d').to_numpy(),'provider':'frankfurter_v2_central_bank_blend','rate_status':pd.Series(alldays.strftime('%Y-%m-%d')).eq(obs.dt.strftime('%Y-%m-%d').to_numpy()).map({True:'observed',False:'carried_forward'}).to_numpy()}))
    fx=pd.concat(res,ignore_index=True)
    if len(fx)!=len(alldays)*len(CURRENCIES):raise AssertionError('FX coverage incomplete')
    export=target/'fact_fx_rate.csv.gz'
    fx.to_csv(export,index=False,compression='gzip',float_format='%.12f')
    manifest=target/'manifest.json'
    if manifest.exists():
        d=json.loads(manifest.read_text()); d['row_counts']['fact_fx_rate']=len(fx);d['total_rows']=sum(d['row_counts'].values());d['usd_fx_rates']='REAL observed central-bank reference series + tagged non-trading-day carry-forward, via Frankfurter v2';d['fx_source_url']=API;d['fx_fx_record_count']=len(fx); manifest.write_text(json.dumps(d,indent=2))
    print('FX imported:',len(fx),'rows, 10 currencies,',FROM,'through',TO)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--data-dir',default='data');a=p.parse_args();main(a.data_dir)
