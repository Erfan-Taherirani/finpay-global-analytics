#!/usr/bin/env python3
"""FinPay Global synthetic payment data. Monetary amounts are local minor units, NOT USD."""
from __future__ import annotations
import argparse, calendar, gzip, json, math
from pathlib import Path
from datetime import date, datetime, timedelta, timezone
import numpy as np
import pandas as pd

START='2021-10-01'; END='2026-09-30'; CUTOFF=pd.Timestamp('2026-10-01',tz='UTC')
COUNTRIES=['US','GB','DE','FR','CA','AU','JP','CN','IR','RU','MX','EG']
CCY={'US':'USD','GB':'GBP','DE':'EUR','FR':'EUR','CA':'CAD','AU':'AUD','JP':'JPY','CN':'CNY','IR':'USD','RU':'RUB','MX':'MXN','EG':'EGP'}
# purely fictional domestic checkout nominal scales; NOT market exchange rates
PRICE_SCALE={'USD':1,'EUR':.95,'GBP':.85,'CAD':1.35,'AUD':1.55,'JPY':140,'CNY':7.3,'RUB':90,'MXN':18,'EGP':48}
TZ={'US':'America/New_York','GB':'Europe/London','DE':'Europe/Berlin','FR':'Europe/Paris','CA':'America/Toronto','AU':'Australia/Sydney','JP':'Asia/Tokyo','CN':'Asia/Shanghai','IR':'Asia/Tehran','RU':'Europe/Moscow','MX':'America/Mexico_City','EG':'Africa/Cairo'}
MINOR={'USD':2,'EUR':2,'GBP':2,'CAD':2,'AUD':2,'JPY':0,'CNY':2,'RUB':2,'MXN':2,'EGP':2}
INDUSTRIES=['retail','electronics','travel','subscriptions','food','services']
GW_NAMES=['AtlasFlow','BlueHarbor','OrbitRoute','NovaSwitch','PineBridge']
RNG=np.random.default_rng(20261021)

def write(df,name,out):
    p=out/(name+'.csv.gz')
    df.to_csv(p,mode='at',compression={'method':'gzip','compresslevel':1},index=False,header=not p.exists(),float_format='%.9f')

def iso(ts): return pd.to_datetime(ts,unit='s',utc=True).strftime('%Y-%m-%dT%H:%M:%SZ')

