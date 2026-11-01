#!/usr/bin/env python3
"""Build a Markdown dataset-card scaffold and uniform images from metadata plus real data.

Examples:
  python scripts/generate_data_card.py --manifest examples/manifest.example.json \
      --data-dir examples/data --out /tmp/shop_data_card --zip

Dependencies: Pillow, pandas; optional pyarrow for parquet, Graphviz for diagrams.
"""
import argparse
from datetime import datetime, timezone
import gzip
import html
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile
from collections import Counter

try:
    import pandas as pd
    from PIL import Image, ImageDraw, ImageFont
except ImportError as e:
    raise SystemExit(f"Missing dependency: {e}. Install: pip install pillow pandas pyarrow")

NAVY='#081B32'; DARK='#102742'; TEAL='#0F9C92'; BLUE='#20A7E8'; FACT='#748BD4'
BG='#F6FBFF'; ALT='#EAF3F8'; MUTED='#617B91'; WHITE='#FFFFFF'


def slug(x):
    s=re.sub(r'[^a-z0-9_-]+','-',str(x).lower()).strip('-')
    return s or 'dataset'


def md(x):
    return str(x if x is not None else 'Not specified').replace('|','\\|').replace('\n',' ')


def text(x):
    return str(x if x is not None else '')


def fonts(size, bold=False):
    names=(['/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf',
            '/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf'] if bold else
           ['/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
            '/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf'])
    for path in names:
        if Path(path).exists(): return ImageFont.truetype(path,size)
    return ImageFont.load_default()


def wrap_line(draw, s, maxw, font):
    words=text(s).split(); result=[]; line=''
    for word in words:
        candidate=(line+' '+word).strip()
        if draw.textbbox((0,0),candidate,font=font)[2]>maxw and line:
            result.append(line);line=word
        else:line=candidate
    if line:result.append(line)
    return result


def ellipsis(draw, val, width, font):
    s=text(val).replace('\n',' ')
    if draw.textbbox((0,0),s,font=font)[2]<=width:return s
    while s and draw.textbbox((0,0),s+'…',font=font)[2]>width:s=s[:-1]
    return s+'…'


def rounded(draw,xy,r,fill):draw.rounded_rectangle(xy,radius=r,fill=fill)


def hero(out,title,subtitle,table_count):
    W,H=1800,460; im=Image.new('RGB',(W,H),NAVY); d=ImageDraw.Draw(im)
    for y in range(H):
        t=y/max(H-1,1)
        d.line((0,y,W,y),fill=(int(8+8*t),int(27+15*t),int(50+29*t)))
    # subtle data-motif grid
    for x in range(930,1780,50):
        for y in range(60,420,50):
            r=2 if (x+y)//50 % 4 else 4
            d.ellipse((x-r,y-r,x+r,y+r),fill='#164969')
    d.rectangle((77,96,88,364),fill=BLUE)
    d.text((132,104),'DATASET  /  DATA CARD',font=fonts(28,True),fill='#89DFD6')
    title_lines=wrap_line(d,title,1050,fonts(76,True))[:2]
    yy=164
    for line in title_lines:
        d.text((132,yy),line,font=fonts(76,True),fill=WHITE); yy+=87
    d.text((136,min(yy+7,365)),ellipsis(d,subtitle,1100,fonts(30)),font=fonts(30),fill='#C2D8E8')
    # arc motifs
    d.arc((1190,60,1830,680),start=175,end=355,fill=BLUE,width=6)
    d.arc((1325,-70,2050,610),start=170,end=345,fill=TEAL,width=4)
    for i,h in enumerate([65,92,128,172,230,272]):
        x=1468+i*40;d.rounded_rectangle((x,370-h,x+23,370),radius=6,fill=('#147E9A' if i%2 else '#26A5CF'))
    d.text((1380,410),f'{table_count} DATA TABLES',font=fonts(22,True),fill='#97E9DF')
    im.save(out,optimize=True)


def find_file(data_dir,name):
    for ext in ('.parquet','.csv','.csv.gz'):
        p=data_dir/(name+ext)
        if p.is_file():return p
    return None


