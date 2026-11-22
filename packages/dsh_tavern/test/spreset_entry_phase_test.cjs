const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
// Shipped adapter in independent page realms, as in the owner's chat routing.
const quiet = {log() {}, info() {}, warn() {}, error() {}, debug() {}};
let sequence = 0;
function page() {
  const realm = vm.createContext({console: quiet, Date: {now: () => 0}});
  vm.runInContext(fs.readFileSync('assets/spreset_page_runtime.js', 'utf8'), realm);
  return {realm, runtime: realm.DshSPresetPageRuntime};
}
function binding(marker, uuid = marker) {
  const code = 'globalThis.evaluated = (globalThis.evaluated || 0) + 1;' +
    'return {name:"fixture_tool", description:' + JSON.stringify(marker) +
    ', parameters:{}, action:function(){ return ' + JSON.stringify(marker) + '; }};';
  return {identifier: 'slot', uuid, code};
}
function request(kind, scope, args, extra = {}) {
  return {requestId: String(++sequence), chatId: 'chat', generationId: 'public-id',
    sessionScope: scope, sessionId: scope + ':tool-registry', stage: 'ToolBindings',
    source: '', kind, arguments: args, ...extra};
}
async function registry(p, scope, mode, bindings, activeIdentifiers = ['slot']) {
  const input = {activeIdentifiers, ...(bindings === undefined ? {} : {bindings}),
    ...(mode === undefined ? {} : {registryMode: mode})};
  const result = await p.runtime.evaluate(request('toolRegistry', scope, [input]));
  return JSON.parse(JSON.stringify(result.value));
}
async function action(p, scope) {
  return (await p.runtime.evaluate(request('toolAction', scope, [{}],
    {sessionId: scope + ':tool:fixture_tool'}))).value;
}
(async () => {
  const rows = [];
  {
    const p = page();
    const early = await registry(p, 'outer', undefined, [], []);
    assert.deepEqual(early.registryModes, ['sync', 'read', 'refresh']);
    assert.equal(early.registryMode, 'sync');
    // STOP restores defaults, but read cannot invent an excluded registration.
    const selected = await registry(p, 'outer', 'read', undefined);
    assert.equal(selected.registryMode, 'read');
    assert.deepEqual(selected.tools, []);
    const refreshed = await registry(p, 'outer', 'refresh', [binding('next')]);
    assert.equal(refreshed.registryMode, 'refresh');
    assert.deepEqual(refreshed.tools, []);
    await assert.rejects(() => action(p, 'outer'), /retained SPreset tool definition is unavailable/);
    const next = await registry(p, 'next', 'read', undefined);
    assert.equal(next.tools.length, 1);
    assert.equal(await action(p, 'next'), 'next');
    rows.push('early false -> STOP -> current wire empty -> refresh -> next wire registered');
  }
  {
    const p = page();
    await registry(p, 'outer', undefined, [], []);
    await registry(p, 'nested', 'refresh', [binding('nested-ready')]);
    const outer = await registry(p, 'outer', 'read', undefined);
    assert.equal(outer.tools[0].definition.description, 'nested-ready');
    assert.equal(await action(p, 'outer'), 'nested-ready');
    assert.equal(p.realm.evaluated, 1);
    rows.push('nested READY changes shared registry before outer wire read');
  }
  {
    const p = page();
    await registry(p, 'outer', undefined, [binding('selected')]);
    const selected = await registry(p, 'outer', 'read', undefined);
    const frozen = JSON.stringify(selected.tools);
    // A different UUID replaces the registration without rebinding this run.
    await registry(p, 'outer', 'refresh', [binding('future')]);
    assert.equal(JSON.stringify(selected.tools), frozen);
    assert.equal(await action(p, 'outer'), 'selected');
    await registry(p, 'next', 'read', undefined);
    assert.equal(await action(p, 'next'), 'future');
    assert.equal(p.realm.evaluated, 2);
    rows.push('refresh updates future registration while current action stays selected');
  }
  {
    const p = page();
    await registry(p, 'outer', undefined, [binding('kept')]);
    const invalid = [{identifier: 'slot', uuid: 'bad', code: 'throw new Error("must not run")'}];
    const read = await registry(p, 'reader', 'read', invalid);
    assert.equal(read.tools[0].definition.description, 'kept');
    assert.equal(p.realm.evaluated, 1);
    assert.deepEqual((await registry(p, 'hidden', 'read', undefined, [])).tools, []);
    assert.equal((await registry(p, 'visible', 'read', undefined)).tools.length, 1);
    assert.equal(p.realm.evaluated, 1);
    rows.push('read applies current shouldRegister without evaluating definitions');
  }
  {
    const p = page();
    await registry(p, 'outer', undefined, [binding('kept')]);
    await assert.rejects(() => registry(p, 'bad', 'unsupported', [], []), /Unsupported tool registry mode/);
    assert.equal((await registry(p, 'next', 'read', undefined)).tools.length, 1);
    assert.equal(await action(p, 'outer'), 'kept');
    p.runtime.releaseSession('outer:tool:fixture_tool');
    await assert.rejects(() => action(p, 'outer'), /retained SPreset tool definition is unavailable/);
    assert.equal(await action(p, 'next'), 'kept');
    rows.push('unknown mode rejects before mutation; release remains run-scoped');
  }
  {
    const a = page(), b = page();
    await registry(a, 'a', undefined, [binding('a')]);
    assert.deepEqual((await registry(b, 'b', 'read', undefined)).tools, []);
    assert.equal((await registry(a, 'a-next', 'read', undefined)).tools.length, 1);
    rows.push('distinct page realms do not share registration');
  }
  console.log(JSON.stringify({status:'6/6 page adapter phase controls passed', rows}, null, 2));
})().catch(error => {console.error(error); process.exitCode = 1;});
