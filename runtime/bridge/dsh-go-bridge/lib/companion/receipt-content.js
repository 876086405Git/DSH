// Fixed local receipt rules. Absence of a match is never evidence of absence on the original.
export const RECEIPT_LIMITS = Object.freeze({files: 4, fileBytes: 4194304, pdfPages: 5,
  textBytes: 4194304, textLines: 100000, workbookBytes: 262144});
export const receiptFields = Object.freeze(['date', 'item', 'amount']);
export class ReceiptTaskError extends Error {
  constructor(reason, state = 'failed') { super(reason); this.name = 'ReceiptTaskError';
    this.receiptReason = reason; this.receiptState = state; }
}
export const receiptMediaType = name => /\.pdf$/iu.test(name) ? 'application/pdf'
  : /\.md$/iu.test(name) ? 'text/markdown' : 'text/plain';
export const unverifiedField = reason => ({state: 'unverified', value: null, evidence: null, reason});
const unknownRow = (reference, reason) => ({sourceRef: reference.sourceRef, version: reference.version,
  ...Object.fromEntries(receiptFields.map(key => [key, unverifiedField(reason)]))});

export function receiptTextLines(bytes) {
  if (!(bytes instanceof Uint8Array) || bytes.length > RECEIPT_LIMITS.fileBytes)
    throw new ReceiptTaskError('input_too_large');
  let text;
  try { text = new TextDecoder('utf-8', {fatal: true}).decode(bytes); }
  catch { throw new ReceiptTaskError('input_not_utf8'); }
  // A bounded scanner rejects excessive lines before constructing a huge split array.
  const lines = []; let start = 0;
  for (let cursor = 0; cursor <= text.length; cursor++) {
    if (cursor !== text.length && text[cursor] !== '\r' && text[cursor] !== '\n') continue;
    if (lines.length === RECEIPT_LIMITS.textLines) throw new ReceiptTaskError('text_line_limit');
    lines.push({line: lines.length + 1, text: text.slice(start, cursor)});
    if (text[cursor] === '\r' && text[cursor + 1] === '\n') cursor++;
    start = cursor + 1;
  }
  return {pages: [{page: null, lines}], pageCount: null, textLayerOnly: false, fullTextExtraction: true};
}

