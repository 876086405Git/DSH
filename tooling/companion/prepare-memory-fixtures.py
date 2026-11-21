#!/usr/bin/env python3
"""明确重建当前合成夹具源的哈希清单；不运行测试，不产生通过结果。"""
import argparse
from hashlib import sha256
import json
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cases', type=Path, default=Path(__file__).with_name('memory-replay-cases.json'))
parser.add_argument('--output', type=Path, default=Path(__file__).with_name('memory-model-fixtures.json'))
args = parser.parse_args()
manifest = json.loads(args.cases.read_text(encoding='utf-8'))
if manifest['fixture_version'] != 1 or manifest['ruleset'] != '09e-r2+r2.1':
    raise ValueError('unsupported fixture/rules version')
root = Path(__file__).resolve().parents[2]
catalog = {'fixture_version': 1, 'kind': 'compiled-product-fixtures',
           'sources': [{'path': path, 'sha256': sha256((root / path).read_bytes()).hexdigest()}
                       for path in manifest['fixture_sources']]}
args.output.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
print(json.dumps({'status': 'PREPARED_NOT_RUN', 'sources': len(catalog['sources']),
                  'sha256': sha256(args.output.read_bytes()).hexdigest()}))
