import assert from 'node:assert/strict';
import { test } from 'node:test';
import { readFile, writeFile, mkdir, mkdtemp, readdir, stat, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFile, spawn } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { canReadReceiptPdf, readReceiptPdf } from '../bridge/dsh-go-bridge/lib/companion/receipt-pdf.js';
import { ordinary, textLines, paintImage, imageDate, chinese, chinesePdf, encryptedPdf } from './fixtures/companion-receipt-pdf.mjs';

const text = ordinary([textLines(['DATE 2026-11-20', 'ITEM TRAIN', 'AMOUNT CNY 80.00'])]);
const texts = result => result.pages.map(page => page.lines.map(line => line.text));

async function childOutput(args, env = process.env) {
  const child = spawn(process.execPath, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '', errors = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { errors += chunk; });
  const timeout = setTimeout(() => child.kill('SIGKILL'), 5000);
  try {
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
    assert.equal(code, 0, errors);
    return output.trim();
  } finally { clearTimeout(timeout); }
}

test('PDF production worker returns actual extraction lines without detaching the original bytes', async () => {
  assert.equal(canReadReceiptPdf(), true);
  const before = createHash('sha256').update(text).digest('hex');
  const result = await readReceiptPdf(text);
  assert.deepEqual(result, {
    pageCount: 1,
    pages: [{ page: 1, lines: [
      { line: 1, text: 'DATE 2026-11-20' },
      { line: 2, text: 'ITEM TRAIN' },
      { line: 3, text: 'AMOUNT CNY 80.00' },
    ] }],
    textLayerOnly: true, fullTextExtraction: true,
  });
  assert.equal(createHash('sha256').update(text).digest('hex'), before);
});

test('PDF scan and mixed pages never invent the date contained only in image pixels', async () => {
  const result = await readReceiptPdf(ordinary([
    paintImage,
    textLines(['AMOUNT CNY 80.00']) + '\n' + paintImage,
  ]));
  assert.equal(result.pageCount, 2);
  assert.deepEqual(texts(result), [[], ['AMOUNT CNY 80.00']]);
  assert.equal(JSON.stringify(result).includes(imageDate), false);
  assert.equal(result.textLayerOnly, true);
  // This means all text-layer reads ended; it says nothing about image contents.
  assert.equal(result.fullTextExtraction, true);
});

test('PDF Chinese ToUnicode mapping stays in the library extraction order', async () => {
  assert.deepEqual(texts(await readReceiptPdf(chinesePdf)), [[chinese]]);
});

test('PDF document OpenAction is not executed by text extraction', async () => {
  const result = await readReceiptPdf(ordinary([textLines(['AMOUNT CNY 80.00'])], { action: true }));
  assert.deepEqual(texts(result), [['AMOUNT CNY 80.00']]);
});

test('PDF invalid data and input or page limits reject instead of returning empty success', async () => {
  await assert.rejects(readReceiptPdf(Buffer.from('not a PDF')), { code: 'pdf_invalid' });
  await assert.rejects(readReceiptPdf(Buffer.alloc(4 * 1024 * 1024 + 1)), { code: 'pdf_input_limit' });
  await assert.rejects(readReceiptPdf(ordinary(Array(6).fill(textLines(['DATE 2026-11-20'])))), { code: 'pdf_page_limit' });
});

test('PDF compressed text exceeding the requested output budget rejects in the worker', async () => {
  const compressed = ordinary([textLines(Array(64).fill('AMOUNT CNY 80.00'))], { compressed: true, pageHeight: 2000 });
  assert.ok(compressed.byteLength < 4096);
  await assert.rejects(readReceiptPdf(compressed, { maxTextBytes: 128 }), { code: 'pdf_text_limit' });
});