def main(n=1620000, out=Path('data')):
    out.mkdir(parents=True,exist_ok=True)
    for p in out.glob('*.csv.gz'): p.unlink()
    rng=RNG
    months=pd.period_range('2021-10','2026-09',freq='M')
    start_ts=pd.Timestamp(START,tz='UTC').timestamp()
    end_ts=CUTOFF.timestamp()
    # dimensions
    write(pd.DataFrame({'currency_code':list(MINOR),'minor_units':list(MINOR.values()),'currency_name': ['US Dollar','Euro','Pound Sterling','Canadian Dollar','Australian Dollar','Japanese Yen','Chinese Yuan','Russian Ruble','Mexican Peso','Egyptian Pound']}),'dim_currency',out)
    write(pd.DataFrame({'country_code':COUNTRIES,'market_name':['United States','United Kingdom','Germany','France','Canada','Australia','Japan','China','Iran (sandbox-only USD)','Russia (fictional domestic)','Mexico','Egypt'],'currency_code':[CCY[x] for x in COUNTRIES],'timezone':[TZ[x] for x in COUNTRIES]}),'dim_market',out)
    write(pd.DataFrame({'gateway_id':np.arange(1,6),'gateway_name':GW_NAMES,'home_region':['North America','Europe','APAC','Global','Emerging Markets'],'is_enabled':[1]*5}),'dim_gateway',out)
    m=2000; c=100000
    merchant_country=rng.choice(COUNTRIES,size=m,p=np.array([.21,.11,.095,.09,.09,.075,.08,.065,.025,.045,.055,.06])/1.02) if False else None
    w=np.array([.21,.11,.095,.09,.09,.075,.08,.065,.025,.045,.055,.06]);w=w/w.sum()
    merchant_country=rng.choice(COUNTRIES,size=m,p=w)
    merchant_currency=np.array([CCY[x] for x in merchant_country]); merchant_industry=rng.choice(INDUSTRIES,size=m,p=[.32,.15,.08,.12,.13,.20]); merchant_tier=rng.choice(['starter','growth','enterprise'],size=m,p=[.63,.29,.08]); merchant_pay=rng.choice(['monthly','weekly'],size=m,p=[.72,.28])
    merchant_onboard_days=rng.integers(-1400,1550,size=m);merchant_onboard_days=np.clip(merchant_onboard_days,-1400,1620)
    merchant_onboard_sec=start_ts+merchant_onboard_days*86400
    merchant_onboard_str=iso(merchant_onboard_sec)
    merchant_prop=rng.lognormal(.0,1.0,m)*np.where(merchant_tier=='enterprise',4,np.where(merchant_tier=='growth',1.65,.85))
    merchant_prop /= merchant_prop.sum()
    dim_merchant=pd.DataFrame({'merchant_id':np.arange(1,m+1),'merchant_name':[f'FinPay Merchant {i:04d}' for i in range(1,m+1)],'country_code':merchant_country,'industry':merchant_industry,'onboarded_at':merchant_onboard_str,'settlement_currency':merchant_currency,'pricing_tier':merchant_tier,'payout_frequency':merchant_pay,'account_status':'active'})
    write(dim_merchant,'dim_merchant',out)
    # signups start with early prior first payments; list ordered by signup for safe eligibility
    customer_signup_day=np.sort(rng.integers(-400,1790,size=c))
    customer_country=rng.choice(COUNTRIES,size=c,p=w)
    customer_acq=rng.choice(['organic','paid_search','social','referral','partner'],size=c,p=[.36,.23,.15,.18,.08])
    write(pd.DataFrame({'customer_id':np.arange(1,c+1),'signed_up_at':iso(start_ts+customer_signup_day*86400+3600),'country_code':customer_country,'acquisition_channel':customer_acq,'is_verified':(rng.random(c)<.88).astype(int)}),'dim_customer',out)
    dates=pd.date_range(START,END,freq='D',tz='UTC')
    write(pd.DataFrame({'date_key':dates.strftime('%Y%m%d').astype('int32'),'date_utc':dates.strftime('%Y-%m-%d'),'year':dates.year,'month':dates.month,'year_month':dates.strftime('%Y-%m'),'day_of_week':dates.dayofweek,'is_weekend':(dates.dayofweek>=5).astype(int)}),'dim_date',out)
    # USD identity is real by definition; no fictional non-USD FX is written
    write(pd.DataFrame({'rate_date':dates.strftime('%Y-%m-%d'),'currency_code':'USD','usd_per_major_unit':1.0,'observation_date':dates.strftime('%Y-%m-%d'),'provider':'identity','rate_status':'identity'}),'fact_fx_rate',out)
    # monthly event balance matrix merchant_id x month_idx; dollars not combined
    monthly_bal=np.zeros((61,m),dtype=np.int64)
    ids={'intent':0,'attempt':0,'fee':0,'refund':0,'dispute':0,'ledger':0,'settlement':0}
    totals={name:0 for name in ['dim_currency','dim_market','dim_gateway','dim_merchant','dim_customer','dim_date','fact_fx_rate','fact_payment_intent','fact_payment_attempt','fact_fee','fact_refund','fact_dispute','fact_settlement','fact_merchant_ledger']}
    totals.update(dim_currency=len(MINOR),dim_market=len(COUNTRIES),dim_gateway=5,dim_merchant=m,dim_customer=c,dim_date=len(dates),fact_fx_rate=len(dates))
    probs=np.linspace(.7,1.45,60)*np.array([1.16 if p.month in [11,12] else .89 if p.month in [1,2] else 1.0 for p in months]); probs/=probs.sum()
    monthly_counts=rng.multinomial(n,probs)
    def outwrite(data,table):
        if data is None or len(data)==0:return
        write(pd.DataFrame(data),table,out);totals[table]+=len(next(iter(data.values())))
    for mi, period in enumerate(months):
        k=int(monthly_counts[mi]);base_day=pd.Timestamp(str(period.start_time.date()),tz='UTC');month_days=period.days_in_month
        month_day=rng.integers(0,month_days,size=k)
        created_seconds=base_day.timestamp()+month_day*86400+rng.integers(3600,78000,size=k)
        # avoid first-of-day and cutoff pitfalls
        day_num=np.floor((created_seconds-start_ts)/86400).astype(np.int32)
        merchant_idxs=rng.choice(m,size=k,p=merchant_prop)
        bad=merchant_onboard_sec[merchant_idxs]>=created_seconds
        tries=0
        while bad.any() and tries<15:
            merchant_idxs[bad]=rng.choice(m,size=bad.sum(),p=merchant_prop)
            bad=merchant_onboard_sec[merchant_idxs]>=created_seconds;tries+=1
        if bad.any():
            merchant_idxs[bad]=int(np.argmin(merchant_onboard_sec))
        mids=merchant_idxs+1
        currencies=merchant_currency[merchant_idxs]; countries=merchant_country[merchant_idxs]
        industry=merchant_industry[merchant_idxs];tieri=merchant_tier[merchant_idxs]
        # customer_id 0 denotes guest, valid signup always preceding intent
        available=np.searchsorted(customer_signup_day,day_num-1,side='right'); available=np.maximum(available,0)
        customer_ids=(np.floor(rng.random(k)**1.4*np.maximum(available,1)).astype(np.int64)+1)
        guest=(rng.random(k)<.27)|(available==0);customer_ids[guest]=0
        buyer_country=np.where(rng.random(k)<.84,countries,rng.choice(COUNTRIES,size=k,p=w))
        # Amounts: nominal local currency unit scales are NOT historical FX
        scale=np.array([PRICE_SCALE[x] for x in currencies]); mu=np.array([{'retail':3.45,'electronics':4.45,'travel':4.7,'subscriptions':2.9,'food':2.95,'services':3.75}[x] for x in industry])
        base_amount=np.clip(rng.lognormal(mu,.73,size=k)*scale,.75*scale,2200*scale)
        factors=np.array([10**MINOR[x] for x in currencies]); amounts=np.maximum(1,np.rint(base_amount*factors).astype(np.int64))
        ids0=ids['intent']+np.arange(1,k+1,dtype=np.int64);ids['intent']+=k
        channel=rng.choice(['web','mobile_web','app'],size=k,p=[.38,.33,.29])
        # Wallet growth is a simulation choice, anchored directionally to Worldpay value-share data
        # Approximate wallet *value-share* trajectory from published 2021-2025
        # Global e-commerce reports; this count mix is only a modeling proxy.
        wallet_share=.49+.10*(mi/59)
        method=rng.choice(['card','wallet','bank_debit'],size=k,p=[.86-wallet_share,wallet_share,.14])
        bank_pref=np.isin(countries,['DE','FR','GB','EG'])&(rng.random(k)<.12)
        method=np.where(bank_pref,'bank_debit',method)
        abandoned=rng.random(k)<.032
        pending=(rng.random(k)<.0011)&~abandoned
        gateway1=rng.integers(1,6,size=k,dtype=np.int16)
        # identifiable 2023, 2025, 2026 gateway disturbances
        outage=(np.isin(pd.to_datetime(created_seconds,unit='s',utc=True).strftime('%Y-%m-%d'),['2023-06-13','2023-06-14','2025-02-11','2025-02-12','2026-04-17'])&(gateway1==3))
        first_p=.863+np.where(method=='wallet',.042,np.where(method=='bank_debit',-.026,0)) +np.where(np.isin(countries,['US','GB','DE','FR']),.013,-.012)+np.where(gateway1==1,.018,np.where(gateway1==4,-.015,0)) - .42*outage
        first_success=(rng.random(k)<np.clip(first_p,.2,.97))&~abandoned&~pending
        retry1=(~first_success)&~abandoned&~pending&(rng.random(k)<.48)
        second_success=retry1&(rng.random(k)<(.57-0.3*outage))
        retry2=retry1&(~second_success)&(rng.random(k)<.20)
        third_success=retry2&(rng.random(k)<.55)
        success=first_success|second_success|third_success
        last_attempt=np.where(retry2,3,np.where(retry1,2,np.where(abandoned,0,1))).astype(np.int8)
        final=np.where(success,'succeeded',np.where(abandoned,'abandoned',np.where(pending,'pending','failed')))
        first_start=created_seconds+rng.integers(2,30,size=k)
        times2=first_start+25;times3=first_start+52
        captured_sec=np.where(first_success,first_start+3,np.where(second_success,times2+3,times3+3))
        closed_sec=np.where(pending|abandoned,created_seconds+85, np.where(last_attempt==3,times3+5,np.where(last_attempt==2,times2+5,first_start+5)))
        intent_data={'intent_id':ids0,'merchant_id':mids,'customer_id':np.where(guest,'',customer_ids.astype(str)),'order_reference':['ORDER-%d'%x for x in ids0], 'created_at':iso(created_seconds),'buyer_country':buyer_country,'checkout_channel':channel,'presentment_currency':currencies,'amount_minor':amounts,'final_outcome':final,'closed_at':np.where(pending,'',iso(closed_sec)),'captured_at':np.where(success,iso(captured_sec),''),'captured_settlement_minor':np.where(success,amounts.astype(str),'')}
        outwrite(intent_data,'fact_payment_intent')
        # attempt per retry level, batched
        def attempt_write(mask,num,started,succ,pend,gateway,method):
            x=int(mask.sum());
            if not x:return
            seq=ids['attempt']+np.arange(1,x+1,dtype=np.int64);ids['attempt']+=x
            st=started[mask];pc=pend[mask]; ss=succ[mask]
            latency=rng.integers(140,2600,size=x); latency=np.where(outage[mask],rng.integers(4500,18000,size=x),latency)
            latency=np.where(ss,np.minimum(latency,2100),latency)
            end=st+latency/1000
            reasons=rng.choice(['insufficient_funds','issuer_decline','network_timeout','authentication_failed','suspected_fraud'],size=x,p=[.29,.29,.18,.13,.11])
            reasons=np.where(outage[mask],'network_timeout',reasons)
            outwrite({'attempt_id':seq,'intent_id':ids0[mask],'gateway_id':gateway[mask],'attempt_number':np.full(x,num),'started_at':iso(st),'finished_at':np.where(pc,'',iso(end)),'payment_method':method[mask],'outcome':np.where(pc,'pending',np.where(ss,'succeeded','failed')),'failure_reason':np.where(ss|pc,'',reasons),'latency_ms':np.where(pc,'',latency.astype(str))},'fact_payment_attempt')
        g2=(gateway1%5)+1;g3=(g2%5)+1
        attempt_write(~abandoned,1,first_start,first_success,pending,gateway1,method)
        attempt_write(retry1,2,times2,second_success,np.zeros(k,bool),g2,method)
        attempt_write(retry2,3,times3,third_success,np.zeros(k,bool),g3,method)
        # fees and ledger posted in settlement currency equal presentment currency (v1)
        good=np.where(success)[0];sz=len(good)
        succeeded_id=ids0[good];sm=mids[good]; sa=amounts[good];sf=factors[good]; st=captured_sec[good];tier=tieri[good];sc=currencies[good]
        fee_pct=np.where(tier=='starter',.029,np.where(tier=='growth',.024,.018))
        fx_local=np.array([PRICE_SCALE[x] for x in sc])
        fee_fix=np.maximum(1,np.rint(.25*fx_local*sf).astype(np.int64))
        fee1=np.minimum(sa-1,np.maximum(1,np.rint(sa*fee_pct).astype(np.int64)+fee_fix))
        cost=np.maximum(1,np.rint(sa*np.where(method[good]=='bank_debit',.008,.016)).astype(np.int64)+np.rint(.08*fx_local*sf).astype(np.int64))
        # cost is PSP operating cost, never debits merchant payable
        fee_id1=ids['fee']+np.arange(1,sz+1);fee_id2=ids['fee']+sz+np.arange(1,sz+1);ids['fee']+=2*sz
        outwrite({'fee_id':np.concatenate([fee_id1,fee_id2]),'intent_id':np.tile(succeeded_id,2),'dispute_id':'','assessed_at':np.tile(iso(st+6),2),'fee_type':np.repeat(['merchant_fee','processor_cost'],sz),'amount_settlement_minor':np.concatenate([fee1,cost])},'fact_fee')
        def ledger_entries(mid,ccy,amount,event_at,event_type,source_id):
            length=len(mid)
            if length==0:return
            idx=ids['ledger']+np.arange(1,length+1);ids['ledger']+=length
            outwrite({'entry_id':idx,'merchant_id':mid,'currency_code':ccy,'posted_at':iso(event_at),'event_type':event_type,'source_id':source_id,'signed_amount_minor':amount},'fact_merchant_ledger')
            event_month=pd.to_datetime(event_at,unit='s',utc=True).tz_localize(None).to_period('M')
            mm=((event_month.year-2021)*12+(event_month.month-10)).to_numpy(dtype=np.int32)
            valid=(mm>=0)&(mm<60)
            np.add.at(monthly_bal,(mm[valid],mid[valid]-1),amount[valid])
        ledger_entries(sm,sc,sa,st+7,'capture_credit',succeeded_id)
        ledger_entries(sm,sc,-fee1,st+8,'merchant_fee_debit',fee_id1)
        # refunds event probabilities vary by industry, and full/partial values
        rate=np.array([{'retail':.042,'electronics':.031,'travel':.057,'subscriptions':.024,'food':.018,'services':.023}[a] for a in industry[good]])
        refunded=rng.random(sz)<rate
        rs=np.where(refunded)[0];rr=len(rs)
        rr_id=ids['refund']+np.arange(1,rr+1);ids['refund']+=rr
        refund_delays=rng.integers(1,75,size=rr)*86400
        requested=st[rs]+refund_delays; refund_success=rng.random(rr)<.93
        refund_final=np.where(refund_success,'succeeded',np.where(rng.random(rr)<.62,'pending','failed'))
        resolved=requested+rng.integers(2,6,size=rr)*3600
        eligible=(requested<end_ts-86400)&(resolved<end_ts)
        # skip after snapshot (event not observed)
        rmask=np.where(eligible)[0];rr_id=rr_id[rmask];loc=rs[rmask];req=requested[rmask];end=resolved[rmask];status=refund_final[rmask]
        full=rng.random(len(loc))<.55; proportion=np.where(full,1.0,rng.uniform(.15,.75,size=len(loc)))
        refund_amt=np.maximum(1,np.rint(sa[loc]*proportion).astype(np.int64));sett_ref=np.where(status=='succeeded',refund_amt,0)
        outwrite({'refund_id':rr_id,'intent_id':succeeded_id[loc],'requested_at':iso(req),'completed_at':np.where(status=='pending','',iso(end)),'status':status,'reason':rng.choice(['customer_request','product_return','service_issue','duplicate'],size=len(loc)),'amount_minor':refund_amt,'settlement_debit_minor':np.where(status=='succeeded',refund_amt.astype(str),'')},'fact_refund')
        done=status=='succeeded'
        ledger_entries(sm[loc][done],sc[loc][done],-sett_ref[done],end[done]+1,'refund_debit',rr_id[done])
        refunded_good=np.zeros(sz,bool);refunded_good[loc[done]]=True
        # at most one dispute/payment; card payments only; mutually exclusive with refunded
        dispute_rate=np.where(np.isin(industry[good],['travel','electronics']),.008,.0036)
        disputable=(method[good]=='card')&~refunded_good&(rng.random(sz)<dispute_rate)
        di=np.where(disputable)[0];dn=len(di);d_id=ids['dispute']+np.arange(1,dn+1);ids['dispute']+=dn
        opened=st[di]+rng.integers(10,91,size=dn)*86400
        resolved=opened+rng.integers(12,41,size=dn)*86400
        present=opened<end_ts
        di=di[present];d_id=d_id[present];opened=opened[present];resolved=resolved[present]
        dstatus=np.where(resolved>=end_ts,'open',np.where(rng.random(len(di))<.36,'lost','won'))
        damt=sa[di]; lost=dstatus=='lost'; dl=damt[lost]
        outwrite({'dispute_id':d_id,'intent_id':succeeded_id[di],'opened_at':iso(opened),'resolved_at':np.where(dstatus=='open','',iso(resolved)),'status':dstatus,'reason':rng.choice(['fraud','product_not_received','unrecognized','duplicate'],size=len(di)),'disputed_amount_minor':damt,'settlement_debit_minor':np.where(lost,damt.astype(str),'')},'fact_dispute')
        ledger_entries(sm[di][lost],sc[di][lost],-dl,resolved[lost]+1,'dispute_debit',d_id[lost])
        nl=lost.sum()
        if nl:
            local_f=np.maximum(1,np.rint(8* np.array([PRICE_SCALE[x] for x in sc[di][lost]])*sf[di][lost]).astype(np.int64))
            charge_id=ids['fee']+np.arange(1,nl+1);ids['fee']+=nl
            outwrite({'fee_id':charge_id,'intent_id':succeeded_id[di][lost],'dispute_id':d_id[lost],'assessed_at':iso(resolved[lost]+2),'fee_type':'dispute_fee','amount_settlement_minor':local_f},'fact_fee')
            ledger_entries(sm[di][lost],sc[di][lost],-local_f,resolved[lost]+3,'dispute_fee_debit',charge_id)
        if (mi+1)%12==0:print('generated checkout years', (mi+1)//12, 'intents',ids['intent'], flush=True)
    # Settlement payout activity once per month, event at beginning of FOLLOWING month; ensures no future payout.
    carry=np.zeros(m,dtype=np.int64)
    for mi in range(59):
        carry+=monthly_bal[mi]
        pending_m=np.where(carry>0)[0]
        if not len(pending_m):continue
        select=pending_m[(rng.random(len(pending_m))<.94)]
        if not len(select):continue
        month_end=pd.Timestamp(str(months[mi+1].start_time.date()),tz='UTC').timestamp()
        initiated=month_end+rng.integers(600,2400,size=len(select))
        delay=rng.integers(5,54,size=len(select))*3600
        scheduled=initiated+86400
        completed=initiated+delay
        status=np.where(rng.random(len(select))<.945,'completed',np.where(rng.random(len(select))<.35,'pending','failed'))
        amount=np.maximum(1,np.floor(carry[select]*rng.uniform(.76,.94,size=len(select))).astype(np.int64))
        st_ids=ids['settlement']+np.arange(1,len(select)+1);ids['settlement']+=len(select)
        outwrite({'settlement_id':st_ids,'merchant_id':select+1,'currency_code':merchant_currency[select],'initiated_at':iso(initiated),'scheduled_at':iso(scheduled),'completed_at':np.where(status=='completed',iso(completed),''),'status':status,'amount_minor':amount,'failure_reason':np.where(status=='failed','bank_return','')},'fact_settlement')
        done=status=='completed'
        carry[select[done]]-=amount[done]
        # completed payout debits appear first of next month, not same month
        x=select[done];money=amount[done]
        led_id=ids['ledger']+np.arange(1,len(x)+1);ids['ledger']+=len(x)
        outwrite({'entry_id':led_id,'merchant_id':x+1,'currency_code':merchant_currency[x],'posted_at':iso(completed[done]),'event_type':'payout_debit','source_id':st_ids[done],'signed_amount_minor':-money},'fact_merchant_ledger')
        # carry already debited; never double-subtract at next month roll-forward
    manifest={'dataset_name':'FinPay Global','version':'2.0','synthetic':True,'seed':20261021,'period_start':START,'period_end':END,'snapshot':str(CUTOFF),'currency_coverage':list(MINOR),'merchant_markets':COUNTRIES,'local_only_settlement':True,'usd_fx_rates':'INCOMPLETE: USD identity only; run src/fetch_fx.py to import real historical daily FX; no synthetic rates substituted','row_counts':totals,'total_rows':sum(totals.values()),'money_units':'integer minor units; NOT USD except USD currency','benchmark_source':'Worldpay, Stripe, Visa, data percentages synthetic unless explicitly source-backed'}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2))
    print(json.dumps(manifest,indent=2),flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--intents',type=int,default=1620000);parser.add_argument('--out',type=Path,default=Path('data'));args=parser.parse_args()
    main(args.intents,args.out)
