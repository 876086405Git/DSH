// This test preload captures the public native function without making a request.
globalThis[Symbol.for('dsh.ohos.test.nativeFetch')] = globalThis.fetch;
