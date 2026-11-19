// Checks the paired real ST captures without rewriting either request.
// Capture, state, guard, and full-byte comparison remain separate gates.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

const [root, ...extra] = process.argv.slice(2);
if (!root || extra.length) throw new Error('Usage: node check-assistant-tail-signals.mjs <ST-recording-directory>');
const main = 'DESK-MAIN: Help the visitor at the reception desk.';
const guidance = 'DESK-GUIDANCE: Keep the reply concise.';
const greeting = 'Welcome to the reception desk.';
const question = 'Please tell me the next step.';
const depth = 'DESK-DEPTH: Check the latest visitor request.';
const otherTail = 'DESK-TAIL-A: End with one practical next step.';
const tail = 'DESK-TAIL-B: End with one short question.';

for (const [id, assistantTail] of [['22-ordinary-off', false], ['24-ordinary-assistant-tail', true]]) {
  const raw = await fs.readFile(path.join(root, id, '001.request.raw.json'));
  const request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
  assert(Array.isArray(request.messages)
    && request.messages.every(message => typeof message?.content === 'string'), `${id}: text messages`);
  const messages = request.messages;
  const text = messages.map(message => message.content).join('\n');
  const wanted = [main, greeting, depth, question, tail];
  for (const marker of wanted) {
    assert.equal(text.split(marker).length - 1, 1, `${id}: exactly once ${marker}`);
  }
  for (const marker of [guidance, otherTail]) assert(!text.includes(marker), `${id}: absent ${marker}`);
  assert(wanted.every((marker, index) => index === 0 || text.indexOf(marker) > text.indexOf(wanted[index - 1])),
    `${id}: source order`);
  for (const [marker, role] of [[main, 'system'], [greeting, 'assistant'], [question, 'user']]) {
    assert.equal(messages.find(message => message.content.includes(marker)).role, role, `${id}: role ${marker}`);
  }
  const last = messages.at(-1);
  if (assistantTail) {
    assert.equal(last.role, 'assistant', `${id}: final assistant`);
    assert.equal(last.content, tail, `${id}: exact assistant tail`);
    assert.equal(last.prefix, true, `${id}: boolean prefix`);
    assert(!Object.hasOwn(last, 'reasoning_content'), `${id}: no reasoning tail`);
  } else {
    assert.equal(last.role, 'user', `${id}: final user`);
    assert(last.content.endsWith(tail), `${id}: final system tail after post-processing`);
    assert(!Object.hasOwn(last, 'prefix'), `${id}: no prefix property`);
  }
  console.log(JSON.stringify({
    id, referenceSignals: 'passed', lastRole: last.role, prefixPresent: Object.hasOwn(last, 'prefix'),
  }));
}
