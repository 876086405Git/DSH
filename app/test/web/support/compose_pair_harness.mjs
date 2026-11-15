import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

// A normal editable surface and its paste event: no browser/network or user data.
const messages = [];
const pasted = [];
const editor = {
  textContent: '',
  getClientRects: () => [{}],
  closest() { return null; },
  focus() {},
  dispatchEvent(event) {
    const text = event.clipboardData.getData('text/plain');
    this.textContent += text;
    pasted.push(text);
    return true;
  },
};
class DataTransfer {
  values = new Map();
  items = {add() { throw new Error('this fixture has no files'); }};
  setData(k, v) { this.values.set(k, v); }
  getData(k) { return this.values.get(k) ?? ''; }
}
class ClipboardEvent {
  constructor(type, fields) { this.type = type; Object.assign(this, fields); }
}
const document = {
  addEventListener() {},
  querySelectorAll(selector) {
    return selector === '[data-lexical-editor="true"][contenteditable="true"]' ? [editor] : [];
  },
};
const window = {DshAppCompose: {postMessage(value) { messages.push(JSON.parse(value)); }}};
const context = vm.createContext({
  window, document, location: {href: 'https://fixture.invalid/'},
  sessionStorage: {getItem: () => null, removeItem() {}},
  history: {replaceState() {}}, URL, Date, setTimeout, clearTimeout,
  DataTransfer, ClipboardEvent,
});
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), context, {filename: process.argv[2]});
const drafts = process.argv[3] ? JSON.parse(process.argv[3]) : [{text: 'first ordinary draft', files: []}, {text: 'second ordinary draft', files: []}];
await Promise.all(drafts.map(draft => window.__dshAppCompose(draft)));
assert.deepEqual(pasted, drafts.map(x => x.text));
assert.equal(messages.length, drafts.length);
assert.ok(messages.every(x => x.text === true && x.files === 0));
process.stdout.write(JSON.stringify({drafts, messages, pasted, scope: 'Exact full JS; synthetic ordinary DOM/paste; actual 400ms timers; no WebKit.'}) + '\n');