function calendarDate(value) {
  const found = /^(\d{4})[-/]([0-9]{1,2})[-/]([0-9]{1,2})$/u.exec(value) ??
    /^(\d{4})年([0-9]{1,2})月([0-9]{1,2})日$/u.exec(value);
  if (!found) return null;
  const [, y, m, d] = found.map(Number), leap = y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0);
  const days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (y < 1 || m < 1 || m > 12 || d < 1 || d > days[m - 1]) return null;
  return `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}
const currency = new Map([['CNY', 'CNY'], ['RMB', 'CNY'], ['人民币', 'CNY'], ['USD', 'USD'], ['美元', 'USD'],
  ['EUR', 'EUR'], ['欧元', 'EUR'], ['GBP', 'GBP'], ['英镑', 'GBP'], ['JPY', 'JPY'], ['日元', 'JPY'],
  ['HKD', 'HKD'], ['港币', 'HKD'], ['SGD', 'SGD'], ['新加坡元', 'SGD']]);
const currencyNames = [...currency.keys()].join('|');
const amountPattern = new RegExp(`^(?:(${currencyNames})\\s*([0-9]{1,12}(?:\\.[0-9]{1,2})?)|([0-9]{1,12}(?:\\.[0-9]{1,2})?)\\s*(${currencyNames}))$`, 'iu');
function money(value) {
  const found = amountPattern.exec(value);
  if (!found) return null;
  const code = currency.get((found[1] ?? found[4]).toUpperCase()), numeric = found[2] ?? found[3];
  if (!code) return null;
  const [whole, decimal = ''] = numeric.split('.');
  // String arithmetic preserves exact decimal text; there is no floating-point sum or conversion.
  return `${code} ${whole.replace(/^0+(?=\d)/u, '')}.${decimal.padEnd(2, '0')}`;
}
const patterns = {
  date: /^(?:[-*]\s+)?(?:日期|开票日期|交易日期|Date)\s*[:：]\s*(.*?)\s*$/iu,
  item: /^(?:[-*]\s+)?(?:项目|品名|品目|Item)\s*[:：]\s*(.*?)\s*$/iu,
  amount: /^(?:[-*]\s+)?(?:金额|总金额|价税合计|Amount)\s*[:：]\s*(.*?)\s*$/iu,
};
const supportedXml = value => [...value].every(char => {
  const code = char.codePointAt(0);
  return code === 9 || code === 10 || code === 13 || code >= 32 && code <= 0xd7ff ||
    code >= 0xe000 && code <= 0xfffd || code >= 0x10000 && code <= 0x10ffff;
});
function readField(key, extraction) {
  const candidates = []; let invalid = false;
  for (const page of extraction.pages) for (const line of page.lines) {
    const found = patterns[key].exec(line.text.trim());
    if (!found) continue;
    if (line.text.length > 2048 || !supportedXml(line.text)) { invalid = true; continue; }
    const raw = found[1], value = key === 'date' ? calendarDate(raw) : key === 'amount' ? money(raw)
      : raw && raw.length <= 512 ? raw : null;
    if (!value) { invalid = true; continue; }
    candidates.push({value, evidence: {page: page.page, lineStart: line.line, lineEnd: line.line, quote: line.text}});
  }
  if (invalid || new Set(candidates.map(value => value.value)).size > 1)
    return unverifiedField(`${key}_ambiguous_or_unsupported`);
  if (!candidates.length) return unverifiedField(`${key}_not_verified`);
  return {state: 'verified', value: candidates[0].value, evidence: candidates[0].evidence, reason: null};
}
export function receiptObservation(binding, {read = null, extraction = null, reason = null} = {}) {
  const emptyTextLayer = /\.pdf$/iu.test(binding.entry.name) && extraction !== null &&
    !extraction.pages.some(page => page.lines.some(line => line.text.trim().length));
  if (emptyTextLayer) reason = 'pdf_empty_text';
  const source = {sourceRef: binding.sourceRef, version: binding.entry.version, displayName: binding.entry.name,
    mediaType: receiptMediaType(binding.entry.name), size: binding.entry.size, readComplete: read !== null,
    parseComplete: extraction !== null, textLayerOnly: /\.pdf$/iu.test(binding.entry.name),
    verifiedAtPublish: false, pageCount: extraction?.pageCount ?? null, reason};
  const reference = {sourceRef: source.sourceRef, version: source.version};
  return {source, row: extraction && !emptyTextLayer ? {...reference,
    ...Object.fromEntries(receiptFields.map(key => [key, readField(key, extraction)]))}
    : unknownRow(reference, reason ?? 'input_not_read'),
    sha256: read?.sha256 ?? null, bytesBase64: read ? Buffer.from(read.bytes).toString('base64') : null,
    extraction};
}
export function receiptReport(observations) {
  if (observations.length !== 4) throw new ReceiptTaskError('receipt_count_invalid');
  const sources = observations.map(value => structuredClone(value.source));
  const rows = observations.map(value => structuredClone(value.row)), gaps = [];
  for (let index = 0; index < 4; index++) {
    const source = sources[index], row = rows[index], identity = {sourceRef: source.sourceRef, version: source.version};
    if (!source.readComplete) gaps.push({...identity, field: 'read', reason: source.reason ?? 'input_not_read'});
    if (!source.parseComplete) gaps.push({...identity, field: 'parse', reason: source.reason ?? 'input_not_parsed'});
    for (const field of receiptFields) if (row[field].state !== 'verified')
      gaps.push({...identity, field, reason: row[field].reason});
    if (source.reason === 'input_changed_at_publish' || source.reason === 'input_unavailable_at_publish')
      gaps.push({...identity, field: 'verification', reason: source.reason});
  }
  return {sources, rows, coverage: {inputCount: 4,
    readCompleteCount: sources.filter(value => value.readComplete).length,
    parseCompleteCount: sources.filter(value => value.parseComplete).length,
    rowsWithVerifiedFields: rows.filter(value => receiptFields.some(key => value[key].state === 'verified')).length,
    fullyVerifiedRows: rows.filter(value => receiptFields.every(key => value[key].state === 'verified')).length, gaps}};
}
export function excludeReceiptAtPublish(observation, reason) {
  const result = structuredClone(observation);
  result.source.verifiedAtPublish = false; result.source.reason = reason;
  result.row = unknownRow(result.source, reason);
  return result;
}
export const completeReceiptReport = report => report.coverage.fullyVerifiedRows === 4 &&
  report.sources.every(value => value.readComplete && value.parseComplete && value.verifiedAtPublish);

const displayReasons = Object.freeze({input_not_read: '未读取原件', input_unavailable: '原件无法读取',
  input_changed: '原件已换版', input_changed_at_publish: '发布前原件已换版',
  input_unavailable_at_publish: '发布前无法核原版', input_not_utf8: '文字编码无法核读',
  input_too_large: '原件超过读取上限', pdf_empty_text: '未读到文字层', pdf_unavailable: '当前主机不支持PDF文字提取',
  task_owner_stopping: '主机停止前尚未读取', task_agreement_changed: '约定已变，尚未读取',
  deadline_expired: '到截止时尚未读取', execution_budget_exhausted: '执行额度已用尽',
  date_not_verified: '没有可核的明确日期', item_not_verified: '没有可核的明确项目',
  amount_not_verified: '没有可核的金额与币种', date_ambiguous_or_unsupported: '日期有歧义或格式未支持',
  item_ambiguous_or_unsupported: '项目有歧义或格式未支持', amount_ambiguous_or_unsupported: '金额或币种不明确'});
export const receiptReasonText = reason => displayReasons[reason] ?? '本次未能核定';
export function receiptGrid(report) {
  return report.rows.map((row, index) => {
    const source = report.sources[index], locations = [...new Set(receiptFields.flatMap(key => {
      const evidence = row[key].evidence;
      return evidence ? [evidence.page === null ? `第${evidence.lineStart}行` :
        `第${evidence.page}页文字层提取第${evidence.lineStart}行`] : [];
    }))];
    const scope = source.reason === 'pdf_empty_text' ? '未读到文字层' : !source.readComplete ? '未读取' : !source.parseComplete ? '未能解析' :
      source.textLayerOnly ? '仅核可读文字层' : '完整纯文本';
    const verification = source.verifiedAtPublish ? '发布前核过原版' : '原版未核定';
    return [...receiptFields.map(key => row[key].state === 'verified' ? row[key].value : `未核：${receiptReasonText(row[key].reason)}`),
      `${source.displayName}（${[...locations, scope, verification].join('；')}）`];
  });
}
