#!/usr/bin/env python3
"""Sanity-check a generated dataset-card folder and optional manifest."""
import argparse
import json
from pathlib import Path
import re
import sys


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument('folder',type=Path)
    ap.add_argument('--manifest',type=Path)
    args=ap.parse_args()
    folder=args.folder
    doc=folder/'data_card.md'
    if not doc.is_file():raise SystemExit('FAIL: missing data_card.md')
    s=doc.read_text(encoding='utf-8')
    problems=[]
    ids=re.findall(r'<a id="([^"]+)"></a>',s)
    anchors=set(ids)
    if len(ids)!=len(anchors):problems.append('duplicate anchor IDs')
    for dest in re.findall(r'\]\(#([a-zA-Z0-9_-]+)\)',s):
        if dest not in anchors:problems.append(f'broken anchor #{dest}')
    for path in re.findall(r'!\[[^]]*\]\(([^)]+)\)',s):
        if not (folder/path).is_file():problems.append('missing image '+path)
    for prohibited in ['**Source transparency:**','**Not real commerce data.**','## Sources & traceability','## Provenance & composition']:
        if prohibited.lower() in s.lower():problems.append('excluded presentation element remains')
    if '<details open>' not in s:problems.append('missing collapsible table of contents')
    if args.manifest:
        manifest=json.loads(args.manifest.read_text(encoding='utf-8'))
        for t in manifest['tables']:
            name=t['name']
            if f'<a id="{name}"></a>' not in s:problems.append(f'missing table section: {name}')
            if not (folder/'assets'/f'{name}.png').is_file():problems.append(f'missing table preview: {name}')
            for c in t.get('columns',[]):
                if f'`{c["name"]}`' not in s:problems.append(f'missing field {name}.{c["name"]}')
                if c.get('categorical') and f'### `{name}.{c["name"]}`' not in s:problems.append(f'missing categorical dictionary: {name}.{c["name"]}')
    if problems:
        for x in problems:print('FAIL:',x)
        raise SystemExit(1)
    print(f'PASS: {len(anchors)} unique anchors; image paths and required sections validated.')

if __name__=='__main__':main()
