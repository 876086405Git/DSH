// Loaded only by the installed-only preload chosen by the native host.
// Keep original module URLs: relative imports and package identity stay unchanged.
import { registerHooks } from 'node:module';
import { readFileSync } from 'node:fs';
const root = new URL('../../../', import.meta.url);
const files = JSON.parse(readFileSync(new URL('./overrides.json', import.meta.url), 'utf8'));
const approved = new Set(["runtime/ohos/process/index.mjs", "node_modules/@deepseek-ai/dsh-tool-fs/lib/index.js", "node_modules/@deepseek-ai/dsh-fs-local/lib/index.js", "node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js", "runtime/ohos/process/worker.mjs", "runtime/ohos/process/runtime.mjs", "runtime/ohos/capabilities/snapshot.mjs", "node_modules/@deepseek-ai/dsh-tool-bash/lib/index.js", "node_modules/@deepseek-ai/dsh-bash-sandbox/lib/index.js"]);
if (Object.keys(files).length !== approved.size || Object.entries(files).some(([source, target]) =>
  !approved.has(source) || target !== 'runtime/ios/guest/overrides/' + source)) {
  throw new Error('Guest override manifest differs from the fixed iOS module whitelist');
}
const sources = new Map(Object.entries(files).map(([source, replacement]) =>
  [new URL(source, root).href, new URL(replacement, root)]));
registerHooks({ load(url, context, nextLoad) {
  const replacement = sources.get(url);
  if (!replacement) return nextLoad(url, context);
  return { format: 'module', source: readFileSync(replacement, 'utf8'), shortCircuit: true };
} });
