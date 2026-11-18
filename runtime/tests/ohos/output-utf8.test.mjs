import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, isAbsolute } from 'node:path';
import { pathToFileURL } from 'node:url';

// This test-only input selects an independently patched fixed npm module.
// No production environment switch is introduced by the output patch.
const modulePath = process.env.DSH_OUTPUT_COLLECTOR_TEST_MODULE;
const moduleSha = process.env.DSH_OUTPUT_COLLECTOR_TEST_SHA256;
assert(modulePath && isAbsolute(modulePath), 'DSH_OUTPUT_COLLECTOR_TEST_MODULE must be an absolute module path');
assert.match(moduleSha ?? '', /^[a-f0-9]{64}$/, 'the exact module SHA256 is required');
const actual = createHash('sha256').update(await readFile(modulePath)).digest('hex');
assert.equal(actual, moduleSha);
const { OutputCollector } = await import(pathToFileURL(modulePath).href);
const make = () => new OutputCollector(4096, 'stdout');
const hex = text => Buffer.from(text, 'utf8').toString('hex');

test('跨读取的完整三字节字符没有替换字符，nextOffset停在未完整字节之前', () => {
  const reader = make();
  reader.push(Buffer.from([0xe4, 0xb8]));
  const first = reader.readFrom(0);
  assert.deepEqual(first, { text: '', nextOffset: 0, lossy: false });
  reader.push(Buffer.from([0xad]));
  reader.seal();
  const second = reader.readFrom(first.nextOffset);
  assert.deepEqual(second, { text: '中', nextOffset: 3, lossy: false });
  assert.equal(first.text + second.text, '中');
  assert.equal(reader.readFrom(0).text, '中');
  assert.equal(reader.snapshot().bytes.toString('hex'), 'e4b8ad');
});

test('两个读者在2/3/4字节字符的所有内部切点独立读取，完整前缀仍立即返回', () => {
  for (const character of ['¢', '中', '🙂']) {
    const bytes = Buffer.from(character);
    for (let cut = 1; cut < bytes.length; cut++) {
      const reader = make();
      reader.push(Buffer.concat([Buffer.from('A'), bytes.subarray(0, cut)]));
      const a1 = reader.readFrom(0);
      assert.deepEqual(a1, { text: 'A', nextOffset: 1, lossy: false });
      const b1 = reader.readFrom(0);
      assert.deepEqual(b1, a1);
      assert.deepEqual(reader.readFrom(a1.nextOffset), { text: '', nextOffset: 1, lossy: false });
      reader.push(Buffer.concat([bytes.subarray(cut), Buffer.from('Z')]));
      const a2 = reader.readFrom(a1.nextOffset);
      assert.deepEqual(a2, { text: character + 'Z', nextOffset: bytes.length + 2, lossy: false });
      assert.deepEqual(reader.readFrom(b1.nextOffset), a2);
      assert.equal(reader.readFrom(0).text, 'A' + character + 'Z');
      reader.seal();
      assert.equal(reader.readFrom(a2.nextOffset).text, '');
    }
  }
});

test('逐字节输入合法UTF8边界字符，拼接结果等于一次性解码且没有容量损失', () => {
  const expected = 'A\u007f\u0080\u07ff\u0800\ud7ff\ue000\uffff\u{10000}\u{10ffff}中🙂Z';
  const bytes = Buffer.from(expected);
  const reader = make();
  let offset = 0, text = '';
  for (const byte of bytes) {
    reader.push(Buffer.from([byte]));
    const read = reader.readFrom(offset);
    assert.equal(read.lossy, false);
    assert(read.nextOffset >= offset && read.nextOffset <= reader.snapshot().totalBytes);
    text += read.text;
    offset = read.nextOffset;
  }
  reader.seal();
  const tail = reader.readFrom(offset);
  text += tail.text;
  assert.equal(text, expected);
  assert.equal(tail.nextOffset, bytes.length);
  assert.equal(reader.readFrom(0).text, expected);
});

test('非法UTF8与合法未完整前缀混合，所有二段切点保持原Buffer替换结果', () => {
  for (const inputHex of [
    '80', 'c0af', 'c1bf', 'f5808080', 'e08080', 'eda080', 'f0808080', 'f4908080',
    'e28241', 'c2c2a2', 'e480e4b8ad', '41f09f99825ae4b8', 'f09f41e4b8ad',
  ]) {
    const input = Buffer.from(inputHex, 'hex');
    for (let cut = 0; cut <= input.length; cut++) {
      const reader = make();
      reader.push(input.subarray(0, cut));
      const first = reader.readFrom(0);
      reader.push(input.subarray(cut));
      const second = reader.readFrom(first.nextOffset);
      reader.seal();
      const tail = reader.readFrom(second.nextOffset);
      assert.equal(hex(first.text + second.text + tail.text), hex(input.toString('utf8')), `${inputHex} split ${cut}`);
      assert.equal(tail.nextOffset, input.length);
      assert.equal(reader.readFrom(0).text, input.toString('utf8'));
      assert.equal(reader.snapshot().bytes.toString('hex'), inputHex);
    }
  }
});

test('已不可能构成合法UTF8的尾部立即返回，不为非法字节保留游标', () => {
  for (const inputHex of ['80', 'c0', 'c1', 'f5', 'e080', 'eda0', 'f080', 'f490']) {
    const bytes = Buffer.from(inputHex, 'hex'), reader = make();
    reader.push(bytes);
    assert.deepEqual(reader.readFrom(0), { text: bytes.toString('utf8'), nextOffset: bytes.length, lossy: false }, inputHex);
  }
});

