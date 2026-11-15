#!/usr/bin/env python3
"""Fetch only the pinned public source files needed for the M3-1 audit."""
import argparse, hashlib, json, pathlib, urllib.request
parser=argparse.ArgumentParser()
parser.add_argument('destination',type=pathlib.Path)
args=parser.parse_args()
manifest=pathlib.Path(__file__).with_name('publication-source-manifest.json')
args.destination.mkdir(parents=True,exist_ok=True)
for record in json.loads(manifest.read_text())['files']:
    target=args.destination/record['name']
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest()==record['sha256']:
        print(record['name']+' verified existing')
        continue
    with urllib.request.urlopen(record['url'],timeout=30) as response:
        if response.status!=200:
            raise RuntimeError('HTTP failure: '+record['name'])
        data=response.read()
    if len(data)!=record['bytes'] or hashlib.sha256(data).hexdigest()!=record['sha256']:
        raise RuntimeError('Source bytes did not match pinned manifest: '+record['name'])
    target.write_bytes(data)
    print(record['name']+' downloaded and verified')
