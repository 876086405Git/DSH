// Test-only, explicit preload. An environment variable never enables simulation.
// Workers recreate this isolate-local marker by inheriting the --import argument.
globalThis[Symbol.for('dsh.go.ohos.sim')] = true;
