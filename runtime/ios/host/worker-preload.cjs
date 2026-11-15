'use strict';

// Synchronous --require also runs in classic eval Workers, unlike --import.
// Keep the user's entry source untouched, including its directive prologue.
const workers = require('node:worker_threads');
const { syncBuiltinESMExports } = require('node:module');
const NativeWorker = workers.Worker;
workers.Worker = class Worker extends NativeWorker {
  constructor(filename, options) {
    const effective = { ...options, trackUnmanagedFds: false };
    // An omitted execArgv must remain omitted: passing inherited --jitless
    // explicitly is rejected by Node. Explicit arrays need this preload even
    // when the caller requested no other Node startup flags.
    if (Array.isArray(effective.execArgv)) {
      effective.execArgv = ['--require', __filename, ...effective.execArgv];
    }
    super(filename, effective);
  }
};
syncBuiltinESMExports();
