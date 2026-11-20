// Runs an island's own scripts (the bundled libraries and its story helpers,
// as tavernIslandDocument puts them in; tavern_islands_test.dart writes them
// to the file DSH_ISLAND_SCRIPTS names) on a bare global, and checks what a
// front end finds.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const scripts = JSON.parse(readFileSync(process.env.DSH_ISLAND_SCRIPTS, 'utf8'));

function island() {
  const posted = [];
  const window = {
    console,
    TavernIsland: { postMessage: (m) => posted.push(JSON.parse(m)) },
    // Enough of DOMParser for toastr's plain text.
    DOMParser: class {
      parseFromString(s) {
        return { body: { textContent: s.replace(/<[^>]*>/g, ''), querySelectorAll: () => [] } };
      }
    },
  };
  window.window = window;
  vm.createContext(window);
  for (const code of scripts) vm.runInContext(code, window);
  return { window, posted, run: (code) => vm.runInContext(code, window) };
}

/** [v] made of this realm's objects: the page's have their own prototypes. */
function plain(v) {
  return JSON.parse(JSON.stringify(v));
}

test('zod and YAML are there, and waitGlobalInitialized gives them', async () => {
  const { window, run } = island();
  assert.equal(typeof run("z.object({a: z.string().prefault('x')}).prefault({}).parse(undefined).a"), 'string');
  assert.deepEqual(plain(run("YAML.parse('a: [1]')").a), [1]);
  assert.equal(await run("waitGlobalInitialized('z')"), window.z);
  assert.equal(await run("waitGlobalInitialized('YAML')"), window.YAML);
  assert.equal(await run("waitGlobalInitialized('Mvu')"), window.Mvu);
  // Anything else waits until it is shared.
  const later = run("waitGlobalInitialized('Later')");
  run("initializeGlobal('Later', 7)");
  assert.equal(await later, 7);
});

test('getAllVariables: global, character, chat, then this floor, each over the last', () => {
  const { run } = island();
  assert.deepEqual(plain(run('getAllVariables()')), {
    g: 1,
    c: 2,
    chat: 3,
    stat_data: { 世界: { 日期: '01月17日', 天气: '晴' } },
  });
});

test('getChatMessages: its own floor, the first, the latest, by number or range', () => {
  const { run } = island();
  assert.deepEqual(plain(run('getChatMessages(getCurrentMessageId())').map((m) => m.message)), ['她坐下。']);
  assert.deepEqual(plain(run("getChatMessages('0-{last}'.replace('{last}', getLastMessageId()))").map((m) => m.message_id)), [0, 2, 4]);
  assert.deepEqual(plain(run('getChatMessages(-1)').map((m) => m.message)), ['最新']);
  assert.deepEqual(plain(run("getChatMessages('0-4', {role: 'user'})").map((m) => m.message_id)), [4]);
  assert.equal(run('getChatMessages(3)').length, 0);
  assert.throws(() => run("getChatMessages('latest floor')"), /not a floor or a range/);
});

test("SillyTavern.getContext(): the chat as ST keeps it, the names, the character, the chat's variables", () => {
  const { run } = island();
  const ctx = run('SillyTavern.getContext()');
  assert.equal(ctx.chat.length, 5);
  assert.equal(ctx.chat[2].mes, '她坐下。');
  assert.equal(ctx.chat[4].is_user, true);
  assert.equal(ctx.chat[1], undefined);
  assert.equal(ctx.name1, '阿青');
  assert.equal(ctx.name2, '沈鹿笙');
  assert.equal(ctx.characterId, 'char-1');
  assert.deepEqual(plain(ctx.chatMetadata.variables), { chat: 3 });
  assert.equal(ctx.variables.local.get('chat'), 3);
  assert.throws(() => ctx.variables.local.set('chat', 4), /Read only in an island/);
});

test("MVU's update events fire when the app says the story moved, not when it did not", async () => {
  const { run } = island();
  run("window.seen=[];eventOn(Mvu.events.VARIABLE_UPDATE_ENDED,function(v,before){seen.push([v.n,before.n]);});");
  run('eventOn(tavern_events.MESSAGE_RECEIVED, function(){ throw new Error("never"); })');
  run('dshStoryUpdate(Object.assign({}, dshStory))');
  run("dshStoryUpdate(Object.assign({}, dshStory, {latest: {n: 2}}))");
  await new Promise((done) => setTimeout(done, 0));
  assert.deepEqual(plain(run('seen')), [[2, 1]]);
  // Read from now on.
  assert.deepEqual(plain(run("getVariables({type: 'message', message_id: 'latest'})")), { n: 2 });
});

test("toastr is the app's notice, its text only", () => {
  const { run, posted } = island();
  run("toastr.success('<b>存好了</b>', '变量')");
  run('toastr.clear()');
  assert.deepEqual(plain(posted), [
    { type: 'toast', level: 'success', title: '变量', message: '存好了', id: 1 },
    { type: 'toastClear', id: null },
  ]);
});