def first_rows(path,n=5):
    if not path:return None
    try:
        if path.name.endswith('.parquet'):
            try:
                import pyarrow.parquet as pq
                pf=pq.ParquetFile(path)
                batches=pf.iter_batches(batch_size=n)
                batch=next(batches,None)
                return batch.to_pandas().head(n) if batch is not None else pd.DataFrame(columns=pf.schema.names)
            except ImportError:
                try:
                    import polars as pl
                    return pl.scan_parquet(str(path)).head(n).collect().to_pandas()
                except ImportError:
                    raise RuntimeError('parquet reading needs pyarrow or polars')
        return pd.read_csv(path,nrows=n,low_memory=False,dtype=str,keep_default_na=False)
    except Exception as exc:
        print(f'WARNING preview {path.name}: {exc}',file=sys.stderr)
        return None



def count_rows(path):
    """Count source rows without loading the full dataset at once."""
    if not path:return None
    if path.name.endswith('.parquet'):
        try:
            import pyarrow.parquet as pq
            return int(pq.ParquetFile(path).metadata.num_rows)
        except ImportError:
            return None
    # Use CSV parser rather than raw line count (quoted fields can have newlines).
    return sum(len(chunk) for chunk in pd.read_csv(path,chunksize=200_000,usecols=[0],low_memory=False))


def render_preview(out,table,df,filename):
    name=table['name']; role=table.get('role','fact').lower(); accent=TEAL if role=='dimension' else FACT
    W,H=1600,670; im=Image.new('RGB',(W,H),BG);d=ImageDraw.Draw(im)
    d.rectangle((0,0,W,160),fill=NAVY);d.rectangle((0,153,W,160),fill=accent)
    d.text((56,36),ellipsis(d,name,1450,fonts(45,True)),font=fonts(45,True),fill=WHITE)
    d.text((58,101),role.upper()+'  /  '+table.get('grain','ONE RECORD'),font=fonts(20),fill='#B8DFE8')
    if df is None or df.empty:
        rounded(d,(55,225,1540,545),20,ALT)
        d.text((110,310),'PREVIEW UNAVAILABLE',font=fonts(45,True),fill=DARK)
        d.text((110,390),'No readable source rows were supplied for this table.',font=fonts(25),fill=MUTED)
        d.text((58,612),'Column definitions may still be documented in the Markdown dictionary.',font=fonts(18),fill=MUTED)
    else:
        excluded=set(table.get('preview_exclude',[]))
        requested=table.get('preview_columns',[])
        cols=[x for x in requested if x in df.columns and x not in excluded] if requested else [x for x in df.columns if x not in excluded]
        cols=cols[:6]
        if not cols:
            d.text((58,280),'PREVIEW UNAVAILABLE — ALL COLUMNS EXCLUDED',font=fonts(31,True),fill=DARK)
        else:
            # adaptive width via equal columns; intentional truncation of long values
            x0=55; x1=1545;row_h=59;top=238;cw=(x1-x0)/len(cols)
            d.text((57,186),f'FIRST {min(5,len(df))} SOURCE RECORDS  /  {len(cols)} OF {len(df.columns)} COLUMNS SHOWN',font=fonts(19,True),fill=MUTED)
            d.rectangle((x0,top,x1,top+row_h),fill=DARK)
            for i,c in enumerate(cols):
                x=int(x0+i*cw)+12
                d.text((x,top+20),ellipsis(d,c,cw-25,fonts(19,True)),font=fonts(19,True),fill=WHITE)
            for i,(_,r) in enumerate(df[cols].head(5).iterrows()):
                yy=top+row_h*(i+1)
                d.rectangle((x0,yy,x1,yy+row_h),fill=WHITE if i%2 else ALT)
                for j,c in enumerate(cols):
                    v=r[c];v='NULL' if pd.isna(v) else str(v)
                    x=int(x0+j*cw)+12
                    d.text((x,yy+22),ellipsis(d,v,cw-25,fonts(18)),font=fonts(18),fill=DARK)
        d.text((58,626),'Record order follows the input file; it is not an analytical sorting key.',font=fonts(18),fill=MUTED)
    im.save(out,optimize=True)


