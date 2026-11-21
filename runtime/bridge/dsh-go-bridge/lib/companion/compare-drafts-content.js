import { createHash } from 'node:crypto';

export const COMPARE_DRAFT_SOURCE_BYTES = 65536;
const EXCERPT_WINDOW = 160, EXCERPT_CONTEXT = 32;

function input(text, side) {
  if (typeof text !== 'string' || !text.isWellFormed()) {
    throw Object.assign(new TypeError(`${side} must be a complete, well-formed UTF-8 text`),
      {code: 'COMPARE_INPUT_TEXT', side});
  }
  if (text.length > COMPARE_DRAFT_SOURCE_BYTES || Buffer.byteLength(text) > COMPARE_DRAFT_SOURCE_BYTES) {
    throw Object.assign(new RangeError(`${side} exceeds the complete-source byte limit`),
      {code: 'COMPARE_INPUT_LIMIT', side});
  }
  return text;
}

// Retain every character, including CR, LF, CRLF, separators and final whitespace.
// Paragraphs are runs of nonblank lines. Empty/space/tab-only line bodies separate
// paragraphs; classification never trims the text being compared or quoted.
function lines(text) {
  const tokens = [], offsets = [0];
  let from = 0;
  for (let at = 0; at < text.length; at++) {
    const code = text.charCodeAt(at);
    if (code !== 10 && code !== 13) continue;
    if (code === 13 && text.charCodeAt(at + 1) === 10) at++;
    tokens.push(text.slice(from, at + 1));
    from = at + 1;
    offsets.push(from);
  }
  if (from < text.length) { tokens.push(text.slice(from)); offsets.push(text.length); }
  const paragraphs = new Uint32Array(tokens.length);
  let paragraphCount = 0, inside = false;
  for (let index = 0; index < tokens.length; index++) {
    if (/^[ \t]*(?:\r\n|\r|\n)?$/.test(tokens[index])) { inside = false; continue; }
    if (!inside) { paragraphCount++; inside = true; }
    paragraphs[index] = paragraphCount;
  }
  const before = new Uint32Array(tokens.length + 1), after = new Uint32Array(tokens.length + 1);
  for (let index = 0; index < tokens.length; index++) before[index + 1] = paragraphs[index] || before[index];
  for (let index = tokens.length - 1; index >= 0; index--) after[index] = paragraphs[index] || after[index + 1];
  return {tokens, offsets, paragraphs, paragraphCount, before, after};
}

function unique(tokens, from, to) {
  const positions = new Map();
  for (let index = from; index < to; index++) {
    positions.set(tokens[index], positions.has(tokens[index]) ? -1 : index);
  }
  return positions;
}

// One global unique-line/LIS pass. Unanchored ranges remain conservative groups;
// there is no recursive quadratic diff and no claim of a minimum edit script.
function anchors(a, b, aFrom, aTo, bFrom, bTo) {
  const aUnique = unique(a, aFrom, aTo), bUnique = unique(b, bFrom, bTo), pairs = [];
  for (let index = aFrom; index < aTo; index++) {
    const peer = bUnique.get(a[index]);
    if (aUnique.get(a[index]) === index && peer !== undefined && peer >= 0) pairs.push([index, peer]);
  }
  const tails = [], prior = new Int32Array(pairs.length).fill(-1);
  for (let index = 0; index < pairs.length; index++) {
    let low = 0, high = tails.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (pairs[tails[middle]][1] < pairs[index][1]) low = middle + 1;
      else high = middle;
    }
    if (low) prior[index] = tails[low - 1];
    tails[low] = index;
  }
  const result = [];
  for (let index = tails.length ? tails.at(-1) : -1; index !== -1; index = prior[index]) result.push(pairs[index]);
  return result.reverse();
}

function location(data, fromLine, toLine) {
  const first = data.after[fromLine], last = data.before[toLine];
  const paragraphs = fromLine !== toLine && first && last && first <= last ? {from: first, to: last} : null;
  return {
    lineStart: fromLine + 1, lineEnd: toLine + 1,
    paragraphs,
    // A separator-only range or empty insertion side. Equal nonnull neighbors
    // locate an insertion inside the same paragraph, never two invented ones.
    boundary: paragraphs ? null : {
      beforeParagraph: data.before[fromLine] || null,
      afterParagraph: data.after[toLine] || null,
    },
  };
}

function lowerBound(values, value) {
  let low = 0, high = values.length;
  while (low < high) {
    const middle = (low + high) >>> 1;
    if (values[middle] < value) low = middle + 1;
    else high = middle;
  }
  return low;
}

function excerptLocation(data, from, to) {
  const begin = lowerBound(data.offsets, from);
  return location(data, data.offsets[begin] === from ? begin : begin - 1, lowerBound(data.offsets, to));
}

