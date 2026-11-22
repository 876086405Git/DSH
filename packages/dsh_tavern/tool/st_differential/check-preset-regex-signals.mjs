// Fixed four-stage file checks only. Native UI, permissions, health and generation
// completion remain independent observations; this tool never rewrites evidence.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

const [recordingDirectory, exportDirectory, throughArgument = '4', ...extra] = process.argv.slice(2);
const usage = 'Usage: node check-preset-regex-signals.mjs <ST-recording-directory> <chat-export-directory> [throughStage:1..4]';
if (!recordingDirectory || !exportDirectory || extra.length || !/^[1-4]$/.test(throughArgument)) {
  throw new Error(usage);
}
const throughStage = Number(throughArgument);
const stages = [
  ['rx-a', '001', 'DSHRXPRESETA', 'DSHRXPOUT'],
  ['rx-a', '002', 'DSHRXPRESETA', 'DSHRXPRAW'],
  ['rx-b', '001', 'DSHRXPRESETB', 'DSHRXPRAW'],
  ['rx-a', '003', 'DSHRXPRESETA', 'DSHRXPOUT'],
].slice(0, throughStage);
const anchor = 'DSHRXANCHOR | DSHRXPRAW | RECORDER_OK';
const markers = ['DSHRXPRESETA', 'DSHRXPRESETB', 'DSHRXANCHOR', 'DSHRXPRAW', 'DSHRXPOUT', 'RECORDER_OK', 'DSHRXDOUT'];
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);

async function readText(file, label) {
  try {
    const text = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(await fs.readFile(file));
    return text.startsWith('\uFEFF') ? text.slice(1) : text;
  } catch (error) {
    throw new Error(`${label}: strict UTF-8 read failed (${error.code ?? error.name})`);
  }
}

function json(text, label) {
  try { return JSON.parse(text); }
  catch { throw new Error(`${label}: invalid JSON`); }
}

function markerCounts(raw, label) {
  const counts = Object.fromEntries(markers.map(marker => [marker, 0]));
  // The complete JSON was validated first. Count decoded string tokens, including
  // keys and strings shadowed by duplicate keys, without joining separate tokens.
  for (const token of raw.matchAll(/"(?:\\.|[^"\\])*"/g)) {
    const value = json(token[0], label);
    for (const marker of markers) counts[marker] += value.split(marker).length - 1;
  }
  return counts;
}

async function check() {
  const directories = new Map((await fs.readdir(recordingDirectory, { withFileTypes: true }))
    .map(entry => [entry.name, entry]));
  for (const id of ['rx-a', 'rx-b']) {
    const expected = stages.filter(stage => stage[0] === id).map(stage => `${stage[1]}.request.raw.json`).sort();
    const directory = directories.get(id);
    if (!directory) {
      assert.equal(expected.length, 0, `${id}: missing capture directory`);
      continue;
    }
    assert(directory.isDirectory(), `${id}: expected a capture directory`);
    const actual = (await fs.readdir(path.join(recordingDirectory, id)))
      .filter(name => name.endsWith('.request.raw.json')).sort();
    assert.deepEqual(actual, expected, `${id}: exact capture files through stage ${throughStage}`);
  }
  const expectedExports = stages.map((_, index) => `stage-${index + 1}.jsonl`);
  const actualExports = (await fs.readdir(exportDirectory)).filter(name => name.endsWith('.jsonl')).sort();
  assert.deepEqual(actualExports, expectedExports, `exact chat exports through stage ${throughStage}`);

  const reports = [];
  for (const [index, [id, attempt, main, promptMarker]] of stages.entries()) {
    const stage = index + 1;
    const capture = `${id}/${attempt}`;
    const rawLabel = `${capture}.request.raw.json`;
    const raw = await readText(path.join(recordingDirectory, id, `${attempt}.request.raw.json`), rawLabel);
    const request = json(raw, rawLabel);
    assert(object(request), `${rawLabel}: request object`);
    assert(!Object.hasOwn(request, 'tools') && !Object.hasOwn(request, 'tool_choice'), `${rawLabel}: no tool attributes`);
    assert(Array.isArray(request.messages) && request.messages.length > 0
      && request.messages.every(message => object(message) && typeof message.content === 'string'),
    `${rawLabel}: text messages`);
    const counts = markerCounts(raw, rawLabel);
    const wanted = { [main]: 1, DSHRXANCHOR: 1, [promptMarker]: 1, RECORDER_OK: stage };
    for (const marker of markers) {
      assert.equal(counts[marker], wanted[marker] ?? 0, `${rawLabel}: global count ${marker}`);
    }
    const mainMessage = request.messages.find(message => message.content.includes(main));
    const anchorMessage = request.messages.find(message => message.content.includes('DSHRXANCHOR'));
    assert(mainMessage?.role === 'system', `${rawLabel}: main role`);
    assert(anchorMessage?.role === 'assistant', `${rawLabel}: anchor role`);
    assert(anchorMessage.content.includes(`DSHRXANCHOR | ${promptMarker} | RECORDER_OK`), `${rawLabel}: complete anchor`);

    const exportLabel = `stage-${stage}.jsonl`;
    const text = await readText(path.join(exportDirectory, exportLabel), exportLabel);
    const rows = [];
    for (const [line, value] of text.split(/\r\n|\r|\n/).entries()) {
      if (/^[ \t]*$/.test(value)) continue;
      const row = json(value, `${exportLabel}:${line + 1}`);
      assert(object(row), `${exportLabel}:${line + 1}: JSON object`);
      rows.push(row);
    }
    const [header, ...messages] = rows;
    assert(object(header) && object(header.chat_metadata)
      && !Object.hasOwn(header, 'mes') && !Object.hasOwn(header, 'is_user'), `${exportLabel}: chat header`);
    assert.equal(messages.length, 1 + 2 * stage, `${exportLabel}: complete message count`);
    for (const [messageIndex, message] of messages.entries()) {
      const user = messageIndex % 2 === 1;
      const expected = messageIndex === 0 ? anchor : user ? 'Please continue.' : 'RECORDER_OK';
      const label = `${exportLabel}: message ${messageIndex + 1}`;
      assert(message.is_user === user, `${label}: boolean role`);
      assert(!Object.hasOwn(message, 'is_system') || message.is_system === false, `${label}: not a system message`);
      assert(typeof message.mes === 'string' && message.mes === expected, `${label}: exact stored text`);
    }
    reports.push({ checkedThrough: throughStage, stage, capture, wireSignals: 'passed', exportSignals: 'passed',
      exportMessages: messages.length, recorderMarkerCount: counts.RECORDER_OK });
  }
  for (const report of reports) console.log(JSON.stringify(report));
}

try { await check(); }
catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
