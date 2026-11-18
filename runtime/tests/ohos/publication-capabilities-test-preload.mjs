// Test instrumentation only: observe the real service without adding an HTTP
// mutation route. The parent controls a private child-process IPC channel.
const original = process._linkedBinding;
let nativeCalls = 0;
process._linkedBinding = function (name) {
  const binding = original.call(this, name);
  if (name !== 'dsh_ohos_publication') return binding;
  return { ...binding, renameNoReplace(...args) {
    nativeCalls++;
    if (process.env.M6_TEST_RENAME_RESULT === 'EINVAL') {
      throw Object.assign(new Error('Explicit test-only renameat2 failure'),
        { code: 'EINVAL', syscall: 'renameat2', errno: -22 });
    }
    return binding.renameNoReplace(...args);
  } };
};
process.on('message', async message => {
  const service = globalThis[Symbol.for('dsh.go.ohos.publication')];
  try {
    let result;
    if (message.operation === 'publish') result = await service.publish(message.source, message.target);
    else if (message.operation !== 'observe') throw new Error('Unknown test operation');
    process.send({ id: message.id, ok: true, nativeCalls, atomic: service.atomic,
      systemVersion: service.systemVersion, result });
  } catch (error) {
    process.send({ id: message.id, ok: false, nativeCalls,
      error: { code: error.code, message: error.message, committed: error.committed } });
  }
});
