#!/usr/bin/env python3
"""Build isolated evaluation copies; never edit the production publisher."""
from pathlib import Path
import hashlib
import json
import sys

baseline = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
expected = 'c774041d8174cd495bfcb4e2deda2dc3f5eb8100ffcb5557ceae2a107d7f78cc'
original = baseline.read_bytes()
assert hashlib.sha256(original).hexdigest() == expected, 'The experiment only covers the approved 30 core'
source = original.decode()
call = 'await legacyExclusiveCopy(source, target, activeFs, signal);'
assert source.count(call) == 1
guarded_helper = '''
// Evaluation only: reopen the completed temporary without following a symlink,
// pin the opened inode, and verify it before creating the final file.
async function guardedTemporaryCopy(receipt, target, fs, signal) {
  const input = await fs.open(receipt.path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const info = await input.stat({ bigint: true });
    if (!info.isFile() || !sameIdentity(info, receipt)) {
      throw Object.assign(new Error('Completed publication temporary was replaced'),
        { code: 'ERR_OHOS_PUBLICATION_TEMP_REPLACED' });
    }
    const output = await fs.open(target, 'wx', 0o600);
    try { await copyStream(input, output, signal); }
    finally { await output.close(); }
  } finally { await input.close(); }
}

'''
variants = {
    'baseline': source,
    'naive': source.replace(call, 'await legacyExclusiveCopy(receipt.path, target, activeFs, signal);'),
    'guarded': source.replace("import { lstatSync, unlinkSync }", "import { constants, lstatSync, unlinkSync }")
        .replace('/**\n * Build a publisher', guarded_helper + '/**\n * Build a publisher')
        .replace(call, 'await guardedTemporaryCopy(receipt, target, activeFs, signal);'),
}
output.mkdir(parents=True, exist_ok=True)
manifest = {'baselinePath': str(baseline), 'baselineSHA256': expected,
            'scope': 'isolated evaluation copies of approved 30 core, not M3b production edits', 'variants': {}}
for name, text in variants.items():
    path = output / (name + '.mjs')
    data = text.encode()
    path.write_bytes(data)
    manifest['variants'][name] = {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
(output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
