// Deliberately finite OOXML: five known parts, one visible sheet, 20 literal string cells.
// This is not an importer for arbitrary user workbooks.
import {zipSync, unzipSync, strToU8} from '../vendor/receipt-sheet/fflate.mjs';
import {RECEIPT_LIMITS, ReceiptTaskError} from './receipt-content.js';

export const receiptHeaders = Object.freeze(['日期', '项目', '金额', '来源']);
const main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const rel = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const packageRel = 'http://schemas.openxmlformats.org/package/2006/relationships';
const declaration = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>';
const staticParts = Object.freeze({
  '[Content_Types].xml': `${declaration}<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>`,
  '_rels/.rels': `${declaration}<Relationships xmlns="${packageRel}"><Relationship Id="rId1" Type="${rel}/officeDocument" Target="xl/workbook.xml"/></Relationships>`,
  'xl/workbook.xml': `${declaration}<workbook xmlns="${main}" xmlns:r="${rel}"><sheets><sheet name="差旅小表" sheetId="1" r:id="rId1"/></sheets></workbook>`,
  'xl/_rels/workbook.xml.rels': `${declaration}<Relationships xmlns="${packageRel}"><Relationship Id="rId1" Type="${rel}/worksheet" Target="worksheets/sheet1.xml"/></Relationships>`,
});
const sheetName = 'xl/worksheets/sheet1.xml';
const sheetPrefix = `${declaration}<worksheet xmlns="${main}"><sheetData>`;
const sheetSuffix = '</sheetData></worksheet>';
const fail = () => { throw new ReceiptTaskError('workbook_verification_failed'); };
function validText(value) {
  if (typeof value !== 'string' || value.length > 32767) fail();
  for (const char of value) {
    const code = char.codePointAt(0);
    if (!(code === 9 || code === 10 || code === 13 || code >= 32 && code <= 0xd7ff ||
        code >= 0xe000 && code <= 0xfffd || code >= 0x10000 && code <= 0x10ffff)) fail();
  }
  return value;
}
function quote(value) {
  return validText(value).replace(/_x([0-9a-fA-F]{4})_/g, '_x005F_x$1_')
    .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
    .replaceAll('\r', '&#13;').replaceAll('\n', '&#10;');
}
function grid(rows) {
  if (!Array.isArray(rows) || rows.length !== 4 || rows.some(row => !Array.isArray(row) || row.length !== 4)) fail();
  return [receiptHeaders, ...rows].map(row => row.map(validText));
}
export function createReceiptWorkbook(rows) {
  const cells = grid(rows).map((row, r) => `<row r="${r + 1}">${row.map((value, c) =>
    `<c r="${String.fromCharCode(65 + c)}${r + 1}" t="inlineStr"><is><t xml:space="preserve">${quote(value)}</t></is></c>`).join('')}</row>`).join('');
  const parts = {...staticParts, [sheetName]: `${sheetPrefix}${cells}${sheetSuffix}`};
  const bytes = Buffer.from(zipSync(Object.fromEntries(Object.entries(parts).map(([name, xml]) => [name, strToU8(xml)])),
    {level: 0, mtime: new Date(2026, 0, 1)}));
  if (bytes.length > RECEIPT_LIMITS.workbookBytes) throw new ReceiptTaskError('workbook_size_limit');
  return bytes;
}
function decodeText(value) {
  // These are precisely the five entity forms emitted by quote(). No DTD/entity resolver.
  if (/[<>]/u.test(value) || /&(?!(?:amp|lt|gt|#13|#10);)/u.test(value)) fail();
  const xml = value.replace(/&(amp|lt|gt|#13|#10);/gu,
    (_, key) => ({amp: '&', lt: '<', gt: '>', '#13': '\r', '#10': '\n'})[key]);
  // Decode ST_Xstring once. _x005F_x0041_ denotes literal _x0041_, not A.
  return validText(xml.replace(/_x([0-9a-fA-F]{4})_/g, (_, hex) => String.fromCharCode(parseInt(hex, 16))));
}
export function verifyReceiptWorkbook(bytes, expectedRows) {
  if (!(bytes instanceof Uint8Array) || bytes.length > RECEIPT_LIMITS.workbookBytes) fail();
  const expected = grid(expectedRows), decoder = new TextDecoder('utf-8', {fatal: true});
  let parts;
  try { parts = unzipSync(bytes, {filter: entry => entry.originalSize <= RECEIPT_LIMITS.workbookBytes}); }
  catch { fail(); }
  const names = [...Object.keys(staticParts), sheetName];
  if (Object.keys(parts).length !== names.length || names.some(name => !Object.hasOwn(parts, name))) fail();
  if (Object.values(parts).reduce((sum, value) => sum + value.length, 0) > RECEIPT_LIMITS.workbookBytes) fail();
  try {
    for (const [name, xml] of Object.entries(staticParts)) if (decoder.decode(parts[name]) !== xml) fail();
    const xml = decoder.decode(parts[sheetName]);
    let cursor = 0;
    const consume = literal => {
      if (!xml.startsWith(literal, cursor)) fail();
      cursor += literal.length;
    };
    consume(sheetPrefix);
    const actual = [];
    for (let r = 0; r < 5; r++) {
      consume(`<row r="${r + 1}">`); const row = [];
      for (let c = 0; c < 4; c++) {
        consume(`<c r="${String.fromCharCode(65 + c)}${r + 1}" t="inlineStr"><is><t xml:space="preserve">`);
        const end = xml.indexOf('</t>', cursor);
        if (end < 0) fail();
        const encoded = xml.slice(cursor, end), value = decodeText(encoded);
        if (value !== expected[r][c] || quote(value) !== encoded) fail();
        row.push(value); cursor = end;
        consume('</t></is></c>');
      }
      consume('</row>'); actual.push(row);
    }
    consume(sheetSuffix);
    if (cursor !== xml.length) fail();
    return {sheet: '差旅小表', cells: 20, rows: actual};
  } catch (error) {
    if (error instanceof ReceiptTaskError) throw error;
    fail();
  }
}
