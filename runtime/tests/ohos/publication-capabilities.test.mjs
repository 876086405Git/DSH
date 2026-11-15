import test from 'node:test';
import assert from 'node:assert/strict';
import { readPublicationCapabilities } from '../../ohos/publication/capabilities.mjs';

const symbol = Symbol.for('dsh.go.ohos.publication');
const unknown = { publication: { atomic: 'unknown', systemVersion: null } };
const version = 'ohos-build-v1:' + 'a'.repeat(64);
async function withService(value, fn) {
  const original = Object.getOwnPropertyDescriptor(globalThis, symbol);
  assert(!original || original.configurable, 'this isolated contract suite must not replace a production service');
  if (value === undefined) delete globalThis[symbol];
  else Object.defineProperty(globalThis, symbol, { configurable: true, value });
  try { await fn(); }
  finally {
    if (original) Object.defineProperty(globalThis, symbol, original);
    else delete globalThis[symbol];
  }
}
const publish = () => { throw new Error('capability reads must never publish'); };

// These malformed/legacy declarations are explicit test inputs; the separate
// SIGKILL integration suite reads a real installed service in fresh processes.
test('absent and older v1 services report unknown without inventing support', async () => {
  await withService(undefined, () => assert.deepEqual(readPublicationCapabilities(), unknown));
  await withService(Object.freeze({ protocolVersion: 1, publish }), () => assert.deepEqual(readPublicationCapabilities(), unknown));
});

test('each actual state is read live into a fresh immutable snapshot', async () => {
  let atomic = 'untried';
  const service = Object.freeze({ protocolVersion: 1, publish, get atomic() { return atomic; }, systemVersion: version });
  await withService(service, () => {
    const first = readPublicationCapabilities();
    for (const next of ['untried', 'trying', 'available', 'unsupported', 'disabled-after-crash']) {
      atomic = next;
      const snapshot = readPublicationCapabilities();
      assert.deepEqual(snapshot, { publication: { atomic: next, systemVersion: version } });
      assert(Object.isFrozen(snapshot)); assert(Object.isFrozen(snapshot.publication));
      assert.notStrictEqual(snapshot, first); assert.notStrictEqual(snapshot.publication, first.publication);
      assert.equal(Reflect.set(snapshot.publication, 'atomic', 'available'), false);
      assert.equal(service.atomic, next);
    }
    assert.equal(first.publication.atomic, 'untried', 'a previous response must not change as the service advances');
  });
});

test('unknown and malformed state values remain unknown while an independent valid version survives', async () => {
  for (const atomic of ['future-state', '', true, false, 1, null, undefined, [], {}]) {
    await withService({ protocolVersion: 1, publish, atomic, systemVersion: version }, () => {
      assert.deepEqual(readPublicationCapabilities(), { publication: { atomic: 'unknown', systemVersion: version } });
    });
  }
});

test('invalid version values become null without erasing a valid state', async () => {
  for (const systemVersion of [null, undefined, '', '   ', true, 1, {}, [], 'x\0y', '\ud800', 'x'.repeat(4097)]) {
    await withService({ protocolVersion: 1, publish, atomic: 'available', systemVersion }, () => {
      assert.deepEqual(readPublicationCapabilities(), { publication: { atomic: 'available', systemVersion: null } });
    });
  }
});

test('unknown protocols and non-installed declarations are not interpreted as a v1 service', async () => {
  for (const protocolVersion of [2, '1', null, undefined]) {
    await withService({ protocolVersion, publish,
      get atomic() { throw new Error('do not read an unknown protocol'); },
      get systemVersion() { throw new Error('do not read an unknown protocol'); } }, () => {
      assert.deepEqual(readPublicationCapabilities(), unknown);
    });
  }
  await withService({ protocolVersion: 1, atomic: 'available', systemVersion: version }, () => assert.deepEqual(readPublicationCapabilities(), unknown));
});

test('one getter read per field, no native load, and no publication side effect', async () => {
  let atomicReads = 0, versionReads = 0;
  const binding = process._linkedBinding;
  process._linkedBinding = () => { throw new Error('capability reads must never load native code'); };
  try {
    await withService(Object.freeze({ protocolVersion: 1, publish,
      get atomic() { atomicReads++; return 'disabled-after-crash'; },
      get systemVersion() { versionReads++; return version; } }), () => {
      for (let i = 0; i < 21; i++) assert.deepEqual(readPublicationCapabilities(), {
        publication: { atomic: 'disabled-after-crash', systemVersion: version },
      });
      assert.equal(atomicReads, 21); assert.equal(versionReads, 21);
    });
  } finally { process._linkedBinding = binding; }
});
