import test from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {COMPARE_DRAFT_SOURCE_BYTES, compareDraftTexts} from '../bridge/dsh-go-bridge/lib/companion/compare-drafts-content.js';

// Check coverage using the original inputs and returned ranges, independently
// of the alignment algorithm. Unchanged gaps must be equal; replacing every
// returned A range with its B range must reconstruct all of B, including EOF.
function covered(a, b, report = compareDraftTexts(a, b)) {
  assert.equal(report.complete, true);
  assert.equal(report.minimumEditScriptGuaranteed, false);
  assert.equal(report.identical, a === b);
  assert.equal(report.totalChanges, report.changes.length);
  assert.equal(new Set(report.changes.map(change => change.id)).size, report.totalChanges);
  let aCursor = 0, bCursor = 0, rebuilt = '';
  for (const change of report.changes) {
    assert.ok(change.a.from >= aCursor && change.b.from >= bCursor);
    assert.equal(a.slice(aCursor, change.a.from), b.slice(bCursor, change.b.from));
    assert.notEqual(a.slice(change.a.from, change.a.to), b.slice(change.b.from, change.b.to));
    rebuilt += a.slice(aCursor, change.a.from) + b.slice(change.b.from, change.b.to);
    for (const [key, text] of [['a', a], ['b', b]]) {
      const side = change[key];
      assert.ok(side.from <= side.to && side.to <= text.length);
      assert.ok(side.lineStart >= 1 && side.lineEnd >= side.lineStart);
      assert.ok((side.paragraphs === null) !== (side.boundary === null));
      assert.ok(side.excerpts.length <= 2);
      for (const excerpt of side.excerpts) {
        assert.ok(excerpt.from >= side.from && excerpt.to <= side.to && excerpt.from < excerpt.to);
        assert.equal(excerpt.text, text.slice(excerpt.from, excerpt.to));
        assert.equal(excerpt.text.isWellFormed(), true);
        assert.ok(Array.from(excerpt.text).length <= 160);
        assert.ok((excerpt.paragraphs === null) !== (excerpt.boundary === null));
      }
    }
    aCursor = change.a.to; bCursor = change.b.to;
  }
  assert.equal(a.slice(aCursor), b.slice(bCursor));
  assert.equal(rebuilt + a.slice(aCursor), b);
  for (const [key, text] of [['a', a], ['b', b]]) {
    assert.equal(report[key].utf8Bytes, Buffer.byteLength(text));
    assert.equal(report[key].utf16Length, text.length);
    assert.equal(report[key].sha256, createHash('sha256').update(text).digest('hex'));
  }
  return report;
}

test('compare original two changes gives actual first and last paragraphs without inventing a third', () => {
  const a = '周五开放。\n\n中间不变。\n\n最后我们再想一想？\n';
  const b = '周六开放。\n\n中间不变。\n\n最后我们再想一想。\n';
  const report = covered(a, b);
  assert.equal(report.totalChanges, 2);
  assert.deepEqual(report.changes.map(change => change.a.paragraphs), [{from: 1, to: 1}, {from: 3, to: 3}]);
  assert.deepEqual(report.changes.map(change => change.b.paragraphs), [{from: 1, to: 1}, {from: 3, to: 3}]);
  assert.deepEqual(report.changes.map(change => [change.a.lineStart, change.a.lineEnd]), [[1, 2], [5, 6]]);
  assert.equal(report.changes[0].a.excerpts[0].text, '周五开放。\n');
  assert.equal(report.changes[0].b.excerpts[0].text, '周六开放。\n');
  assert.equal(report.changes[1].a.excerpts[0].text, '最后我们再想一想？\n');
  assert.equal(report.changes[1].b.excerpts[0].text, '最后我们再想一想。\n');
  assert.deepEqual(compareDraftTexts(a, b), report);
  assert.equal(Object.hasOwn(report, 'suggestions'), false);
  assert.equal(Object.hasOwn(report, 'ranked'), false);
});

test('compare two line groups in the same paragraph keep the same actual paragraph number', () => {
  const report = covered('旧开头\n固定中句\n旧结尾\n', '新开头\n固定中句\n新结尾\n');
  assert.equal(report.totalChanges, 2);
  assert.equal(report.a.paragraphCount, 1);
  for (const change of report.changes) {
    assert.deepEqual(change.a.paragraphs, {from: 1, to: 1});
    assert.deepEqual(change.b.paragraphs, {from: 1, to: 1});
  }
});

