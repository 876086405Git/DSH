// Executes the real PastePrompt lifecycle class. Only the ArkUI @Builder render
// body and platform objects are seams; this cannot grant device authorization.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

export function promptFixture(ts, hooks = {}) {
  const source = process.env.OHOS_PASTE_PROMPT_SOURCE || new URL('../../../app/ohos/entry/src/main/ets/plugins/PastePrompt.ets', import.meta.url);
  const original = readFileSync(source, 'utf8');
  const start = original.indexOf('@Builder\nfunction pasteContent(');
  const end = original.indexOf('// This is the only UI boundary replaced by the Linux contract fixture.');
  assert(start >= 0 && end > start, 'Expected the original explicit ArkUI render boundary');
  const rendered = original.slice(0, start) + 'function pasteContent(_actions: PasteActions): void {}\n\n' + original.slice(end);
  const compiled = ts.transpileModule(rendered, { compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
  } });
  const listeners = new Set(), contents = [], opens = [], closes = [], feedbacks = [];
  const events = Object.fromEntries(['WINDOW_SHOWN', 'WINDOW_ACTIVE', 'WINDOW_INACTIVE', 'WINDOW_HIDDEN', 'WINDOW_DESTROYED'].map(x => [x, x]));
  const emit = value => { for (const listener of [...listeners]) listener(value); };
  const prompt = {
    async openCustomDialog(content, options) {
      opens.push({content, options});
      if (hooks.openEvent) emit(events[hooks.openEvent]);
      await hooks.open?.();
    },
    async closeCustomDialog(content) { closes.push(content); await hooks.close?.(closes.length); },
    showToast(value) { feedbacks.push(value); },
  };
  const win = {
    on(name, listener) { assert.equal(name, 'windowEvent'); listeners.add(listener); },
    off(name, listener) { assert.equal(name, 'windowEvent'); assert(listeners.delete(listener)); },
    getUIContext() { return {getPromptAction: () => prompt}; },
  };
  class ComponentContent {
    constructor(_ui, _builder, actions) { this.actions = actions; this.disposed = false; contents.push(this); }
    dispose() { assert.equal(this.disposed, false); this.disposed = true; }
  }
  const module = {exports: {}};
  vm.runInNewContext(compiled.outputText, {module, exports: module.exports, wrapBuilder: builder => builder,
    require(name) {
      if (name === '@ohos.window') return {default: {WindowEventType: events, async getLastWindow() { await hooks.window?.(); return win; }}};
      if (name === '@ohos.arkui.node') return {ComponentContent};
      throw Error('unmapped prompt import ' + name);
    },
  });
  return {PastePrompt: module.exports.PastePrompt, emit, events, contents, opens, closes, feedbacks, listeners};
}
