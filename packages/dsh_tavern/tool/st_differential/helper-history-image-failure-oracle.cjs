const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const {stripTypeScriptTypes} = require('node:module');
const st = fs.readFileSync(process.argv[2], 'utf8');
const helper = fs.readFileSync(process.argv[3], 'utf8');
const hash = s => crypto.createHash('sha256').update(s).digest('hex');
assert.equal(hash(st), '0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604');
assert.equal(hash(helper), '9aace591938c207d8c3e81a5619ed39ccc6a1d53a1d3e84190243ca6c69ca3ff');
function extract(source, marker) {
  const start = source.indexOf(marker);
  assert.ok(start >= 0);
  const end = /^}\s*$/m.exec(source.slice(start));
  assert.ok(end);
  return source.slice(start, start + end.index + end[0].length);
}
const cls = extract(st, 'class Message {');
const convert = stripTypeScriptTypes(extract(helper, 'export async function convertFileToBase64(').replace(/^export /, ''), {mode: 'strip'});
(async () => {
  const rows = [];
  for (const stage of ['download', 'base64']) for (const path of ['raw-history-image', 'top-level-single-image']) {
    const calls = [], warnings = [];
    const ctx = {
      console: {log() {}, error: value => warnings.push(String(value))},
      isDataURL: value => value.startsWith('data:'),
      tokenHandler: {countAsync: async message => message.content.length},
      fetch: async () => {
        calls.push('download');
        if (stage === 'download') throw new Error('controlled download failure');
        return {ok: true, blob: async () => ({})};
      },
      getBase64Async: async () => { calls.push('base64'); throw new Error('controlled base64 failure'); },
    };
    vm.createContext(ctx);
    vm.runInContext(cls + '\n' + convert + '\nObject.assign(globalThis, {Message, convertFileToBase64});', ctx);
    const message = await ctx.Message.createAsync('user', 'H', 'fixture-history');
    if (path === 'raw-history-image') await message.addImage('https://fixture.invalid/history.png');
    else {
      const value = await ctx.convertFileToBase64('https://fixture.invalid/top.png');
      if (value) await message.addImage(value);
    }
    const content = JSON.parse(JSON.stringify(message.content));
    assert.deepEqual(content, path === 'raw-history-image' ? [{type: 'text', text: 'H'}] : 'H');
    assert.equal(message.tokens, 1);
    rows.push({path, stage, content, calls, warnings, textTokensUnchanged: true});
  }
  process.stdout.write(JSON.stringify({
    status: '4/4 actual source controls passed',
    stCommit: '7e8663cd9c184a550b37238218bdd32c6efc68e9',
    helperCommit: '29331c36fb9b2e880d4d488ff919317e1bc95684',
    messageClassSha256: hash(cls),
    scope: 'Actual fixed Message.createAsync/ensureContentIsArray/addImage plus actual Helper convertFileToBase64; fetch/base64 outcomes and text counter are explicit controls. No whole browser, image compression or token accuracy claim.',
    rows,
  }, null, 2) + '\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
