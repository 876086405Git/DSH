import test from 'node:test';
import assert from 'node:assert/strict';
import {receiptTextLines, receiptObservation, receiptReport, receiptGrid, excludeReceiptAtPublish}
  from '../bridge/dsh-go-bridge/lib/companion/receipt-content.js';
import {createReceiptWorkbook, verifyReceiptWorkbook, receiptHeaders}
  from '../bridge/dsh-go-bridge/lib/companion/receipt-workbook.js';
import {zipSync, unzipSync, strToU8, strFromU8} from '../bridge/dsh-go-bridge/lib/vendor/receipt-sheet/fflate.mjs';

const text = '日期：2026-11-20\n项目：交通\n金额：CNY 128.50\n';
function observed(value = text, name = 'original.txt', ref = 'source-one') {
  const bytes = Buffer.from(value);
  return receiptObservation({sourceRef: ref, entry: {name, version: 'original-v1', size: bytes.length}},
    {read: {bytes, sha256: '1'.repeat(64)}, extraction: receiptTextLines(bytes)});
}
const reportFor = values => receiptReport(values.map((value, index) => observed(value, `source-${index}.txt`, `source-${index}`)));

test('J SOURCE_UNIT explicitly labelled dates/items/currencies have exact original line evidence', () => {
  const original = ' 日期：2026年2月28日\r\nItem: =HYPERLINK("https://example.invalid","票")\r金额：000128.5 人民币';
  const row = observed(original).row;
  assert.equal(row.date.value, '2026-02-28'); assert.equal(row.item.value, '=HYPERLINK("https://example.invalid","票")');
  assert.equal(row.amount.value, 'CNY 128.50');
  const lines = original.split(/\r\n|\r|\n/u);
  for (const field of ['date', 'item', 'amount']) {
    assert.equal(row[field].state, 'verified'); assert.equal(row[field].reason, null);
    const evidence = row[field].evidence;
    assert.equal(evidence.page, null); assert.equal(evidence.lineStart, evidence.lineEnd);
    assert.equal(evidence.quote, lines[evidence.lineStart - 1]);
  }
});
for (const date of ['2026-02-29', '1900-02-29', '0000-01-01', '2026-13-01', '11-20', '20/11/2026', '2026-11-20 maybe'])
test('J SOURCE_UNIT no guessed or invalid calendar date: ' + date, () => {
  assert.equal(observed(`日期：${date}\n项目：公交\n金额：CNY 3`).row.date.state, 'unverified');
});
test('J SOURCE_UNIT leap-year calendar, currency aliases and exact large decimals avoid float arithmetic', () => {
  assert.equal(observed('Date: 2000/2/29\nItem: Train\nAmount: 999999999999.99 USD').row.date.value, '2000-02-29');
  assert.equal(observed('Amount: 999999999999.99 USD').row.amount.value, 'USD 999999999999.99');
  assert.equal(observed('金额：SGD 0').row.amount.value, 'SGD 0.00');
});
for (const amount of ['¥80.00', '$80.00', '80.00', 'USD 1,200.00', 'CNY 1.001', 'CNY -3', 'CNY 8 USD', 'CNY 8+2'])
test('J SOURCE_UNIT ambiguous/unsupported amount stays unverified: ' + amount, () => {
  const row = observed('金额：' + amount).row;
  assert.equal(row.amount.state, 'unverified'); assert.equal(row.amount.value, null);
});
test('J SOURCE_UNIT conflicting labels invalidate a value; filename/mtime and unrelated prose are never fields', () => {
  const row = observed(text + '金额：USD 90.00\n日期：2026-11-21', '2026-11-20_餐费_CNY80.txt').row;
  assert.equal(row.date.state, 'unverified'); assert.equal(row.amount.state, 'unverified');
  const absent = observed('This receipt mentions CNY 80 and 2026-11-20 in prose.', '2026-11-20_train_CNY80.txt').row;
  for (const key of ['date', 'item', 'amount']) assert.equal(absent[key].state, 'unverified');
  assert(!JSON.stringify(absent).includes('not_present'));
});
test('J SOURCE_UNIT mixed PDF only uses real extracted amount, never the image date or absence claim', () => {
  const entry = {sourceRef: 'mixed', entry: {name: 'mixed.pdf', version: 'v1', size: 30}};
  const value = receiptObservation(entry, {read: {bytes: Buffer.alloc(30), sha256: '1'.repeat(64)}, extraction:
    {pageCount: 1, textLayerOnly: true, fullTextExtraction: true, pages: [{page: 1, lines: [{line: 1, text: 'Amount: CNY 80.00'}]}]}});
  assert.equal(value.row.amount.value, 'CNY 80.00'); assert.equal(value.row.amount.evidence.page, 1);
  assert.equal(value.row.date.state, 'unverified'); assert.equal(value.source.textLayerOnly, true);
  assert.equal(value.source.readComplete, true); assert.equal(value.source.parseComplete, true);
  assert(!JSON.stringify(value.row).includes('not_present'));
});
test('J SOURCE_UNIT fully empty PDF text layer explicitly records unread text instead of an empty verified receipt', () => {
  const value = receiptObservation({sourceRef: 'scan', entry: {name: 'scan.pdf', version: 'v1', size: 30}},
    {read: {bytes: Buffer.alloc(30), sha256: '1'.repeat(64)}, extraction:
      {pageCount: 1, textLayerOnly: true, fullTextExtraction: true, pages: [{page: 1, lines: []}]}});
  assert.equal(value.source.reason, 'pdf_empty_text'); assert.equal(value.row.date.reason, 'pdf_empty_text');
  const report = receiptReport([observed(), observed(), observed(), value]);
  assert.match(receiptGrid(report)[3][3], /未读到文字层/u);
});
test('J SOURCE_UNIT four rows and coverage are derived exactly; invalidated source fields leave evidence out of the table', () => {
  const values = [observed(), observed(), observed(), observed('nothing here')];
  values[0] = excludeReceiptAtPublish(values[0], 'input_changed_at_publish');
  const report = receiptReport(values);
  assert.equal(report.coverage.inputCount, 4); assert.equal(report.coverage.readCompleteCount, 4);
  assert.equal(report.coverage.rowsWithVerifiedFields, 2); assert.equal(report.coverage.fullyVerifiedRows, 2);
  assert.equal(report.coverage.gaps.filter(value => value.field === 'verification').length, 1);
  for (const key of ['date', 'item', 'amount']) assert.equal(report.rows[0][key].evidence, null);
  assert.match(receiptGrid(report)[0][2], /原件已换版/u);
});
test('J SOURCE_UNIT UTF8, long-line and text-line limits fail explicitly without truncated full-coverage results', () => {
  assert.throws(() => receiptTextLines(Buffer.from([0xc3, 0x28])), /input_not_utf8/u);
  assert.throws(() => receiptTextLines(Buffer.alloc(4194305)), /input_too_large/u);
  assert.throws(() => receiptTextLines(Buffer.from('\n'.repeat(100000))), /text_line_limit/u);
  assert.equal(observed('项目：' + 'x'.repeat(3000)).row.item.state, 'unverified');
});
test('J SOURCE_ZIP actual 20 explicit-string cells round-trip all sources, formulas-as-text, XML and Xstring escapes', () => {
  const report = reportFor([text, text, text, text]); const rows = receiptGrid(report);
  rows[0][1] = '=HYPERLINK("https://example.invalid","ticket")';
  rows[1][1] = ' <票据>&"\'\t\r\n😀 _x0041_ _x005F_ ';
  const bytes = createReceiptWorkbook(rows), read = verifyReceiptWorkbook(bytes, rows);
  assert(bytes.length < 262144); assert.equal(read.cells, 20); assert.equal(read.sheet, '差旅小表');
  assert.deepEqual(read.rows, [receiptHeaders, ...rows]);
});
test('J SOURCE_ZIP rejects formulas, macros, external links, hidden sheets, extra cells and changed actual source values', () => {
  const rows = receiptGrid(reportFor([text, text, text, text])), bytes = createReceiptWorkbook(rows);
  const original = unzipSync(bytes);
  const modified = mutate => { const parts = {...original}; mutate(parts); return zipSync(parts, {level: 0}); };
  for (const mutate of [parts => { parts['xl/vbaProject.bin'] = new Uint8Array([1]); },
    parts => { parts['xl/workbook.xml'] = strToU8(strFromU8(parts['xl/workbook.xml']).replace('sheetId="1"', 'sheetId="1" state="hidden"')); },
    parts => { parts['xl/_rels/workbook.xml.rels'] = strToU8(strFromU8(parts['xl/_rels/workbook.xml.rels']).replace('Target=', 'TargetMode="External" Target=')); },
    parts => { parts['xl/worksheets/sheet1.xml'] = strToU8(strFromU8(parts['xl/worksheets/sheet1.xml']).replace('<is>', '<f>1+1</f><is>')); },
    parts => { parts['xl/worksheets/sheet1.xml'] = strToU8(strFromU8(parts['xl/worksheets/sheet1.xml']).replace('128.50', '129.50')); },
    parts => { parts['xl/worksheets/sheet1.xml'] = strToU8(strFromU8(parts['xl/worksheets/sheet1.xml']).replace('</sheetData>', '<row r="6"/></sheetData>')); }])
    assert.throws(() => verifyReceiptWorkbook(modified(mutate), rows), /workbook_verification_failed/u);
});
test('J SOURCE_ZIP no malformed XML text, fifth source or decompressed oversized member is accepted', () => {
  const rows = receiptGrid(reportFor([text, text, text, text]));
  for (const value of ['\u0000', '\u0001', '\ud800', '\uffff']) {
    const invalid = structuredClone(rows); invalid[0][1] = value;
    assert.throws(() => createReceiptWorkbook(invalid), /workbook_verification_failed/u);
  }
  assert.throws(() => createReceiptWorkbook([...rows, rows[0]]), /workbook_verification_failed/u);
  const parts = unzipSync(createReceiptWorkbook(rows)); parts['xl/worksheets/sheet1.xml'] = new Uint8Array(262145);
  assert.throws(() => verifyReceiptWorkbook(zipSync(parts, {level: 9}), rows), /workbook_verification_failed/u);
});
