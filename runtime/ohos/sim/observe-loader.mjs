// Measurement-only instrumentation. Never import this from the product host.
// This wraps the existing dlopen (including O0's deny-by-default wrapper).
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { isMainThread } from 'node:worker_threads';

if (isMainThread && process.env.DSH_OHOS_MEASURE_LOADER === '1') {
  const original = process.dlopen;
  const emit = (record) => {
    try { fs.writeSync(2, `[dsh-ohos-loader] ${JSON.stringify(record)}\n`); }
    catch { /* Diagnostic collection must not change the native load result. */ }
  };
  emit({ kind: 'observer-ready', node: process.version, platform: process.platform,
    noWasm: typeof WebAssembly === 'undefined',
    nativeCacheDisabled: process.env.NARB_DISABLE_NATIVE_CACHE === '1' });
  process.dlopen = function (module, filename, flags) {
    // A denied or failed dlopen must propagate exactly as it did before.
    const value = Reflect.apply(original, this, arguments);
    try {
      const path = fs.realpathSync(filename);
      const sha256 = createHash('sha256').update(fs.readFileSync(path)).digest('hex');
      const diagnostic = Object.getOwnPropertyDescriptor(module.exports, 'getNativeBindingInfo')?.value;
      const info = typeof diagnostic === 'function' ? Reflect.apply(diagnostic, module.exports, []) : undefined;
      // Read only the native addon's existing, side-effect-free metadata API.
      // Do not require a package or call requireBuiltin to manufacture a load.
      const binding = info && typeof info === 'object' ? {
        product: info.product, backend: info.backend, abi: info.abi, mode: info.mode,
      } : undefined;
      emit({ kind: 'native-load', path, sha256, binding });
    } catch {
      emit({ kind: 'observation-incomplete' });
    }
    return value;
  };
}
