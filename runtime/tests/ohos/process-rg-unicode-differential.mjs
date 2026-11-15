// Host-only native comparison: all valid scalars except LF, plus a separate LF probe.
import { RE2JS } from '../../ohos/process/build/re2js-unicode.mjs';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const rg = process.env.OHOS_NATIVE_RG;
if (!rg) throw new Error('OHOS_NATIVE_RG must name the bundled ripgrep 15.0.0 binary');
const temp = await mkdtemp(join(tmpdir(), 'rg-unicode-scalars-'));
const input = [];
for (let cp = 0; cp <= 0x10ffff; cp++) if ((cp < 0xd800 || cp > 0xdfff) && cp !== 10) input.push(String.fromCodePoint(cp), '\n');
const bytes = Buffer.from(input.join('')), array = Array.from(bytes), hash = bytes => createHash('sha256').update(bytes).digest('hex');
try {
  const path = join(temp,'scalars.txt'); await writeFile(path, bytes);
  const records = [];
  for (const pattern of ['\\w','\\d','\\s','\\W','\\D','\\S','\\b.\\b','\\B.\\B']) {
    const original = spawnSync(rg, ['--no-config', '--text', '--only-matching', pattern, path], { maxBuffer: 16 * 1024 * 1024 });
    if (original.error || original.status !== 0) throw original.error || new Error(original.stderr.toString());
    const matcher = RE2JS.compile(pattern).matcher(array), chunks = [];
    while (matcher.find()) {
      const value = bytes.subarray(matcher.start(), matcher.end()).toString('utf8');
      // rg is line-oriented and does not expose line separators as matches.
      if (value !== '\n') chunks.push(value, '\n');
    }
    const actual = Buffer.from(chunks.join(''));
    const expectedSet = new Set(original.stdout.toString().split('\n').filter(Boolean)), actualSet = new Set(actual.toString().split('\n').filter(Boolean));
    const extra = [...actualSet].filter(cp => !expectedSet.has(cp)).slice(0,20).map(cp => cp.codePointAt(0).toString(16));
    const missing = [...expectedSet].filter(cp => !actualSet.has(cp)).slice(0,20).map(cp => cp.codePointAt(0).toString(16));
    records.push({ pattern, equal: original.stdout.equals(actual), nativeCount: expectedSet.size, candidateCount: actualSet.size, nativeSHA256: hash(original.stdout), candidateSHA256: hash(actual), extra, missing });
    console.error(JSON.stringify(records.at(-1)));
  }
  const lfPath=join(temp,'lf.txt');await writeFile(lfPath,'\n');
  const lf=[];
  for(const {pattern} of records){
    const native=spawnSync(rg,['--no-config','--json','--multiline','--text',pattern,lfPath],{maxBuffer:1024*1024});
    if(native.error||native.status>1)throw native.error||new Error(native.stderr.toString());
    const expected=native.stdout.toString().split('\n').filter(Boolean).map(JSON.parse).some(x=>x.type==='match');
    const actual=RE2JS.compile(pattern).matches([10]);lf.push({pattern,native:expected,candidate:actual,equal:expected===actual});
  }
  console.log(JSON.stringify({ rgSHA256:hash(await readFile(rg)),scriptSHA256:hash(await readFile(new URL(import.meta.url))),candidateSHA256:hash(await readFile(new URL('../../ohos/process/build/re2js-unicode.mjs',import.meta.url))),lf, nativeVersion: spawnSync(rg,['--version'],{encoding:'utf8'}).stdout, node:process.version, nodeUnicode:process.versions.unicode, candidateUnicode:'16.0', scalarValues:0x110000-0x800-1, inputBytes:bytes.length, inputSHA256:hash(bytes), records },null,2));
  if(records.some(r=>!r.equal)||lf.some(r=>!r.equal))process.exitCode=1;
} finally { await rm(temp,{recursive:true,force:true}); }
