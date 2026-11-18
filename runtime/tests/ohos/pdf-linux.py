#!/usr/bin/env python3
"""Real FS/native opener/ETS logic plus Poppler oracle fixtures, NOT an HMS PDF implementation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--node', required=True, type=Path)
parser.add_argument('--node-headers', required=True, type=Path)
parser.add_argument('--typescript-prefix', required=True, type=Path)
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--cxx', default='clang++-18')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[3]
out = args.out.resolve()
out.mkdir(parents=True, exist_ok=True)
fixtures = out / 'fixtures'
fixtures.mkdir(exist_ok=True)
commands = []
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()

def run(name, argv, env=None):
    start = time.time()
    with (out / (name + '.log')).open('wb') as log:
        try:
            code = subprocess.run(argv, cwd=repo, env=dict(os.environ, **(env or {})), stdout=log,
                                  stderr=subprocess.STDOUT, timeout=180).returncode
        except subprocess.TimeoutExpired:
            code = 124
    commands.append({'name': name, 'argv': argv, 'environment': env or {}, 'exitCode': code, 'elapsedSeconds': time.time() - start})
    (out / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
    return code

# Original two-page PDF made from exact drawing commands, with no external copyrighted source.
contents = [b'1 0 0 rg 0 0 200 300 re f\n0 0 1 rg 20 30 100 150 re f\n',
            b'0 1 0 rg 0 0 400 200 re f\n1 1 0 rg 50 40 100 80 re f\n']
objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Count 2 /Kids [3 0 R 5 0 R] >>',
           b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 300] /Resources << >> /Contents 4 0 R >>',
           b'<< /Length ' + str(len(contents[0])).encode() + b' >>\nstream\n' + contents[0] + b'endstream',
           b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 200] /Resources << >> /Contents 6 0 R >>',
           b'<< /Length ' + str(len(contents[1])).encode() + b' >>\nstream\n' + contents[1] + b'endstream']
pdf = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
offsets = [0]
for i, obj in enumerate(objects, 1):
    offsets.append(len(pdf)); pdf.extend(str(i).encode() + b' 0 obj\n' + obj + b'\nendobj\n')
xref = len(pdf)
pdf.extend(b'xref\n0 7\n0000000000 65535 f \n')
for offset in offsets[1:]: pdf.extend(f'{offset:010d} 00000 n \n'.encode())
pdf.extend(b'trailer\n<< /Size 7 /Root 1 0 R >>\nstartxref\n' + str(xref).encode() + b'\n%%EOF\n')
(fixtures / 'sample.pdf').write_bytes(pdf)
assert run('pdfinfo-version', ['pdfinfo', '-v']) == 0
assert run('pdfinfo', ['pdfinfo', '-f', '1', '-l', '2', '-box', str(fixtures / 'sample.pdf')]) == 0
text = (out / 'pdfinfo.log').read_text()
pages = [{'width': int(float(w)), 'height': int(float(h))}
         for _, w, h in re.findall(r'^Page\s+(\d+) size:\s+([\d.]+) x ([\d.]+) pts', text, re.M)]
assert pages == [{'width': 200, 'height': 300}, {'width': 400, 'height': 200}], text
(fixtures / 'pdf.json').write_text(json.dumps({'pages': pages, 'pdfSha256': sha(fixtures / 'sample.pdf')}, indent=2) + '\n')
for width, height in [(64, 96), (100, 150), (1080, 1620), (2400, 3600)]:
    prefix = fixtures / f'page-{width}x{height}'
    assert run(f'render-{width}', ['pdftoppm', '-f', '1', '-l', '1', '-scale-to-x', str(width), '-scale-to-y', str(height),
                                 '-png', '-singlefile', str(fixtures / 'sample.pdf'), str(prefix)]) == 0
    rendered = prefix.with_suffix('.png').read_bytes()
    assert rendered[:8] == b'\x89PNG\r\n\x1a\n' and struct.unpack('>II', rendered[16:24]) == (width, height)

addon = out / 'user-file-access.node'
native_source = repo / 'runtime/tests/ohos/user-file-access-addon.cc'
assert run('native-build', [args.cxx, '-std=c++17', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                            '-I', str(args.node_headers.resolve()), str(native_source), '-o', str(addon)]) == 0
paths = [repo / 'app/ohos/entry/src/main/ets/plugins/HmsPdfKit.ets', repo / 'app/ohos/entry/src/main/ets/plugins/HmsKits.ets', repo / 'app/ohos/entry/src/main/ets/plugins/HmsPdfPages.ets', repo / 'app/ohos/entry/src/main/ets/plugins/PdfInput.ets',
         repo / 'app/ohos/entry/src/main/ets/plugins/FilesMediaPlugin.ets', repo / 'runtime/tests/ohos/files-pdf-channel.test.mjs',
         native_source, repo / 'app/ohos/entry/src/main/cpp/file_access.h', *sorted((repo / 'runtime/tests/ohos').glob('pdf-*'))]
for p in paths:
    target = out / 'sources' / p.relative_to(repo)
    target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(p.read_bytes())
env = {'OHOS_PDF_FIXTURES': str(fixtures), 'OHOS_TYPESCRIPT_PREFIX': str(args.typescript_prefix.resolve()),
       'OHOS_USER_FILE_ADDON': str(addon), 'OHOS_PDF_RENDER_OUTPUT': str(out / 'actual-returned.png')}
code = run('logic', [str(args.node.resolve()), '--test', '--test-isolation=none', '--test-reporter=tap',
                     str(repo / 'runtime/tests/ohos/pdf-pages.test.mjs'), str(repo / 'runtime/tests/ohos/files-pdf-channel.test.mjs')], env)
counts = {k: int(v) for k, v in re.findall(r'^# (tests|pass|fail|cancelled|skipped) (\d+)$', (out / 'logic.log').read_text(), re.M)}
report = {'exitCode': code, 'counts': counts, 'sources': {str(p.relative_to(repo)): sha(p) for p in paths},
          'nodeSha256': sha(args.node.resolve()), 'addonSha256': sha(addon),
          'fixtures': {p.name: sha(p) for p in sorted(fixtures.iterdir())},
          'scope': 'Actual ETS + Linux FS + production native opener; real Poppler metadata/PNG fixtures; HMS PDF and image handles are explicit doubles; UNCOMPILED_HMS'}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'exitCode': code, 'counts': counts, 'report': str(out / 'report.json')}, indent=2))
raise SystemExit(code)
