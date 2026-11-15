// Run with Node 24 and DSH_WEBVIEW_FORK pointing at the actual OHOS package.
// Executes the actual callback/getter bodies with a handler double; this is not
// an ArkWeb device test or an ArkTS compiler substitute.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { stripTypeScriptTypes } from 'node:module';
import { join } from 'node:path';
import test from 'node:test';
import vm from 'node:vm';

const root = process.env.DSH_WEBVIEW_FORK;
assert.ok(root, 'Set DSH_WEBVIEW_FORK to webview_flutter_ohos');
const ets = 'ohos/src/main/ets/io.flutter.plugins/webview_flutter';
const view = readFileSync(join(root, ets, 'OhosWebView.ets'), 'utf8');
const settings = readFileSync(join(root, ets, 'WebViewHostApiImpl.ets'), 'utf8');
for (const [name, text] of [['OhosWebView.ets', view], ['WebViewHostApiImpl.ets', settings]]) {
  console.log(JSON.stringify({ input: name, bytes: Buffer.byteLength(text),
    sha256: createHash('sha256').update(text).digest('hex') }));
}

// These pinned source sections contain no braces in strings or comments. Refuse
// a changed shape instead of silently executing a rewritten equivalent fixture.
function body(text, anchor) {
  const start = text.indexOf(anchor);
  assert.ok(start >= 0 && text.indexOf(anchor, start + 1) === -1, anchor);
  const open = text.indexOf('{', start + anchor.length);
  assert.ok(open >= 0);
  let depth = 1;
  for (let end = open + 1; end < text.length; end++) {
    if (text[end] === '{') depth++;
    if (text[end] === '}') depth--;
    if (depth === 0) return text.slice(open + 1, end);
  }
  assert.fail('Unterminated source section: ' + anchor);
}

const sslBody = body(view, '.onSslErrorEventReceive((event) =>');
const modeBody = body(view, 'getMixedModeValue(): MixedMode');
const initialModes = [...settings.matchAll(/\bmixedMode\s*:\s*number\s*=\s*(\d+)\s*;/g)];
assert.equal(initialModes.length, 1, 'Exactly one actual mixed-mode default');
const initialMode = Number(initialModes[0][1]);
const callback = vm.runInNewContext('(event) => {' + sslBody + '}');
// The enum object supplies distinct symbols; no SDK numeric value is assumed.
const MixedMode = Object.freeze({ All: Symbol('All'), Compatible: Symbol('Compatible'), None: Symbol('None') });
const getter = vm.runInNewContext(stripTypeScriptTypes('(function () {' + modeBody + '})'), { MixedMode });
const modeValue = mode => getter.call({ webView: { getWebSettings: () => ({ getMixedMode: () => mode }) } });

test('certificate error is rejected exactly once and never confirmed', () => {
  const calls = [];
  callback({ handler: { handleCancel: () => calls.push('cancel'), handleConfirm: () => calls.push('confirm') } });
  assert.deepEqual(calls, ['cancel']);
});

test('new WebView defaults to no mixed content and the actual builder uses it', () => {
  assert.match(view, /\.mixedMode\(this\.getMixedModeValue\(\)\)/);
  assert.equal(modeValue(initialMode), MixedMode.None);
});

test('explicit modes retain their mapping; unknown input never enables mixed content', () => {
  assert.equal(modeValue(0), MixedMode.All);
  assert.equal(modeValue(1), MixedMode.Compatible);
  assert.equal(modeValue(2), MixedMode.None);
  for (const mode of [-1, 3, 999, NaN]) assert.equal(modeValue(mode), MixedMode.None);
});