test('PDF finite compressed content exceeding the item budget rejects without returning a truncated page', async () => {
  const content = Array.from({ length: 50001 }, (_, i) =>
    `BT /F1 1 Tf 20 ${i % 2 ? 180 : 190} Td (X) Tj ET`).join('\n');
  const compressed = ordinary([content], { compressed: true });
  assert.ok(compressed.byteLength < 16000);
  await assert.rejects(readReceiptPdf(compressed), { code: 'pdf_item_limit' });
});

test('PDF password-protected document is unavailable rather than an empty receipt', async () => {
  await assert.rejects(readReceiptPdf(encryptedPdf()), { code: 'pdf_password_required' });
});

test('PDF already aborted input does not enter extraction', async () => {
  const reason = new Error('original task already cancelled');
  const signal = AbortSignal.abort(reason);
  await assert.rejects(readReceiptPdf(text, { signal }), error => error === reason);
});

test('PDF active worker is terminated by the original abort and releases the child process', async () => {
  // Abort after the real API has constructed its worker, without waiting on a
  // guessed parser delay. The child can exit only when the worker is gone.
  const source = `
    import assert from 'node:assert/strict';
    import { readReceiptPdf } from ${JSON.stringify(new URL('../bridge/dsh-go-bridge/lib/companion/receipt-pdf.js', import.meta.url).href)};
    const controller = new AbortController();
    const reason = new Error('original deadline reached');
    const pending = readReceiptPdf(new Uint8Array(${JSON.stringify([...text])}), {signal:controller.signal});
    setImmediate(() => controller.abort(reason));
    await assert.rejects(pending, error => error === reason);
    console.log('original-abort-observed');
  `;
  assert.equal(await childOutput(['--no-addons', '--input-type=module', '-e', source]), 'original-abort-observed');
});

