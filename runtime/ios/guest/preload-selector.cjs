'use strict';
// Invoked only by the trusted installed Environment's native preload callback.
// Node propagates that callback to Workers before any user module runs.
const { registerHooks } = require('node:module');
const { readFileSync } = require('node:fs');
const { pathToFileURL } = require('node:url');
const { resolve } = require('node:path');
const original = pathToFileURL(resolve(__dirname, '../../ohos/preload.mjs')).href;
const replacement = resolve(__dirname, '../../ohos/preload-guest.mjs');
registerHooks({ load(url, context, nextLoad) {
  if (url !== original) return nextLoad(url, context);
  return { format: 'module', source: readFileSync(replacement, 'utf8'), shortCircuit: true };
} });