function excerpts(text, data, from, points, firstChanged, lastChanged) {
  if (!points.length) return [];
  const offsets = [0];
  for (const point of points) offsets.push(offsets.at(-1) + point.length);
  const window = center => {
    const start = Math.max(0, Math.min(center - EXCERPT_CONTEXT, points.length - EXCERPT_WINDOW));
    return [start, Math.min(points.length, start + EXCERPT_WINDOW)];
  };
  const head = window(firstChanged), tail = window(Math.max(firstChanged, lastChanged - 1));
  const ranges = head[0] === tail[0] && head[1] === tail[1] ? [head] : [head, tail];
  return ranges.map(([start, end]) => {
    const absoluteFrom = from + offsets[start], absoluteTo = from + offsets[end];
    return {from: absoluteFrom, to: absoluteTo, text: text.slice(absoluteFrom, absoluteTo),
      ...excerptLocation(data, absoluteFrom, absoluteTo)};
  });
}

function change(a, b, aLines, bLines, aFrom, aTo, bFrom, bTo, pairId) {
  const aStart = aLines.offsets[aFrom], aEnd = aLines.offsets[aTo];
  const bStart = bLines.offsets[bFrom], bEnd = bLines.offsets[bTo];
  const aPoints = Array.from(a.slice(aStart, aEnd)), bPoints = Array.from(b.slice(bStart, bEnd));
  let prefix = 0, suffix = 0;
  while (prefix < aPoints.length && prefix < bPoints.length && aPoints[prefix] === bPoints[prefix]) prefix++;
  while (suffix < aPoints.length - prefix && suffix < bPoints.length - prefix &&
    aPoints[aPoints.length - suffix - 1] === bPoints[bPoints.length - suffix - 1]) suffix++;
  const side = (text, data, from, to, start, end, points) => ({
    from: start, to: end, ...location(data, from, to),
    excerpts: excerpts(text, data, start, points, prefix, points.length - suffix),
  });
  return {
    id: `change:${pairId}:${aStart}-${aEnd}:${bStart}-${bEnd}`,
    kind: aFrom === aTo ? 'insert' : bFrom === bTo ? 'delete' : 'replace',
    a: side(a, aLines, aFrom, aTo, aStart, aEnd, aPoints),
    b: side(b, bLines, bFrom, bTo, bStart, bEnd, bPoints),
  };
}

/**
 * Compare complete old A and new B texts without normalizing or dropping bytes.
 * UTF-16 offsets and one-based line ranges are half-open; paragraph ranges are
 * one-based inclusive. Excerpts are exact contiguous substrings, never joined
 * with an invented ellipsis. They may cover only part of their containing group.
 * Each side has at most two excerpts, each at most 160 Unicode code points.
 *
 * Every unequal region is covered. Unique equal lines are monotone anchors;
 * gaps without such anchors form conservative contiguous groups. totalChanges
 * counts those groups, not semantic facts or minimum insert/delete operations.
 * Time is O(n+m+p log p), space O(n+m+text), with n/m lines and p unique peers.
 * No ranking, model, filesystem access, task state or user-facing advice lives here.
 */
export function compareDraftTexts(oldText, newText) {
  const a = input(oldText, 'A'), b = input(newText, 'B'), aLines = lines(a), bLines = lines(b);
  const digest = text => createHash('sha256').update(text).digest('hex');
  const aHash = digest(a), bHash = digest(b), pairId = digest(`${aHash}:${bHash}`);
  const summary = (text, data, sha256) => ({utf8Bytes: Buffer.byteLength(text), utf16Length: text.length,
    lineCount: data.tokens.length, paragraphCount: data.paragraphCount, sha256});
  const changes = [];
  let prefix = 0, aEnd = aLines.tokens.length, bEnd = bLines.tokens.length;
  while (prefix < aEnd && prefix < bEnd && aLines.tokens[prefix] === bLines.tokens[prefix]) prefix++;
  while (aEnd > prefix && bEnd > prefix && aLines.tokens[aEnd - 1] === bLines.tokens[bEnd - 1]) { aEnd--; bEnd--; }
  const equalAnchors = anchors(aLines.tokens, bLines.tokens, prefix, aEnd, prefix, bEnd);
  let aCursor = prefix, bCursor = prefix;
  for (const [aAnchor, bAnchor] of [...equalAnchors, [aEnd, bEnd]]) {
    let aFrom = aCursor, bFrom = bCursor, aTo = aAnchor, bTo = bAnchor;
    while (aFrom < aTo && bFrom < bTo && aLines.tokens[aFrom] === bLines.tokens[bFrom]) { aFrom++; bFrom++; }
    while (aTo > aFrom && bTo > bFrom && aLines.tokens[aTo - 1] === bLines.tokens[bTo - 1]) { aTo--; bTo--; }
    if (aFrom < aTo || bFrom < bTo) changes.push(change(a, b, aLines, bLines, aFrom, aTo, bFrom, bTo, pairId));
    aCursor = aAnchor + 1; bCursor = bAnchor + 1;
  }
  return {algorithm: 'unique-line-anchors-v1', minimumEditScriptGuaranteed: false,
    complete: true, identical: changes.length === 0, totalChanges: changes.length,
    a: summary(a, aLines, aHash), b: summary(b, bLines, bHash), changes};
}
