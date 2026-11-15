#!/usr/bin/env python3
"""Fetch only the pinned public research sources; never install a runtime input."""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    pins = json.loads(Path(__file__).with_name('sources.json').read_text())
    args.cache.mkdir(parents=True, exist_ok=True)
    result = []
    for row in pins['files']:
        target = args.cache / row['name']
        if target.exists():
            data = target.read_bytes()
            origin = 'existing-cache'
        else:
            request = urllib.request.Request(row['url'], headers={'User-Agent': 'dsh-go-source-research'})
            with urllib.request.urlopen(request, timeout=30) as response:
                if response.status != 200:
                    raise RuntimeError('Unexpected HTTP status for ' + row['name'])
                data = response.read(row['bytes'] + 1)
            origin = 'download'
        if len(data) != row['bytes'] or hashlib.sha256(data).hexdigest() != row['sha256']:
            raise RuntimeError('Source identity mismatch: ' + row['name'])
        if origin == 'download':
            target.write_bytes(data)
        result.append({'name': row['name'], 'sha256': row['sha256'], 'origin': origin})
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
