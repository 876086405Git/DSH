// What this Node build really has, read inside NodeMobile. A module that assumes one of these
// breaks only where it's missing, and the desktop never shows it. Each row answers on its own, so
// one missing feature can't hide the rest.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import zlib from 'node:zlib';
import moduleApi from 'node:module';

const rows = {};
const ask = (name, read) => {
  try {
    rows[name] = read();
  } catch (error) {
    rows[name] = `throws ${error?.name}: ${String(error?.message).slice(0, 100)}`;
  }
};
const sample = new Date(1700000000000);

ask('icu', () => process.versions.icu ?? null);
ask('i18nBuild', () => {
  const { v8_enable_i18n_support: i18n, icu_small: small } = process.config.variables;
  return { i18n, small };
});
ask('intl', () => typeof Intl);
ask('tzEnv', () => process.env.TZ ?? null);
ask('offsetMinutes', () => sample.getTimezoneOffset());
ask('dateString', () => sample.toString());
ask('resolvedZone', () => Intl.DateTimeFormat().resolvedOptions().timeZone);
ask('resolvedLocale', () => Intl.DateTimeFormat().resolvedOptions().locale);
ask('namedZone', () => new Intl.DateTimeFormat('en-US', { timeZone: 'Australia/Sydney', hour: 'numeric', hour12: false }).format(sample));
ask('zhFormat', () => new Intl.DateTimeFormat('zh-CN', { dateStyle: 'long' }).format(sample));
ask('toLocale', () => sample.toLocaleString('zh-CN'));
ask('numberFormat', () => new Intl.NumberFormat('zh-CN').format(1234567.5));
ask('segmenter', () => typeof Intl.Segmenter);
ask('collator', () => ['b', 'a'].sort(new Intl.Collator('zh').compare).join(''));
ask('regexLetter', () => new RegExp('\\p{L}+', 'u').exec('中文abc')?.[0]);
ask('regexXid', () => new RegExp('\\p{XID_Start}', 'u').test('中'));
ask('normalize', () => 'é'.normalize('NFD').length);
ask('fetch', () => typeof fetch);
ask('webSocket', () => typeof WebSocket);
ask('webAssembly', () => typeof WebAssembly);
ask('wasmCompiles', () => new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0])) instanceof WebAssembly.Module);
ask('decoderGbk', () => new TextDecoder('gbk').decode(new Uint8Array([0xd6, 0xd0])));
ask('decoderUtf16', () => new TextDecoder('utf-16le').decode(new Uint8Array([0x2d, 0x4e])));
ask('zstd', () => typeof zlib.zstdCompressSync);
ask('compileCache', () => typeof moduleApi.enableCompileCache);
ask('spawn', () => {
  const result = spawnSync('/bin/echo', ['ok'], { encoding: 'utf8', timeout: 3000 });
  return result.error ? `refused ${result.error.code}` : `ran ${result.status}`;
});
ask('timeContext', () => {
  const file = join(process.env.DSH_IOS_IMAGE_RUNTIME, 'node_modules/@deepseek-ai/dsh-time-context/lib/index.js');
  const lines = readFileSync(file, 'utf8').split('\n').filter(line => /timeZone|Intl\.|toLocale/.test(line));
  return lines.slice(0, 8).map(line => line.trim().slice(0, 110));
});

console.log(JSON.stringify(rows));