test('无spill的seal也交付真实终态残片；重复seal和续读不重复文本', () => {
  for (const inputHex of ['c2', 'e4', 'e4b8', 'f0', 'f09f', 'f09f99']) {
    const bytes = Buffer.from(inputHex, 'hex'), reader = make();
    reader.push(bytes);
    const live = reader.readFrom(0);
    assert.deepEqual(live, { text: '', nextOffset: 0, lossy: false });
    reader.seal();
    const ended = reader.readFrom(live.nextOffset);
    assert.deepEqual(ended, { text: bytes.toString('utf8'), nextOffset: bytes.length, lossy: false });
    reader.seal();
    assert.deepEqual(reader.readFrom(ended.nextOffset), { text: '', nextOffset: bytes.length, lossy: false });
    assert.deepEqual(reader.readFrom(0), ended);
    assert.equal(reader.snapshot().bytes.toString('hex'), inputHex);
  }
});

test('finalize仍是终态屏障，完整字符串和真实残片保持原最终输出', () => {
  for (const inputHex of ['e4b8ad', '41e4b8', '', 'ff']) {
    const bytes = Buffer.from(inputHex, 'hex'), reader = make();
    reader.push(bytes);
    const before = reader.snapshot();
    assert.deepEqual(reader.finalize(), { text: bytes.toString('utf8'), truncated: false });
    assert.deepEqual(reader.finalize(), { text: bytes.toString('utf8'), truncated: false });
    assert.deepEqual(reader.snapshot(), before);
    assert.equal(reader.readFrom(0).nextOffset, bytes.length);
  }
});

test('ASCII尾窗与任意字节offset语义不变，两个读者不互相消费', () => {
  const reader = new OutputCollector(8, 'stdout');
  reader.push(Buffer.from('0123456789ABCDEFGHIJ'));
  const first = { text: 'CDEFGHIJ', nextOffset: 20, lossy: true };
  assert.deepEqual(reader.readFrom(0), first);
  assert.deepEqual(reader.readFrom(0), first);
  assert.deepEqual(reader.readFrom(17), { text: 'HIJ', nextOffset: 20, lossy: false });
  reader.seal();
  assert.deepEqual(reader.readFrom(20), { text: '', nextOffset: 20, lossy: false });
});

test('容量不足导致UTF8头部被裁剪仍明确lossy，不伪造完整字符', () => {
  const reader = new OutputCollector(2, 'stdout');
  reader.push(Buffer.from([0xe4, 0xb8]));
  const first = reader.readFrom(0);
  assert.deepEqual(first, { text: '', nextOffset: 0, lossy: false });
  reader.push(Buffer.from([0xad]));
  const expected = { text: Buffer.from([0xb8, 0xad]).toString('utf8'), nextOffset: 3, lossy: true };
  assert.deepEqual(reader.readFrom(first.nextOffset), expected);
  reader.seal();
  assert.deepEqual(reader.readFrom(0), expected);
  assert.deepEqual(reader.snapshot(), { bytes: Buffer.from([0xb8, 0xad]), totalBytes: 3 });
});

test('真实spill保持完整原字节及路径，lossy尾窗仍用原裁剪语义', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'output-utf8-spill-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const failures = [];
  const reader = new OutputCollector(2, 'stdout', { dir, maxBytes: 100, onFailure: error => failures.push(error) });
  reader.push(Buffer.from([0xe4, 0xb8]));
  assert.equal(reader.readFrom(0).nextOffset, 0);
  reader.push(Buffer.from([0xad]));
  reader.seal();
  const output = reader.readFrom(0);
  assert.equal(output.lossy, true);
  assert.equal(output.nextOffset, 3);
  assert.equal(output.text, Buffer.from([0xb8, 0xad]).toString('utf8'));
  assert.equal((await readFile(output.spillPath)).toString('hex'), 'e4b8ad');
  assert.deepEqual(failures, []);
  assert.equal(reader.finalize().spillPath, output.spillPath);
});

test('oversized output tail releases the discarded backing buffer without copying it on every later small chunk', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'output-backing-spill-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const input = Buffer.alloc(8 * 1024 * 1024, 0x61);
  const suffix = Buffer.alloc(64, 0x62);
  for (const cap of [64e3, 1024 * 1024]) for (const withSpill of [false, true]) {
    const failures = [];
    const reader = new OutputCollector(cap, 'stdout', withSpill ? {
      dir, maxBytes: input.length + suffix.length, onFailure: error => failures.push(error),
    } : undefined);
    reader.push(input);
    assert.equal(reader.bytes, cap);
    assert.equal(reader.total, input.length);
    assert.equal(reader.dropped, true);
    assert.notEqual(reader.chunks[0].buffer, input.buffer, 'the tiny retained tail must release the oversized input allocation');
    assert(reader.chunks[0].buffer.byteLength <= Math.max(cap, Buffer.poolSize));
    const retained = reader.chunks[0].buffer;
    for (const byte of suffix) reader.push(Buffer.from([byte]));
    assert.equal(reader.chunks[0].buffer, retained, 'later small appends must not repeatedly copy the large retained head');
    reader.seal();
    const result = reader.readFrom(0);
    assert.equal(reader.bytes, cap);
    assert.equal(reader.total, input.length + suffix.length);
    assert.equal(result.nextOffset, reader.total);
    assert.equal(result.lossy, true);
    assert.equal(result.text, 'a'.repeat(cap - suffix.length) + 'b'.repeat(suffix.length));
    assert.equal(reader.readFrom(reader.total - suffix.length).text, 'b'.repeat(suffix.length));
    assert.deepEqual(failures, []);
    if (withSpill) {
      const bytes = await readFile(result.spillPath);
      assert.equal(bytes.length, input.length + suffix.length);
      assert.deepEqual(bytes.subarray(0, input.length), input);
      assert.deepEqual(bytes.subarray(input.length), suffix);
    } else assert.equal(result.spillPath, undefined);
  }
});