def categories_by_scan(path,columns,limit=50):
    """Enumerate bounded values by streaming all rows; report truncation if >limit."""
    result={c:set() for c in columns}
    if not path or not columns:return result
    if path.name.endswith('.parquet'):
        try:
            import pyarrow.parquet as pq
            pf=pq.ParquetFile(path)
            available=set(pf.schema.names);selected=[c for c in columns if c in available]
            batches=(b.to_pandas() for b in pf.iter_batches(batch_size=250_000,columns=selected))
        except ImportError:
            print('WARNING: pyarrow required to scan parquet categories',file=sys.stderr);return result
    else:
        cols=pd.read_csv(path,nrows=0).columns
        selected=[c for c in columns if c in cols]
        batches=pd.read_csv(path,usecols=selected,chunksize=100_000,dtype=str,keep_default_na=False)
    for chunk in batches:
        for c in selected:
            if len(result[c])>limit:continue
            values=chunk[c].dropna().astype(str).unique()
            result[c].update(values[:limit+1])
    return result


def graph_assets(out_dir,title,tables):
    assets=out_dir/'assets'; dot_path=assets/'relationship_map.dot'; png=assets/'relationship_map.png'
    lines=['digraph Dataset {','  graph [rankdir=LR,bgcolor="#F6FBFF",nodesep=.35,ranksep=1.1,pad=.5,splines=polyline,fontname="DejaVu Sans"];',
           '  node [shape=box,style="rounded,filled",fontname="DejaVu Sans",fontsize=13,margin="0.19,0.14"];',
           '  edge [color="#8EA7BA",fontname="DejaVu Sans",fontsize=10,arrowsize=.60];']
    names={t['name'] for t in tables}
    for t in tables:
        name=t['name']; role=t.get('role','fact').lower()
        fill='#D5F2EB' if role=='dimension' else '#E0E9FF'
        border=TEAL if role=='dimension' else FACT
        lines.append(f'  "{name}" [fillcolor="{fill}",color="{border}"];')
    edges=0
    for t in tables:
        for r in t.get('relationships',[]):
            parent=r.get('to_table')
            if parent not in names:continue
            label=r.get('from_column','')
            optional=bool(r.get('optional',False))
            style='dashed' if optional else 'solid'
            lines.append(f'  "{parent}" -> "{t["name"]}" [label="{label}",style={style}];')
            edges+=1
    lines.append('}')
    dot_path.write_text('\n'.join(lines)+'\n',encoding='utf-8')
    if shutil.which('dot'):
        p=subprocess.run(['dot','-Tpng',str(dot_path),'-o',str(png)],capture_output=True,text=True)
        if p.returncode==0:return edges
        print('WARNING Graphviz failed: '+p.stderr,file=sys.stderr)
    im=Image.new('RGB',(1600,590),BG);d=ImageDraw.Draw(im)
    d.text((70,70),'RELATIONSHIP MAP',font=fonts(54,True),fill=DARK)
    d.text((70,180),'Graphviz rendering unavailable. Open assets/relationship_map.dot for graph details.',
           font=fonts(24),fill=MUTED)
    d.text((70,250),f'{len(tables)} tables   |   {edges} specified links',font=fonts(30,True),fill=TEAL)
    im.save(png)
    return edges


def load_columns(table,frame):
    config=list(table.get('columns',[]))
    known={c['name'] for c in config}
    if frame is not None:
        for c in frame.columns:
            if c not in known:
                config.append({'name':c,'type':'Inferred from preview','description':'Not specified','note':'Metadata incomplete'})
    return config


def anchor(name):return slug(name)


