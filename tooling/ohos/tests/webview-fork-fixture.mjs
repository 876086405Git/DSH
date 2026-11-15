// Loads webview_flutter_ohos's actual ETS after TypeScript erasure, with ArkWeb
// and the embedding as doubles. Set DSH_WEBVIEW_FORK to the prepared package and
// OHOS_TYPESCRIPT_PREFIX to runtime/ohos/process after its npm ci. This is not an
// ArkTS compiler or a device test.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve } from 'node:path';
import vm from 'node:vm';

const root = process.env.DSH_WEBVIEW_FORK;
assert.ok(root, 'Set DSH_WEBVIEW_FORK to webview_flutter_ohos');
const prefix = process.env.OHOS_TYPESCRIPT_PREFIX;
assert.ok(prefix, 'Set OHOS_TYPESCRIPT_PREFIX to the fixed runtime/ohos/process npm-ci directory');
const ts = createRequire(resolve(prefix, 'package.json'))('typescript');
const ets = 'ohos/src/main/ets/io.flutter.plugins/webview_flutter';

export const forkSource = name => readFileSync(join(root, ets, name), 'utf8');

/** The public enum of OpenHarmony SDK 26 `ets/component/web.d.ts`. */
export const RenderExitReason = Object.freeze({ ProcessAbnormalTermination: 0, ProcessWasKilled: 1,
  ProcessCrashed: 2, ProcessOom: 3, ProcessExitUnknown: 4 });

/** Evaluates one ETS module; [imports] is everything it may reach at run time. */
export function loadEts(source, imports, globals = {}) {
  const { outputText } = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
  } });
  const module = { exports: {} };
  vm.runInNewContext(outputText, { exports: module.exports, module, ...globals,
    require(name) {
      assert.ok(name in imports, `Unexpected import ${name}`);
      return imports[name];
    } });
  return module.exports;
}

/** As documented: every call but construction needs a bound Web component. */
export class ControllerDouble {
  bound = true;
  calls = [];
  touch(name) {
    if (!this.bound) throw Object.assign(new Error('Init error'), { code: 17100001 });
    this.calls.push(name);
  }
  onActive() { this.touch('onActive'); }
  onInactive() { this.touch('onInactive'); }
  stopAllMedia() { this.touch('stopAllMedia'); }
}

const log = { default: { i() {}, d() {}, w() {}, e() {} } };

/** The fork's real InstanceManager and WebViewPlatformView. */
export function forkClasses() {
  const { InstanceManager } = loadEts(forkSource('InstanceManager.ets'), {
    '@ohos/flutter_ohos/src/main/ets/util/Log': log,
  }, { setTimeout: () => 0, clearTimeout() {} });
  class Stub {}
  const { WebViewPlatformView } = loadEts(forkSource('WebViewHostApiImpl.ets'), {
    '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView': { default: Stub },
    '@ohos/flutter_ohos/src/main/ets/view/DynamicView/dynamicView': { DVModelParameters: Stub },
    '@ohos/flutter_ohos/src/main/ets/util/Log': log,
    '@ohos.web.webview': { default: { WebviewController: ControllerDouble, WebCookieManager: Stub } },
    '@ohos.window': { default: {} },
    './GeneratedOhosWebView': { WebViewHostApi: Stub, HttpAuthHandler: Stub, WebViewPoint: Stub },
    './OhosWebView': { WebBuilder() {}, OhosWebView: Stub },
    './WebViewFlutterApiImpl.ets': { WebViewFlutterApiImpl: Stub },
    './DisplayListenerProxy': { DisplayListenerProxy: Stub },
    './InstanceManager': { InstanceManager },
  }, { RenderExitReason });
  return { InstanceManager, WebViewPlatformView };
}
