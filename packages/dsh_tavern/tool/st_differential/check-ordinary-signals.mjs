// Checks observable inputs in the two real ST captures, without rewriting them.
// This does not replace the capture, state, guard, or full-byte comparison gates.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';

const [root, ...extra] = process.argv.slice(2);
if (!root || extra.length) throw new Error('Usage: node check-ordinary-signals.mjs <ST-recording-directory>');
const main = 'DESK-MAIN: Help the visitor at the reception desk.';
const guidance = 'DESK-GUIDANCE: Keep the reply concise.';
const greeting = 'Welcome to the reception desk.';
const question = 'Please tell me the next step.';
const depth = 'DESK-DEPTH: Check the latest visitor request.';
const tails = ['DESK-TAIL-A: End with one practical next step.', 'DESK-TAIL-B: End with one short question.'];

for (const [id, on] of [['21-ordinary-on', true], ['22-ordinary-off', false]]) {
  const raw = await fs.readFile(path.join(root, id, '001.request.raw.json'));
  const request = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(raw));
  assert(Array.isArray(request.messages)
    && request.messages.every(message => typeof message?.content === 'string'), `${id}: text messages`);
  const messages = request.messages;
  const text = messages.map(message => message.content).join('\n');
  const wanted = [main, ...(on ? [guidance] : []), greeting, depth, question, tails[on ? 0 : 1]];
  for (const marker of wanted) {
    assert.equal(text.split(marker).length - 1, 1, `${id}: exactly once ${marker}`);
  }
  for (const marker of [tails[on ? 1 : 0], ...(on ? [] : [guidance])]) {
    assert(!text.includes(marker), `${id}: absent ${marker}`);
  }
  assert(wanted.every((marker, index) => index === 0 || text.indexOf(marker) > text.indexOf(wanted[index - 1])),
    `${id}: source order`);
  for (const [marker, role] of [[main, 'system'], [greeting, 'assistant'], [question, 'user']]) {
    assert.equal(messages.find(message => message.content.includes(marker)).role, role, `${id}: role ${marker}`);
  }
  console.log(JSON.stringify({ id, referenceSignals: 'passed' }));
}
