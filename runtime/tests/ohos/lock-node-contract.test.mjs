import assert from 'node:assert/strict';
import { mkdtemp, open, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { loadInternals } from './load-internals.mjs';

test('固定 Node 的实例 close 绑定、Promise 和锁释放契约必须一起复核', async () => {
  assert.equal(process.version, 'v24.22.1', 'Node 版本已变化：先重新验证 FileHandle.close 契约，不能直接更新锁定版本');
  const session = await loadInternals('@deepseek-ai/dsh-session-persistence-jsonl', ['tryLockOhos', 'ohosWriteLocks']);
  const directory = await mkdtemp(join(tmpdir(), 'ohos-close-contract-'));
  const handles = [];
  try {
    for (let i = 0; i < 3; i++) handles.push(await open(join(directory, 'lock'), 'a+'));
    const [first, owner, next] = handles;
    for (const handle of handles) {
      const descriptor = Object.getOwnPropertyDescriptor(handle, 'close');
      assert.equal(typeof descriptor?.value, 'function', 'close 必须是实例自带的方法');
      assert.equal(descriptor.writable, true, '该实例的 close 必须可由锁包装');
    }
    assert.notEqual(first.close, owner.close, '不同实例必须有各自的绑定');
    const detachedNativeClose = first.close;
    const nativeClosing = detachedNativeClose();
    assert(nativeClosing instanceof Promise, '原生 close 必须返回 Promise');
    await nativeClosing;
    assert.equal(first.fd, -1);
    assert(owner.fd >= 0, '提取 close 后调用不能关闭另一个实例');

    const originalClose = owner.close;
    await session.tryLockOhos(owner);
    await assert.rejects(session.tryLockOhos(next), { code: 'EAGAIN' });
    const detachedWrappedClose = owner.close;
    assert.notEqual(detachedWrappedClose, originalClose);
    const closing = detachedWrappedClose();
    assert(closing instanceof Promise);
    assert.equal(session.ohosWriteLocks.size, 1, '不能在 close Promise 的 finally 之前丢掉锁');
    await closing;
    assert.equal(owner.fd, -1);
    assert.equal(owner.close, originalClose, '关闭完成后恢复该实例原有的绑定');
    assert.equal(session.ohosWriteLocks.size, 0);
    await session.tryLockOhos(next);
    await next[Symbol.asyncDispose]();
    assert.equal(next.fd, -1);
    assert.equal(session.ohosWriteLocks.size, 0, 'FileHandle 的异步释放也必须经过实例 close');
  } finally {
    await Promise.allSettled(handles.map(handle => handle.close()));
    await rm(directory, { recursive: true, force: true });
  }
});
