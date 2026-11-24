// Production preset's native filesystem, command and web tools, executing inside
// the pinned AgentLoop. Only model decisions and the web page are local fixtures.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
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