test('PDF worker preserves a real inherited preload and refuses ambient optional canvas under jitless', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'companion-pdf-preload-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const record = join(directory, 'preload.jsonl');
  const sentinel = join(directory, 'canvas-loaded.txt');
  const modules = join(directory, 'node_modules');
  const canvas = join(modules, '@napi-rs', 'canvas');
  await mkdir(canvas, { recursive: true });
  await writeFile(join(canvas, 'index.js'), "require('node:fs').writeFileSync(process.env.J_PDF_NATIVE_PROBE,'loaded'); module.exports={};\n");
  const preload = join(directory, 'owner-preload.mjs');
  await writeFile(preload, `import {appendFileSync} from 'node:fs';
    import {isMainThread,threadId} from 'node:worker_threads';
    appendFileSync(process.env.J_PDF_PRELOAD_PROBE,JSON.stringify({isMainThread,threadId,wasm:typeof WebAssembly})+'\\n');\n`);
  const entry = join(directory, 'read.mjs');
  await writeFile(entry, `import {readReceiptPdf} from ${JSON.stringify(new URL('../bridge/dsh-go-bridge/lib/companion/receipt-pdf.js', import.meta.url).href)};
    const result=await readReceiptPdf(new Uint8Array(${JSON.stringify([...text])}));
    console.log(JSON.stringify(result.pages[0].lines.map(line=>line.text)));\n`);
  const result = await childOutput(['--no-addons', '--jitless', '--import', preload, entry], {
    ...process.env, NODE_PATH: modules, J_PDF_NATIVE_PROBE: sentinel, J_PDF_PRELOAD_PROBE: record,
  });
  assert.deepEqual(JSON.parse(result), ['DATE 2026-11-20', 'ITEM TRAIN', 'AMOUNT CNY 80.00']);
  const observed = (await readFile(record, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.equal(observed.length, 2);
  assert.deepEqual(observed.map(row => row.isMainThread), [true, false]);
  assert.ok(observed.every(row => row.wasm === 'undefined'));
  await assert.rejects(readFile(sentinel), { code: 'ENOENT' });
});

test('PDF runtime gate declines an older advertised Node without loading the parser', async () => {
  const descriptor = Object.getOwnPropertyDescriptor(process.versions, 'node');
  try {
    Object.defineProperty(process.versions, 'node', { ...descriptor, value: '20.20.0' });
    assert.equal(canReadReceiptPdf(), false);
    await assert.rejects(readReceiptPdf(text), { code: 'pdf_runtime_unavailable' });
  } finally { Object.defineProperty(process.versions, 'node', descriptor); }
});

test('PDF extraction resolves the exact installed dependency and keeps its licenses', async () => {
  const bridge = new URL('../bridge/dsh-go-bridge/', import.meta.url);
  const require = createRequire(new URL('package.json', bridge));
  const root = new URL('./', pathToFileURL(require.resolve('pdfjs-dist/package.json')));
  const lock = JSON.parse(await readFile(new URL('package-lock.json', bridge), 'utf8'));
  const pinned = lock.packages['node_modules/pdfjs-dist'];
  assert.equal(pinned.version, '6.5.438');
  assert.equal(pinned.integrity, 'sha512-vg8Pw1x+AFKy4AMDvhuWl5cOYV8d698UoEANoFFhc79hqXDnZQqnOXoxw3HG907WHOg1JYOvLhP756boddFxpA==');
  const manifest = await readFile(new URL('package.json', root));
  assert.equal(createHash('sha256').update(manifest).digest('hex'),
    'bf96384ed16c41f33b30f8d7461c3da61c971c17438b6f81e95a225af794db45');
  for (const name of ['LICENSE', 'cmaps/LICENSE', 'standard_fonts/LICENSE_FOXIT', 'standard_fonts/LICENSE_LIBERATION']) {
    assert.ok((await readFile(new URL(name, root))).byteLength > 0, name);
  }
  await assert.rejects(readFile(new URL('lib/companion/pdfjs-6.5.438/manifest.json', bridge)), { code: 'ENOENT' });
});

test('PDF staged bridge extracts real text with the exact installed subset and no native canvas', async t => {
  // The runtime CI job installs the real locked package before this suite.
  // Missing dependencies must fail here, not turn into a tooling-fixture pass.
  const directory = await mkdtemp(join(tmpdir(), 'companion-pdf-stage-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const bridge = fileURLToPath(new URL('../bridge/dsh-go-bridge/', import.meta.url));
  const staged = join(directory, 'bridge');
  await promisify(execFile)('python3', ['-I',
    fileURLToPath(new URL('../lib/bridge_dependencies.py', import.meta.url)),
    '--prefix', bridge, '--out', staged], { timeout: 15000 });
  await assert.rejects(stat(join(staged, 'lib/companion/pdfjs-6.5.438')), { code: 'ENOENT' });
  await assert.rejects(stat(join(staged, 'node_modules/@napi-rs')), { code: 'ENOENT' });
  const subset = join(staged, 'node_modules/pdfjs-dist');
  const files = [];
  for (const name of await readdir(subset, { recursive: true })) {
    if (!(await stat(join(subset, name))).isFile()) continue;
    files.push(name);
    assert.deepEqual(await readFile(join(subset, name)),
      await readFile(join(bridge, 'node_modules/pdfjs-dist', name)), name);
  }
  assert.equal(files.length, 190);
  const entry = join(directory, 'extract.mjs');
  await writeFile(entry, `
    import assert from 'node:assert/strict';
    import {readReceiptPdf} from ${JSON.stringify(pathToFileURL(join(staged, 'lib/companion/receipt-pdf.js')).href)};
    import {ordinary,textLines} from ${JSON.stringify(new URL('./fixtures/companion-receipt-pdf.mjs', import.meta.url).href)};
    const result=await readReceiptPdf(ordinary([textLines(['DATE 2026-11-20'])]));
    assert.deepEqual(result.pages[0].lines,[{line:1,text:'DATE 2026-11-20'}]);
  `);
  await childOutput(['--jitless', '--no-addons', entry]);
});
