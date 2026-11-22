const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const quiet = {log() {}, info() {}, warn() {}, error() {}, debug() {}};
let nextRequest = 0;
function page() {
  const realm = vm.createContext({console: quiet});
  vm.runInContext(fs.readFileSync('assets/spreset_page_runtime.js', 'utf8'), realm);
  return realm.DshSPresetPageRuntime;
}
function binding(identifier) {
  return {identifier, uuid: identifier, code: `return {name:${JSON.stringify(identifier)},
    description:'fixture', parameters:{}, action:()=>null};`};
}
async function registry(runtime, mode, active, bindings) {
  const id = String(++nextRequest);
  const response = await runtime.evaluate({requestId:id, sessionScope:id, generationId:id,
    sessionId:`${id}:registry`, stage:'ToolBindings', kind:'toolRegistry', source:'',
    arguments:[{registryMode:mode, activeIdentifiers:active, ...(bindings ? {bindings} : {})}]});
  return JSON.parse(JSON.stringify(response.value));
}
const names = response => response.tools.map(tool => tool.definition.name);

(async () => {
  const observations = [];
  async function control(name, run) {
    try { observations.push({name, status:'pass', observation:await run()}); }
    catch (error) { observations.push({name, status:'fail', error:String(error), actual:error.actual, expected:error.expected}); }
  }
  await control('concurrent reads retain each request active set', async () => {
    const runtime = page();
    await registry(runtime, 'sync', ['a','b'], [binding('a'), binding('b')]);
    // Both calls enter before either shouldRegister await has completed.
    const [all, none] = await Promise.all([
      registry(runtime, 'read', ['a','b']), registry(runtime, 'read', []),
    ]);
    assert.deepEqual(names(all), ['a','b']);
    assert.deepEqual(names(none), []);
    return [names(all), names(none)];
  });
  await control('read refresh read preserves invocation ordering', async () => {
    const runtime = page();
    await registry(runtime, 'sync', ['a','b'], [binding('a'), binding('b')]);
    const [before, refreshed, after] = await Promise.all([
      registry(runtime, 'read', ['a','b']),
      registry(runtime, 'refresh', ['c'], [binding('c')]),
      registry(runtime, 'read', ['c']),
    ]);
    assert.deepEqual(names(before), ['a','b']);
    assert.deepEqual(names(refreshed), []);
    assert.deepEqual(names(after), ['c']);
    return [names(before), names(refreshed), names(after)];
  });
  await control('failed registry operation does not poison a later read', async () => {
    const runtime = page();
    await registry(runtime, 'sync', ['a'], [binding('a')]);
    const bad = registry(runtime, 'invalid', []);
    const next = registry(runtime, 'read', ['a']);
    await assert.rejects(bad, /Unsupported tool registry mode/);
    assert.deepEqual(names(await next), ['a']);
    return ['rejected', 'a'];
  });
  console.log(JSON.stringify({observations}, null, 2));
  if (observations.some(row => row.status !== 'pass')) process.exitCode = 1;
})().catch(error => {console.error(error); process.exitCode = 1;});