def write_card(output,doc,tables,frames,paths,scanned):
    name=doc.get('name','Dataset');sub=doc.get('subtitle','Data dictionary and analytical guide')
    dims=[t for t in tables if t.get('role','fact').lower()=='dimension']
    facts=[t for t in tables if t not in dims]
    body=[f'![{md(name)} header](assets/header.png)','',f'# {name} — Dataset Card','',
          f'**{md(sub)}**', '', '<a id="table-of-contents"></a>', '<details open>',
          '<summary><strong>Explore this data card</strong></summary>','',
          '- [01 · Overview](#overview)','- [02 · Dataset inventory](#inventory)',
          '- [03 · Data lifecycle & record grain](#lifecycle)','- [04 · Relationship map](#relationships)',
          '- [05 · Dimensions](#dimensions)']
    body += [f'  - [`{t["name"]}`](#{anchor(t["name"])})' for t in dims]
    body+=['- [06 · Facts & reference tables](#facts)']
    body += [f'  - [`{t["name"]}`](#{anchor(t["name"])})' for t in facts]
    body+=['- [07 · Categorical value dictionary](#categorical-values)',
           '- [08 · Units, time & interpretation](#conventions)',
           '- [09 · Data quality & validation](#quality)',
           '- [10 · Analytical use cases](#use-cases)',
           '- [11 · Reproduction & maintenance](#maintenance)', '', '</details>','']
    def sec(id,title):body.extend([f'<a id="{id}"></a>',f'## {title}',''])
    sec('overview','Executive overview')
    body.append(md(doc.get('description','Business purpose not specified.'))+'\n')
    metrics={'Domain':doc.get('domain'),'Coverage':doc.get('coverage'),
             'Snapshot / as of':doc.get('snapshot'),'Version':doc.get('version'),
             'Maintainer':doc.get('owner'),'Tables':str(len(tables)),
             'Dimensions':str(len(dims)),'Facts / other':str(len(facts))}
    body+=['| Property | Value |','|---|---|']
    body += [f'| {md(k)} | {md(v)} |' for k,v in metrics.items() if v not in (None,'')]
    body+=['']
    for paragraph in doc.get('overview_notes',[]):body.extend([md(paragraph),''])
    sec('inventory','Dataset inventory')
    body+=['| Table | Role | Row grain | Primary key | Row count |', '|---|---|---|---|---:|']
    for t in tables:
        body.append(f'| [`{t["name"]}`](#{anchor(t["name"])}) | {md(t.get("role","fact"))} | {md(t.get("grain","Not specified"))} | `{md(", ".join(t.get("primary_key",[])) or "Not specified")}` | {md(t.get("row_count","Not measured"))} |')
    body+=['']
    sec('lifecycle','Business lifecycle & record grain')
    items=doc.get('lifecycle',[])
    if items:
        for i,s in enumerate(items,1):body.append(f'{i}. {md(s)}')
    else:body.append('The complete business-event sequence has not been specified.')
    body+=['','**Join-grain reminder:** do not sum measures after joining independent one-to-many event facts without pre-aggregation.','']
    sec('relationships','Relationship map')
    body+=['![Logical table relationship map](assets/relationship_map.png)','',
           '| Child field | Parent field | Cardinality | Optional? | Interpretation |','|---|---|---|---|---|']
    relationships=[]
    for t in tables:
        for r in t.get('relationships',[]):
            item=(t['name']+'.'+r.get('from_column',''),r.get('to_table','')+'.'+r.get('to_column',''),r.get('cardinality','N:1'), 'Yes' if r.get('optional') else 'No',r.get('meaning','Not specified'))
            relationships.append(item)
            body.append('| '+' | '.join(md(c) for c in item)+' |')
    if not relationships:body.append('| Not specified | Not specified | — | — | Confirm relationships before using multi-table joins. |')
    body+=['']
    for section,group in [('dimensions',dims),('facts',facts)]:
        sec(section,'Dimension tables' if section=='dimensions' else 'Fact & reference tables')
        if not group:body.append('None specified.\n')
        for t in group:
            nm=t['name'];cols=load_columns(t,frames.get(nm)); t['_all_cols']=cols
            body += [f'<a id="{anchor(nm)}"></a>', f'### `{nm}` — {md(t.get("title",nm))}', '',
                     md(t.get('description','Description not specified.'))+'\n',
                     f'**Role:** {md(t.get("role","fact"))}. **Grain:** {md(t.get("grain","Not specified"))}. **Primary key:** `{md(", ".join(t.get("primary_key",[])) or "Not specified")}`.','',
                     f'![First rows of {nm}](assets/{nm}.png)','',
                     '| Column | Type | Meaning | Constraints / relationships |','|---|---|---|---|']
            for c in cols:
                notes=[]
                if c.get('primary_key') or c['name'] in t.get('primary_key',[]):notes.append('Primary key')
                if c.get('nullable') is True:notes.append('Nullable')
                if c.get('nullable') is False:notes.append('Required')
                if c.get('derived'):notes.append('Derived')
                if c.get('unit'):notes.append('Unit: '+str(c['unit']))
                if c.get('note'):notes.append(str(c['note']))
                for r in t.get('relationships',[]):
                    if r.get('from_column')==c['name']:notes.append('→ `'+r['to_table']+'.'+r['to_column']+'`')
                body.append(f'| `{md(c["name"])}` | {md(c.get("type","Not specified"))} | {md(c.get("description","Not specified"))} | {md("; ".join(notes) or "—")} |')
            body+=['']
            if t.get('business_notes'):
                body.append('**Interpretation notes.** '+' '.join(str(x) for x in t['business_notes'])+'\n')
            rel=t.get('relationships',[])
            if rel:
                body.append('**Related tables.** '+'; '.join('`'+r.get('from_column','')+'` → `'+r.get('to_table','')+'.'+r.get('to_column','')+'`' for r in rel)+'.\n')
            body+=['[↑ Back to contents](#table-of-contents)','']
    sec('categorical-values','Categorical value dictionary')
    categorical_sections=0
    for t in tables:
        for c in t.get('_all_cols',[]):
            cats=c.get('categories')
            observed=scanned.get(t['name'],{}).get(c['name'],set())
            is_cat=bool(cats is not None or c.get('categorical'))
            if not is_cat:continue
            categorical_sections+=1
            body+= [f'### `{t["name"]}.{c["name"]}`','',
                    '| Value | Business meaning |','|---|---|']
            if isinstance(cats,dict):
                for k,v in cats.items():body.append(f'| `{md(k)}` | {md(v)} |')
                undiscovered=sorted(map(str,observed-set(map(str,cats))))
                for v in undiscovered[:50]:body.append(f'| `{md(v)}` | Meaning not defined |')
            elif isinstance(cats,list):
                for v in cats:body.append(f'| `{md(v)}` | Meaning not defined |')
            elif observed:
                for v in sorted(map(str,observed))[:50]:body.append(f'| `{md(v)}` | Meaning not defined |')
                if len(observed)>50:body.append('| Other values | High cardinality; confirm complete list |')
            else:body.append('| Not available | No full category enumeration supplied |')
            body+=['']
    if not categorical_sections:body+=['No categorical dictionary has been supplied. Review the data catalog for enumerated values.','']
    sec('conventions','Units, time & interpretation')
    rules=doc.get('conventions',[])
    if rules:
        for s in rules:body.append('- '+md(s))
    else:body.append('Units, calendar boundaries and timestamp semantics have not been fully specified.')
    body+=['']
    sec('quality','Data quality & validation')
    body+=['| Check | Expected rule / observation |','|---|---|']
    for check in doc.get('quality_checks',[]):
        body.append(f'| {md(check.get("name","Integrity check"))} | {md(check.get("rule","Not specified"))} |')
    if not doc.get('quality_checks'):body.append('| Uniqueness and referential integrity | Verify keys and child-parent matches before release. |')
    if doc.get('limitations'):
        body+=['','**Known limitations**','']
        for l in doc['limitations']:body.append('- '+md(l))
    body+=['']
    sec('use-cases','Analytical use cases')
    for u in doc.get('use_cases',[]):body.append('- '+md(u))
    if not doc.get('use_cases'):body.append('Define priority metrics and reporting questions from business requirements.')
    body+=['']
    sec('maintenance','Reproduction & maintenance')
    body += [f'**Data card version:** {md(doc.get("version","Not specified"))}.',
             f'**Updated:** {md(doc.get("updated_at",datetime.now(timezone.utc).date().isoformat()))}.','',
             'To refresh source previews and rebuild the relationship map, run the bundled `scripts/regenerate_assets.py` with the included `manifest.json` and the location of your CSV/Parquet tables.','',
             '```bash','python scripts/regenerate_assets.py --manifest manifest.json --data-dir /path/to/data --out .','```','']
    (output/'data_card.md').write_text('\n'.join(body)+'\n',encoding='utf-8')


