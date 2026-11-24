// Production preset's native filesystem, command and web tools, executing inside
// the pinned AgentLoop. Only model decisions and the web page are local fixtures.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { randomUUID } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { Readable } from 'node:stream';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createCompanionRoutes } from '../bridge/dsh-go-bridge/lib/companion/routes.js';
import test from 'node:test';
import { createFixture, requestSystemText, sseResponse, textResponse } from './fixtures/companion-recall-engine.mjs';

function toolResponse(id, name, args) {
  return sseResponse([
    { type: 'message_start', message: { usage: { input_tokens: 8, output_tokens: 0 } } },
    { type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id, name, input: {} } },
    { type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: JSON.stringify(args) } },
    { type: 'content_block_stop', index: 0 },
    { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 8 } },
    { type: 'message_stop' },
  ]);
}

async function mountHostTools(f) {
  f.ctx.provide('workingDirectory', { ensure: async () => f.home });
  for (const name of ['dsh-subprocess-local', 'dsh-bash-local', 'dsh-shell-env']) {
    const module = await f.engine.load(name);
    await f.ctx.plugin(module.default ?? module, { cwd: f.home, timeoutMs: 5000 }).await();
  }
  await f.ctx.plugin((await f.engine.load('dsh-fs-local')).LocalFileSystem, { cwd: f.home }).await();
  await f.ctx.plugin((await f.engine.load('dsh-web')).WebRuntime, {}).await();
  await f.ctx.plugin(await f.engine.load('dsh-web-fetch-http'), {}).await();

  // Use the shipped rows/config. This fixture exercises these three tools, not every plugin in the profile.
  const yaml = createRequire(join(f.engine.prefix, 'package.json'))('js-yaml');
  const schema = yaml.DEFAULT_SCHEMA.extend([new yaml.Type('tag:yaml.org,2002:js', { kind: 'scalar' })]);
  const source = await readFile(new URL('../bridge/dsh-go-bridge/cordis.patch.yml', import.meta.url), 'utf8');
  const preset = yaml.load(source, { schema })[0].insert.find(row => row.config?.id === 'dsh-go-companion-full');
  const rows = ['tool-fs', 'tool-bash', 'tool-web'].map(id => {
    const row = preset.config.plugins.find(plugin => plugin.id === id);
    assert(row, 'Missing companion preset plugin: ' + id);
    if (row.disabled !== undefined) {
      assert.equal(row.disabled, "process.platform === 'win32'"); // Linux/Unix test, see skip below.
    }
    return { id, config: row.config, name: pathToFileURL(join(f.engine.base,
      row.name.slice('@deepseek-ai/'.length), 'lib/index.js')).href };
  });
  await f.replaceFull([...f.fullPlugins(), ...rows]);
}

