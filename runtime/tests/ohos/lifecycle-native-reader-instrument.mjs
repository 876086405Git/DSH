// Test-only, exact-module instrumentation. The native getter and Node builtins
// are untouched; these records count source-level validations/frozen copies.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { registerHooks } from 'node:module';

const target = new URL('../../ohos/lifecycle/native-host.mjs', import.meta.url).href;
export const instrumentation = { target, transforms: 0 };
export const builtinIdentity = { freeze: Object.freeze, linkedBinding: process._linkedBinding };

registerHooks({
  load(url, context, nextLoad) {
    const loaded = nextLoad(url, context);
    if (url !== target) return loaded;
    const original = String(loaded.source);
    const entry = 'export function validateHostSnapshot(value) {';
    const result = '  return Object.freeze({ ...value });';
    assert.equal(original.split(entry).length, 2, 'one actual validator entry');
    assert.equal(original.split(result).length, 2, 'one actual successful freeze');
    const modified = original.replace(entry, entry +
      '\n  const __validationRow = { input: value }; __nativeReaderValidationTrace.push(__validationRow);')
      .replace(result, '  const __validated = Object.freeze({ ...value });\n' +
        '  __validationRow.output = __validated;\n  return __validated;') +
      '\nexport const __nativeReaderValidationTrace = [];\n';
    instrumentation.transforms++;
    instrumentation.originalSha256 = createHash('sha256').update(original).digest('hex');
    instrumentation.instrumentedSha256 = createHash('sha256').update(modified).digest('hex');
    return { ...loaded, source: modified };
  },
});
