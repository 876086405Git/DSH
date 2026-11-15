'use strict';

const fs = require('node:fs');
const path = require('node:path');
const libraries = Object.freeze({
  flock: 'libdsh_flock.so',
  'require-builtin': 'libdsh_require_builtin.so',
});
const loaded = new Map();

function failure(code, message) { return Object.assign(new Error(message), { code }); }

function load(product) {
  if (process.platform !== 'openharmony' || !Object.hasOwn(libraries, product)) {
    throw failure('ERR_OHOS_NATIVE_PRODUCT', 'This native product is not packaged for OpenHarmony');
  }
  if (loaded.has(product)) return loaded.get(product);
  // Set only by the trusted Ark/native host, never by the Dart env map.
  const directory = process.env.DSH_GO_OHOS_NATIVE_LIBRARY_DIR;
  if (typeof directory !== 'string' || !path.isAbsolute(directory) || directory.includes('\0')) {
    throw failure('ERR_OHOS_NATIVE_LIBRARY_DIRECTORY', 'The application native-library directory is unavailable');
  }
  let filename;
  try {
    const root = fs.realpathSync(directory);
    filename = path.join(root, libraries[product]);
    if (root === path.parse(root).root || !fs.statSync(root).isDirectory() ||
        fs.realpathSync(filename) !== filename || !fs.statSync(filename).isFile()) throw new Error();
  } catch {
    throw failure('ERR_OHOS_NATIVE_LIBRARY_PATH', 'A required library is missing or outside the application library directory');
  }
  // .so is the HAP library filename; require(.so) would parse it as JavaScript.
  // This is an explicit call for two fixed libraries, not a built-in override.
  const module = { exports: {} };
  process.dlopen(module, filename);
  const result = Object.freeze({ binding: module.exports, path: filename });
  loaded.set(product, result);
  return result;
}

module.exports = { load };