test('compare separator whitespace has a real between-paragraph location', () => {
  const report = covered('前段\n\n后段\n', '前段\n \t\n后段\n');
  assert.equal(report.totalChanges, 1);
  for (const side of [report.changes[0].a, report.changes[0].b]) {
    assert.equal(side.paragraphs, null);
    assert.deepEqual(side.boundary, {beforeParagraph: 1, afterParagraph: 2});
    assert.equal(side.lineStart, 2);
    assert.equal(side.lineEnd, 3);
    assert.equal(side.excerpts[0].paragraphs, null);
  }
  assert.equal(report.changes[0].b.excerpts[0].text, ' \t\n');
});

test('compare preserves CRLF, bare CR, indentation, trailing spaces and final newline changes', () => {
  for (const [a, b] of [
    ['首行\r\n\r\n尾行\r\n', '首行\n\n尾行\n'],
    ['前\r\r后', '前\r\r末'],
    ['正文', '正文\n'], ['正文\n', '正文'],
    ['  正文\n', '\t正文\n'], ['正文 \n', '正文\n'],
    ['\n正文\n\n', '\n正文\n\t\n'],
  ]) assert.ok(covered(a, b).totalChanges > 0);
  const cr = covered('前\r\r后', '前\r\r末');
  assert.equal(cr.a.lineCount, 3);
  assert.deepEqual(cr.changes[0].a.paragraphs, {from: 2, to: 2});
});

test('compare retains Unicode literally and excerpts never split a surrogate pair', () => {
  const a = '😀'.repeat(90) + '周五' + '🌲'.repeat(120) + '？\r\n';
  const b = '😀'.repeat(90) + '周六' + '🌲'.repeat(120) + '。\r\n';
  const report = covered(a, b);
  assert.equal(report.totalChanges, 1);
  assert.equal(report.changes[0].a.to, a.length);
  assert.ok(report.changes[0].a.excerpts.some(excerpt => excerpt.text.includes('周五')));
  assert.ok(report.changes[0].b.excerpts.some(excerpt => excerpt.text.includes('周六')));
  assert.ok(report.changes[0].a.excerpts.some(excerpt => excerpt.text.includes('？')));
  assert.ok(report.changes[0].b.excerpts.some(excerpt => excerpt.text.includes('。')));
  assert.ok(covered('e\u0301', '\u00e9').totalChanges > 0);
  assert.ok(covered('\ufeff正文', '正文').totalChanges > 0);
});

test('compare empty and identical inputs produce zero changes and no artificial paragraph', () => {
  for (const text of ['', '正文', '\n', ' \t\r\n', '首\n\n末\n', '\ufeff😀\r\n']) {
    assert.equal(covered(text, text).totalChanges, 0);
  }
  const empty = covered('', '');
  assert.equal(empty.a.lineCount, 0);
  assert.equal(empty.a.paragraphCount, 0);
  const blank = covered(' \t\r\n', ' \t\r\n');
  assert.equal(blank.a.paragraphCount, 0);
});

test('compare insertion and deletion sides use real empty boundary locations', () => {
  const inserted = covered('开始\n固定\n', '开始\n新句\n固定\n');
  assert.equal(inserted.changes[0].kind, 'insert');
  assert.equal(inserted.changes[0].a.from, inserted.changes[0].a.to);
  assert.deepEqual(inserted.changes[0].a.boundary, {beforeParagraph: 1, afterParagraph: 1});
  assert.deepEqual(inserted.changes[0].a.excerpts, []);
  const deleted = covered('开始\n新句\n固定\n', '开始\n固定\n');
  assert.equal(deleted.changes[0].kind, 'delete');
  assert.deepEqual(deleted.changes[0].b.boundary, {beforeParagraph: 1, afterParagraph: 1});
  const whole = covered('', '新稿');
  assert.equal(whole.changes[0].kind, 'insert');
  assert.deepEqual(whole.changes[0].a.boundary, {beforeParagraph: null, afterParagraph: null});
  assert.equal(covered('旧稿', '').changes[0].kind, 'delete');
  const eof = covered('首段\n', '首段\n\n尾段\n');
  assert.deepEqual(eof.changes[0].a.boundary, {beforeParagraph: 1, afterParagraph: null});
  assert.deepEqual(eof.changes[0].b.paragraphs, {from: 2, to: 2});
});

