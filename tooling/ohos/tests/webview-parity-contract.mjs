// Runs with Node 24 (see webview-fork-fixture.mjs for the environment). Executes
// the actual component callback and attribute expressions of the prepared fork
// with ArkWeb as a double. Whether a page really follows, or a renderer really
// reports, is the device's to prove.
import assert from 'node:assert/strict';
import { stripTypeScriptTypes } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { forkClasses, forkSource, RenderExitReason } from './webview-fork-fixture.mjs';

const view = forkSource('OhosWebView.ets');

// As webview-security-contract.mjs: pinned sections with no braces in strings or
// comments. A changed shape is refused rather than executed as a rewrite.
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

function only(text, pattern, what) {
  const found = [...text.matchAll(pattern)];
  assert.equal(found.length, 1, what);
  return found[0];
}

const WebDarkMode = Object.freeze({ Off: Symbol('Off'), On: Symbol('On'), Auto: Symbol('Auto') });
const web = body(view, 'Column()');
const initial = only(view, /@State darkMode: boolean = (.+);/g, 'one darkMode state')[1];
const attribute = only(web, /^\s*\.darkMode\((.+)\)$/gm, 'one darkMode attribute')[1];
const evaluate = expression => vm.runInNewContext(`(function () { return ${expression}; })`, { WebDarkMode });
const appear = vm.runInNewContext(stripTypeScriptTypes(`(function () {${body(view, 'aboutToAppear()')}})`),
  { commonEventManager: { createSubscriber() {} } });
const exited = vm.runInNewContext(stripTypeScriptTypes(
  `(function (event: OnRenderExitedEvent) {${body(web, '.onRenderExited((event: OnRenderExitedEvent) =>')}})`));

/** The struct as ArkUI would hold it: its @State initialiser, then aboutToAppear. */
function component(webView) {
  const struct = { webView, subscriber: null, disposed: false };
  struct.darkMode = evaluate(initial).call(struct);
  appear.call(struct);
  struct.mode = () => evaluate(attribute).call(struct);
  struct.exited = event => exited.call(struct, event);
  return struct;
}

function platformView() {
  const { InstanceManager, WebViewPlatformView } = forkClasses();
  const instances = new InstanceManager({ onFinalize() {} });
  return new WebViewPlatformView({}, instances);
}

test('a new WebView is light until told otherwise, as with force dark off on Android', () => {
  assert.equal(component(platformView()).mode(), WebDarkMode.Off);
});

test('dark set before the Web component exists is what it starts with', () => {
  const webView = platformView();
  webView.setDarkMode(true);
  assert.equal(component(webView).mode(), WebDarkMode.On);
});

test('dark switches at run time on the Web component that is up', () => {
  const webView = platformView();
  const struct = component(webView);
  webView.setDarkMode(true);
  assert.equal(struct.mode(), WebDarkMode.On);
  webView.setDarkMode(false);
  assert.equal(struct.mode(), WebDarkMode.Off);
});

test('a Web component rebuilt on the same WebView keeps the mode and takes over the switch', () => {
  const webView = platformView();
  component(webView);
  webView.setDarkMode(true);
  const rebuilt = component(webView);
  assert.equal(rebuilt.mode(), WebDarkMode.On);
  webView.setDarkMode(false);
  assert.equal(rebuilt.mode(), WebDarkMode.Off);
});

test('the page draws its own dark theme: nothing forces colours, as DARK_STRATEGY_WEB_THEME_DARKENING_ONLY', () => {
  assert.equal(view.includes('forceDarkAccess'), false);
});

test('the Web component reports its renderer through the WebView that owns it', () => {
  const first = platformView(), second = platformView();
  const seen = [];
  first.setOnRenderExitedCallback(crashed => seen.push(['first', crashed]));
  second.setOnRenderExitedCallback(crashed => seen.push(['second', crashed]));
  component(first).exited({ renderExitReason: RenderExitReason.ProcessCrashed });
  assert.deepEqual(seen, [['first', true]]);
  component(second).exited({ renderExitReason: RenderExitReason.ProcessOom });
  assert.deepEqual(seen, [['first', true], ['second', false]]);
});

test('a Web component on its way out reports nothing; its replacement does', () => {
  const webView = platformView();
  const seen = [];
  webView.setOnRenderExitedCallback(crashed => seen.push(crashed));
  const leaving = component(webView);
  webView.dispose();
  assert.equal(leaving.disposed, true);
  leaving.exited({ renderExitReason: RenderExitReason.ProcessAbnormalTermination });
  assert.deepEqual(seen, []);
  component(webView).exited({ renderExitReason: RenderExitReason.ProcessCrashed });
  assert.deepEqual(seen, [true]);
});

test('only an observed crash counts as one, as RenderProcessGoneDetail.didCrash', () => {
  const webView = platformView();
  const seen = [];
  webView.setOnRenderExitedCallback(crashed => seen.push(crashed));
  for (const reason of Object.values(RenderExitReason)) webView.onRenderExited({ renderExitReason: reason });
  assert.deepEqual(seen, [false, false, true, false, false]);
});

test('a renderer exit nobody asked about is dropped, not thrown', () => {
  const webView = platformView();
  webView.onRenderExited({ renderExitReason: RenderExitReason.ProcessCrashed });
  const seen = [];
  webView.setOnRenderExitedCallback(crashed => seen.push(crashed));
  webView.setOnRenderExitedCallback(undefined);
  webView.onRenderExited({ renderExitReason: RenderExitReason.ProcessCrashed });
  assert.deepEqual(seen, []);
});