def main():
    ap=argparse.ArgumentParser(description='Build professional Markdown data card and consistent table visuals')
    ap.add_argument('--manifest',type=Path,required=True)
    ap.add_argument('--data-dir',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True)
    ap.add_argument('--zip',action='store_true')
    ap.add_argument('--scan-categories',action='store_true',help='Stream complete bounded categorical values; may take time on big data')
    ap.add_argument('--count-rows',action='store_true',help='Count rows per data file (streaming CSV; Parquet metadata)')
    args=ap.parse_args()
    manifest=json.loads(args.manifest.read_text(encoding='utf-8'))
    doc=manifest.get('dataset',{});tables=manifest.get('tables',[])
    if not tables:raise SystemExit('Manifest must include a nonempty tables array.')
    names=[t['name'] for t in tables]
    if len(set(names))!=len(names):raise SystemExit('Duplicate table names in manifest.')
    out=args.out.resolve();assets=out/'assets';scripts=out/'scripts'
    assets.mkdir(parents=True,exist_ok=True);scripts.mkdir(parents=True,exist_ok=True)
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    hero(assets/'header.png',doc.get('name','Dataset'),doc.get('subtitle','Dataset documentation'),len(tables))
    source_paths={};frames={};scanned={}
    for t in tables:
        name=t['name'];path=find_file(args.data_dir,name);source_paths[name]=path
        df=first_rows(path);frames[name]=df
        if args.count_rows and path and t.get('row_count') is None:
            try:t['row_count']=count_rows(path)
            except Exception as exc:print(f'WARNING counting {name}: {exc}',file=sys.stderr)
        render_preview(assets/f'{name}.png',t,df,path.name if path else None)
        cat_fields=[c['name'] for c in t.get('columns',[]) if c.get('categorical')]
        scanned[name]=categories_by_scan(path,cat_fields) if args.scan_categories else {}
        if path is None:print('NOTE source absent:',name)
        else:print('PREVIEW:',name,'from',path)
    graph_assets(out,doc.get('name','Dataset'),tables)
    write_card(out,doc,tables,frames,source_paths,scanned)
    (out/'README.md').write_text(
        f'# {doc.get("name","Dataset")} — Data Card\n\n'
        'Open `data_card.md` in GitHub or VS Code Markdown Preview. The interactive table of contents links to each table and asset images load from `assets/`.\n\n'
        'The preview images show source-file first rows when readable files are present; otherwise they visibly indicate that preview data is unavailable.\n\n'
        '## Rebuild\n\n```bash\npip install pandas pillow pyarrow\n'
        'python scripts/regenerate_assets.py --manifest manifest.json --data-dir /path/to/data --out .\n```\n\n'
        'Optional: install Graphviz to render a relationship PNG. Use `--scan-categories` to enumerate bounded categorical values from complete tables.\n',encoding='utf-8')
    shutil.copyfile(Path(__file__),scripts/'regenerate_assets.py')
    if args.zip:
        zpath=out.parent/(out.name+'.zip')
        with zipfile.ZipFile(zpath,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=8) as z:
            for p in out.rglob('*'):
                if p.is_file():z.write(p,arcname=f'{out.name}/{p.relative_to(out)}')
        print('ZIP:',zpath)
    print('DATA CARD:',out/'data_card.md')

if __name__=='__main__':main()
