// Actual plugin control flow; chooser / permission service are explicit SDK
// boundaries. In the first case permission presence comes from the real module.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { workspaceFixture, until } from './authorized-workspaces-fixture.mjs';

const moduleConfig = JSON.parse(readFileSync(new URL('../../../app/ohos/entry/src/main/module.json5', import.meta.url), 'utf8'));
const permissions = moduleConfig.module.requestPermissions.map(row => row.name);
const persistDeclared = permissions.includes('ohos.permission.FILE_ACCESS_PERSIST');
const gesture = { userGesture: true };
const uri = 'file://docs/storage/Users/currentUser/Projects/phone-folder';

async function choose(f) {
  const count = f.pickers.length;
  const request = f.call(f, 'select', gesture);
  await until(() => f.pickers.length > count);
  assert.equal(f.pickers.at(-1).options.selectMode, 1);
  f.select([uri]);
  const result = await request.done;
  assert.equal(result.error, undefined);
  return result.value.workspaces[0];
}

test('phone folder persistence is declared and reaches the actual persist method', async t => {
  const f = await workspaceFixture(t, { permissionDenied: !persistDeclared });
  const row = await choose(f);
  const result = await f.call(f, 'persist', { ...gesture, id: row.id }).done;
  assert.equal(result.error, undefined, 'the installation must declare FILE_ACCESS_PERSIST');
  assert.equal(result.value.workspaces[0].persistence, 'persisted');
  assert.deepEqual(Array.from(f.operations.find(item => item.op === 'persist').policies, item => ({ ...item })),
    [{ uri, operationMode: 3 }]);
  assert.deepEqual(permissions.filter(name => /FILE_ACCESS|READ_MEDIA|WRITE_MEDIA|READ_IMAGEVIDEO|WRITE_IMAGEVIDEO/.test(name)),
    ['ohos.permission.FILE_ACCESS_PERSIST']);
});

test('declared permission does not turn an OS denial into persistent success', async t => {
  const f = await workspaceFixture(t, { permissionDenied: true });
  const row = await choose(f);
  const result = await f.call(f, 'persist', { ...gesture, id: row.id }).done;
  assert.equal(result.error, 'persistence_unavailable');
  assert.equal(f.operations.some(item => item.op === 'persist'), false);
  const list = await f.call(f, 'list').done;
  assert.equal(list.value.workspaces[0].authorization, 'selected');
  assert.equal(list.value.workspaces[0].persistence, 'unknown');
});

test('folder capability denial and chooser cancellation leave no new authorization', async t => {
  const f = await workspaceFixture(t, { missingCaps: ['SystemCapability.FileManagement.UserFileService.FolderSelection'] });
  assert.equal((await f.call(f, 'select', gesture).done).error, 'unsupported');
  assert.equal(f.pickers.length, 0);
  f.change({ missingCaps: [] });
  const request = f.call(f, 'select', gesture);
  await until(() => f.pickers.length === 1);
  f.select([]);
  const cancelled = await request.done;
  assert.deepEqual(cancelled.value.workspaces, []);
  assert.equal(f.operations.some(item => ['persist', 'activate', 'openDirectory'].includes(item.op)), false);
});