test('compare long lines quotes the first and last actual changes without joining them', () => {
  const a = '前'.repeat(400) + '甲' + '中'.repeat(2000) + '乙' + '后'.repeat(400);
  const b = '前'.repeat(400) + '丙' + '中'.repeat(2000) + '丁' + '后'.repeat(400);
  const report = covered(a, b);
  assert.equal(report.totalChanges, 1);
  for (const key of ['a', 'b']) assert.equal(report.changes[0][key].excerpts.length, 2);
  assert.ok(report.changes[0].a.excerpts[0].text.includes('甲'));
  assert.ok(report.changes[0].a.excerpts[1].text.includes('乙'));
  assert.ok(report.changes[0].b.excerpts[0].text.includes('丙'));
  assert.ok(report.changes[0].b.excerpts[1].text.includes('丁'));
  assert.ok(report.changes[0].a.excerpts[0].to < report.changes[0].a.excerpts[1].from);
  assert.equal(report.changes[0].a.from, 0);
  assert.equal(report.changes[0].a.to, a.length);
});

test('compare accepts exactly 64 KiB UTF-8 and rejects excess or incomplete Unicode without truncation', () => {
  assert.equal(COMPARE_DRAFT_SOURCE_BYTES, 65536);
  const ascii = 'a'.repeat(65536), astral = '😀'.repeat(16384);
  assert.equal(covered(ascii, ascii.slice(0, -1) + 'b').a.utf8Bytes, 65536);
  assert.equal(covered(astral, astral).a.utf8Bytes, 65536);
  for (const [a, b, side] of [[ascii + 'a', '', 'A'], ['', astral + 'a', 'B']]) {
    assert.throws(() => compareDraftTexts(a, b), error => error.code === 'COMPARE_INPUT_LIMIT' && error.side === side);
  }
  for (const a of [null, 1, '\ud800', '\udc00', 'x\ud800x']) {
    assert.throws(() => compareDraftTexts(a, ''), error => error.code === 'COMPARE_INPUT_TEXT' && error.side === 'A');
  }
  assert.throws(() => compareDraftTexts('', '\udc00'), error => error.code === 'COMPARE_INPUT_TEXT' && error.side === 'B');
});

test('compare maximum repeated blank lines and completely different short lines stays complete', () => {
  const blank = '\n'.repeat(65536);
  const blankReport = covered(blank, blank.slice(0, -1) + 'x');
  assert.equal(blankReport.a.lineCount, 65536);
  assert.equal(blankReport.totalChanges, 1);
  const a = 'a\n'.repeat(32768), b = 'b\n'.repeat(32768);
  const report = covered(a, b);
  assert.equal(report.totalChanges, 1);
  assert.equal(report.changes[0].a.to, a.length);
  assert.equal(report.changes[0].b.to, b.length);
  assert.deepEqual(report.changes[0].a.paragraphs, {from: 1, to: 1});
});

test('compare returns all 5000 anchored groups instead of treating a first-three slice as complete', () => {
  const a = [], b = [];
  for (let index = 0; index < 5000; index++) {
    a.push(`${index.toString(36)}\nold\n`); b.push(`${index.toString(36)}\nnew\n`);
  }
  const report = covered(a.join(''), b.join(''));
  assert.equal(report.totalChanges, 5000);
  assert.equal(report.a.paragraphCount, 1);
  assert.deepEqual(report.changes.at(-1).b.paragraphs, {from: 1, to: 1});
  assert.equal(report.changes.at(-1).b.to, b.join('').length);
});

test('compare reversed unique lines and repeated text do not require a pairwise matrix', () => {
  const text = Array.from({length: 9000}, (_, index) => `${index.toString(36)}\n`);
  const report = covered(text.join(''), text.toReversed().join(''));
  assert.ok(report.totalChanges > 0);
  covered('one\nsame\nsame\nend\n', 'same\none\nsame\nend\n');
});

test('compare stable IDs bind both complete input digests and the actual side ranges', () => {
  const first = covered('A\nanchor\nZ\n', 'B\nanchor\nZ\n');
  const other = covered('A\nanchor\nQ\n', 'B\nanchor\nQ\n');
  assert.deepEqual(first.changes.map(change => change.id), compareDraftTexts('A\nanchor\nZ\n', 'B\nanchor\nZ\n').changes.map(change => change.id));
  assert.notEqual(first.changes[0].id, other.changes[0].id);
});

test('compare deterministic generated Unicode and newline cases preserve both full-text coverage and reconstruction', () => {
  const alphabet = ['a', 'b', '中', '😀', '\r', '\n', ' ', '\t', '\u0301'];
  let seed = 0x5a17c2e3;
  const next = limit => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % limit; };
  const text = () => Array.from({length: next(160)}, () => alphabet[next(alphabet.length)]).join('');
  for (let index = 0; index < 500; index++) {
    const a = text(), b = index % 4 ? text() : a;
    covered(a, b);
  }
});