test('companion reads a file, writes and runs code, then fetches a fixture web page in one real engine turn', {
  skip: !process.env.DSH_PREFIX ? 'DSH_PREFIX must name the patched runtime' : process.platform === 'win32' && 'Unix shell fixture',
  timeout: 20000, concurrency: false,
}, async t => {
  let pageReads = 0;
  const server = createServer((_req, res) => {
    pageReads++;
    res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' }); res.end('PAGE_FIXTURE_OK');
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const url = new URL('/notice', 'http://127.0.0.1:' + server.address().port);
  const realFetch = globalThis.fetch, seen = [];
  let source, script;
  const f = await createFixture({ withRecall: false, transport: (request, n) => {
    const results = request.body.messages.flatMap(message => message.content).filter(block => block.type === 'tool_result');
    seen.push(results.at(-1));
    switch (n) {
      case 1: return toolResponse('read-input', 'read', { file_path: source });
      case 2: {
        const match = /INPUT=(\d+)/.exec(JSON.stringify(results.at(-1)?.content));
        if (!match) return textResponse('missing input');
        return toolResponse('write-script', 'write', { file_path: script, content: 'console.log("RESULT=" + 2 * ' + match[1] + ')\n' });
      }
      case 3: return toolResponse('run-script', 'bash', { command: 'node double.mjs', description: '运行刚写的测试脚本' });
      case 4: return toolResponse('fetch-page', 'web_fetch', { url: url.href });
      default: return textResponse('完成测试。');
    }
  } });
  t.after(() => f.dispose());
  // Preserve the fixture's fake model and allow only this test's local page.
  const modelFetch = globalThis.fetch;
  globalThis.fetch = (input, init) => {
    const address = new URL(input instanceof Request ? input.url : input);
    return (address.origin === url.origin ? realFetch : modelFetch)(input, init);
  };
  await mountHostTools(f);
  source = join(f.home, 'input.txt'); script = join(f.home, 'double.mjs');
  await writeFile(source, 'INPUT=27\n');
  const { agent } = await f.createAgent('FULL_HOST_TOOLS');
  await f.send(agent, '读输入，写脚本算两倍运行，再查看页面。');
  assert.equal(f.requests.length, 5);
  assert(f.requests.every(request => request.sessionId === agent.id));
  const names = f.requests[0].body.tools.map(tool => tool.name);
  for (const tool of ['read', 'write', 'bash', 'web_fetch']) assert(names.includes(tool), tool);
  assert(!names.includes('workspace'));
  assert(requestSystemText(f.requests[0]).includes('查看输出后继续处理'));
  assert.deepEqual(seen.slice(1).map(block => block.tool_use_id), ['read-input', 'write-script', 'run-script', 'fetch-page']);
  assert(seen.slice(1).every(block => block.is_error !== true));
  assert.match(await readFile(script, 'utf8'), /2 \* 27/);
  assert.match(JSON.stringify(seen[3].content), /RESULT=54/);
  assert.match(JSON.stringify(seen[4].content), /PAGE_FIXTURE_OK/);
  assert.equal(pageReads, 1);
});

// These turns use the production registration, HTTP bridge and Inbox claim.
// The phone answers from fixtures, without an Android device or real photos.
async function offerPhone(f, agent, requestId, definitions, httpFetch, signal) {
  f.ctx.provide('connection', { admit: req => req.headers.authorization === 'fixture-owner'
    ? { peer: { principal: { kind: 'owner' } } } : { rejection: 403 } });
  const routes = createCompanionRoutes({ ctx: f.ctx, store: f.store, send(res, status, body) {
    res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(body));
  } });
  const server = createServer((req, res) => routes.handle(req, res, req.url));
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  const post = (part, extra) => httpFetch(
    'http://127.0.0.1:' + server.address().port + '/dsh-go/v1/companion/session-tools/' + part,
    { method: 'POST', headers: { authorization: 'fixture-owner', 'content-type': 'application/json' },
      body: JSON.stringify({ sessionId: agent.id, requestId, ...extra }), signal });
  async function close() {
    await routes.dispose();
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
  try {
    const response = await post('open', { tools: definitions });
    assert.equal(response.status, 200);
    const lines = createInterface({ input: Readable.fromWeb(response.body) })[Symbol.asyncIterator]();
    const ready = JSON.parse((await lines.next()).value);
    assert.equal(ready.type, 'ready');
    return { close, async serve(handle) {
      for await (const line of lines) {
        const call = JSON.parse(line);
        assert.equal(call.type, 'call');
        const receipt = handle(call);
        assert.equal((await post('result', {
          token: ready.token, callId: call.callId, content: JSON.stringify(receipt), isError: false,
        })).status, 200);
      }
    } };
  } catch (error) { await close(); throw error; }
}

function lastTool(request, id) {
  const result = request.body.messages.flatMap(message => message.content).filter(b => b.type === 'tool_result').at(-1);
  assert.equal(result?.tool_use_id, id);
  assert.notEqual(result.is_error, true);
  return typeof result.content === 'string' ? result.content : result.content.map(block => block.text).join('');
}

function offered(name, properties) {
  return { name, description: 'Synthetic phone ' + name,
    input_schema: { type: 'object', properties, required: Object.keys(properties), additionalProperties: false } };
}

const engineOnly = { skip: !process.env.DSH_PREFIX && 'DSH_PREFIX must name the patched runtime',
  timeout: 20000, concurrency: false };

for (const kind of ['reminder', 'photo']) {
  test('full companion returns a phone ' + kind + ' result to its model and Session', engineOnly, async t => {
    const phoneFetch = globalThis.fetch;
    const marker = randomUUID(), requestId = 'owner-' + kind, calls = [];
    const reminder = kind === 'reminder';
    const text = reminder ? '2030 年 5 月 16 日上海时间上午九点提醒我带伞。' : '看一下我最近的一张照片。';
    const time = { operation: 'create', text: '带伞', localDate: '2030-05-16', localTime: '09:00', zoneId: 'Asia/Shanghai' };
    const f = await createFixture({ withRecall: false, transport(request, n) {
      if (reminder) {
        if (n === 1) return toolResponse('set', 'companion_reminder', time);
        return textResponse('提醒已登记，编号 ' + JSON.parse(lastTool(request, 'set')).task.task_id);
      }
      if (n === 1) return toolResponse('list', 'companion_photos_recent', { limit: 1 });
      if (n === 2) {
        const photo = JSON.parse(lastTool(request, 'list')).photos[0];
        return toolResponse('look', 'companion_photo_view', { id: photo.id });
      }
      return textResponse(JSON.parse(lastTool(request, 'look')).description);
    } });
    try {
      const { agent } = await f.createAgent('FULL_DEVICE_' + kind);
      const defs = reminder ? [offered('reminder', Object.fromEntries(Object.keys(time).map(k => [k, { type: 'string' }])))]
        : [offered('photos_recent', { limit: { type: 'integer' } }), offered('photo_view', { id: { type: 'string' } })];
      const phone = await offerPhone(f, agent, requestId, defs, phoneFetch, t.signal);
      try {
        const serve = phone.serve(call => {
          calls.push([call.callId, call.name, call.input]);
          if (call.name === 'reminder') return { accepted: true, task: { kind: 'phone.reminder', task_id: marker } };
          if (call.name === 'photos_recent') return { photos: [{ id: marker, name: 'mock.jpg' }] };
          assert.equal(call.name, 'photo_view');
          assert.equal(call.input.id, marker);
          return { id: marker, description: '合成照片里的白帆 ' + marker };
        });
        agent.followup(f.engine.llm.createUserMessage({ source: { kind: 'user', rpcId: requestId }, content: [{ type: 'text', text }] }));
        await Promise.all([agent.whenIdle(), serve]);
        assert.deepEqual(calls, reminder ? [['set', 'reminder', time]]
          : [['list', 'photos_recent', { limit: 1 }], ['look', 'photo_view', { id: marker }]]);
        assert.equal(f.requests.length, reminder ? 2 : 3);
        assert(f.requests.every(r => r.sessionId === agent.id));
        const events = agent.session.snapshotEvents();
        assert.deepEqual(events.filter(e => e.type === 'user/message' && e.data.source?.kind === 'user')
          .map(e => [e.data.source.rpcId, e.data.content[0].text]), [[requestId, text]]);
        assert.deepEqual(events.filter(e => e.type === 'assistant/message').at(-1).data.message.content,
          [{ type: 'text', text: (reminder ? '提醒已登记，编号 ' : '合成照片里的白帆 ') + marker }]);
      } finally { await phone.close(); }
    } finally { await f.dispose(); }
  });
}

test('full companion taps the opted-in synthetic MCP button in the same agent turn', engineOnly, async () => {
  const f = await createFixture({ withRecall: false, transport(request, n) {
    return n === 1 ? toolResponse('press', 'mcp__phone__tap', { screen: 'fixture', id: 1 })
      : textResponse(lastTool(request, 'press'));
  } });
  try {
    await f.ctx.plugin((await f.engine.load('dsh-mcp-resources')).default).await();
    await f.ctx.plugin(await f.engine.load('dsh-mcp-client'), {
      serverName: 'phone', transport: 'stdio', command: process.execPath,
      args: [fileURLToPath(new URL('./fixtures/phone-caller-mcp.mjs', import.meta.url)), 'supported', '--button'],
      dshGoPhoneCaller: true, failOnStartupError: true, reconnect: { enabled: false },
    }).await();
    const { agent } = await f.createAgent('FULL_MCP_BUTTON');
    await f.send(agent, '按一下测试按钮');
    assert.equal(f.requests.length, 2);
    assert(f.requests[0].body.tools.some(tool => tool.name === 'mcp__phone__tap'));
    const receipt = lastTool(f.requests[1], 'press');
    assert.match(receipt, /fixture-button-pressed-once/);
    assert.match(receipt, /FULL_MCP_BUTTON/);
    const reply = agent.session.snapshotEvents().filter(e => e.type === 'assistant/message').at(-1);
    assert.deepEqual(reply.data.message.content, [{ type: 'text', text: receipt }]);
  } finally { await f.dispose(); }
});
