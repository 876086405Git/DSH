import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { PassThrough, Writable } from 'node:stream';
import { CommandRouter } from '../../ohos/process/command-router.mjs';
import { createChildProcessFacade } from '../../ohos/process/plugin-process.mjs';
import OhSubprocessRuntime from '../../ohos/process/index.mjs';

const prefix = resolve(process.env.DSH_PREFIX ?? process.env.OHOS_TEST_DSH_PREFIX);
const dist = join(prefix, 'node_modules/@modelcontextprotocol/client/dist');
const { StdioClientTransport } = await import(pathToFileURL(join(dist, 'stdio.mjs')));
const { Client } = await import(pathToFileURL(join(dist, 'index.mjs')));
const CjsTransport = createRequire(import.meta.url)(join(dist, 'stdio.cjs')).StdioClientTransport;
const message = { jsonrpc: '2.0', id: 1, method: 'large', params: { text: 'x'.repeat(65536) } };

for (const [name, Transport] of [['esm', StdioClientTransport], ['cjs', CjsTransport]]) {
  test(`${name}: actual SDK send rejects when a real backpressured stream closes`, { timeout: 2000 }, async () => {
    const transport = new Transport({ command: 'unused' }), stdin = new PassThrough({ highWaterMark: 1 });
    transport._process = { stdin };
    const pending = transport.send(message), rejected = assert.rejects(pending);
    stdin.destroy(); await rejected;
    await assert.rejects(transport.send(message));
    assert.equal(stdin.listenerCount('drain'), 0);
  });

  test(`${name}: successful SDK send waits for actual stream acceptance`, { timeout: 2000 }, async () => {
    const transport = new Transport({ command: 'unused' }), stdin = new PassThrough({ highWaterMark: 1 });
    transport._process = { stdin };
    let settled = false; const pending = transport.send(message).then(() => { settled = true; });
    await new Promise(resolve => setImmediate(resolve)); assert.equal(settled, false);
    let bytes = 0; stdin.on('data', data => { bytes += data.length; }); await pending;
    assert.equal(bytes, Buffer.byteLength(JSON.stringify(message) + '\n'));
    stdin.destroy();
  });

  test(`${name}: SDK write callback failure preserves the real stream error`, async () => {
    const failure = Object.assign(new Error('owned input failure'), { code: 'EIO' });
    const stdin = new Writable({ write(_data, _encoding, callback) { callback(failure); } });
    // The actual transport installs this observer when it starts a process.
    stdin.on('error', () => {});
    const transport = new Transport({ command: 'unused' }); transport._process = { stdin };
    await assert.rejects(transport.send(message), error => error === failure);
  });
}

const server = `import {createInterface} from 'node:readline';
const rl=createInterface({input:process.stdin});
rl.on('line',line=>{const m=JSON.parse(line);if(m.id===undefined)return;
  const reply=value=>process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:m.id,...value})+'\\n');
  if(m.method==='server/discover'){reply({error:{code:-32601,message:'legacy fixture'}});return;}
  let result={};
  if(m.method==='initialize')result={protocolVersion:m.params.protocolVersion,capabilities:{tools:{}},serverInfo:{name:'owned-fixture',version:'1'}};
  if(m.method==='tools/list')result={tools:[{name:'echo',inputSchema:{type:'object',properties:{text:{type:'string'}}}}]};
  if(m.method==='tools/call')result={content:[{type:'text',text:m.params.arguments.text}]};
  reply({result});
});`;

test('actual SDK Clients negotiate through Worker probe siblings and two concurrent stdio sessions', { timeout: 15000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'ohos-mcp-client-'));
  const router = new CommandRouter({ workspaceRoots: [root] });
  const facade = createChildProcessFacade(spec => router.spawnPlugin(spec));
  const calls = [], clients = [];
  t.after(async () => { await Promise.allSettled(clients.map(client => client.close())); await router.dispose(); await rm(root, { recursive: true, force: true }); });
  await writeFile(join(root, 'server.mjs'), server);
  const connect = async () => {
    const transport = new StdioClientTransport({ command: 'node', args: ['server.mjs'], cwd: root, stderr: 'pipe',
      spawn: (...args) => { calls.push(args[2].stdio[2]); return facade.spawn(...args); } });
    transport.stderr.resume();
    const client = new Client({ name: 'ohos-regression', version: '1' }, { capabilities: {}, versionNegotiation: { mode: 'auto' } });
    clients.push(client); await client.connect(transport, { timeout: 3000 }); return client;
  };
  const [a, b] = await Promise.all([connect(), connect()]);
  for (const client of [a, b]) assert.equal((await client.listTools()).tools[0].name, 'echo');
  const invoke = (client, text) => client.callTool({ name: 'echo', arguments: { text } });
  const first = await Promise.all([invoke(a, '第一路'), invoke(b, 'second')]);
  assert.deepEqual(first.map(result => result.content[0].text), ['第一路', 'second']);
  await a.close(); assert.equal((await invoke(b, 'survivor')).content[0].text, 'survivor');
  await b.close(); await router.dispose();
  assert.equal(calls.filter(value => value === 'ignore').length, 2);
  assert.equal(calls.filter(value => value === 'pipe').length, 2);
  assert.equal(router.pluginNode.live.size, 0);
});

test('actual Cordis MCP plugin registers and invokes a stdio tool through the shared service', { timeout: 15000 }, async t => {
  const platform = Object.getOwnPropertyDescriptor(process, 'platform');
  Object.defineProperty(process, 'platform', { value: 'openharmony' });
  const load = name => import(pathToFileURL(join(prefix, 'node_modules/@deepseek-ai', name, 'lib/index.js')));
  const [{ Context }, { SystemPrompt }, { ToolRuntime }, mcp] = await Promise.all(['cordis', 'dsh-system-prompt', 'dsh-tools', 'dsh-mcp-client'].map(load));
  const root = await mkdtemp(join(tmpdir(), 'ohos-mcp-service-'));
  await writeFile(join(root, 'server.mjs'), server);
  const ctx = new Context();
  t.after(async () => { await ctx.fiber.dispose(); Object.defineProperty(process, 'platform', platform); await rm(root, { recursive: true, force: true }); });
  await ctx.plugin(SystemPrompt); await ctx.plugin(ToolRuntime);
  await ctx.plugin(OhSubprocessRuntime, { workspaceRoots: [root] });
  const config = { transport: 'stdio', serverName: 'owned', command: 'node', args: ['server.mjs'], cwd: root,
    env: {}, reconnect: { enabled: false }, failOnStartupError: true, toolCallTimeoutMs: 3000, maxInstructionBytes: 8192 };
  const plugin = await ctx.plugin(mcp, config);
  const tool = ctx.tools.get('mcp__owned__echo'); assert(tool, 'real tool registry must contain MCP definition');
  const result = await tool.execute({ text: '真实注册调用' }, { signal: new AbortController().signal });
  assert.equal(result.content[0].text, '真实注册调用');
  await plugin.dispose(); assert.equal(ctx.tools.get('mcp__owned__echo'), undefined);
  assert.equal(ctx.subprocess.backend.live.size, 0);
  await assert.rejects(mcp.apply({ subprocess: {} }, config), { code: 'ERR_OHOS_NO_SPAWN' });
});
