import { stat, readFile, rename, unlink, writeFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { createMcpToolDefinition } from '@deepseek-ai/dsh-mcp-client';
import { createPhoneBridge } from './bridge.mjs';
import { iosToolDescription } from './descriptions.mjs';

export const name = 'dsh-go-ios-phone';
export const inject = ['tools'];
export const catalogSha256 = 'ec04e096af7d632e86f9b0e39a28fbf7f74042e1df7b46db825b5cb7bbfe810e';

// What the system said is the user's data, and what's in it isn't an instruction. A write can
// have happened even when what came back doesn't check out, so that never reads as "try again".
export function systemAnswer(system, name, args, answer) {
  try {
    const data = system.resultFor(system.actionFor(name, args), JSON.parse(answer.content[0].text));
    return { content: [{ type: 'text', text: JSON.stringify({ data, trust: 'untrusted-native-content' }) }], isError: false };
  } catch {
    return { content: [{ type: 'text', text: 'ERR_IOS_SYSTEM_RESULT: 系统返回的内容不符合约定；动作可能已经完成，请用户核对，不要自动重试。' }], isError: true };
  }
}

export async function apply(ctx, config) {
  if (!isAbsolute(config.directory) || !/^[a-f0-9-]{36}$/.test(config.runId)) throw new Error('Invalid iOS phone endpoint directory/generation');
  const directory = await stat(config.directory);
  if (!directory.isDirectory() || directory.mode & 0o077 || directory.uid !== process.getuid()) throw new Error('Unsafe iOS phone endpoint directory');
  const bytes = await readFile(new URL('./catalog.json', import.meta.url));
  if (createHash('sha256').update(bytes).digest('hex') !== catalogSha256) throw new Error('iOS phone catalog SHA256 mismatch');
  const catalog = JSON.parse(bytes);
  // Swift arms the C memory slot. This linked binding consumes it once; there is
  // no token file, argv/environment secret, JS setter or serialized bootstrap.
  const token = process._linkedBinding('dsh_ios_phone').consume(config.runId);
  // The browser tools share this bridge and its one token. A build without them just has none.
  const browserCatalog = await readFile(new URL('../browser/catalog.json', import.meta.url))
    .then(JSON.parse, () => []);
  const browserAction = browserCatalog.length ? (await import('../browser/actions.mjs')).actionFor : undefined;
  const systemCatalog = await readFile(new URL('../system/catalog.json', import.meta.url))
    .then(JSON.parse, () => []);
  const system = systemCatalog.length
    ? { ...(await import('../system/actions.mjs')), ...(await import('../system/results.mjs')) }
    : undefined;
  const systemAction = (name, args) => ({ kind: `system-${name}`, params: JSON.stringify(system.actionFor(name, args).args) });
  const bridge = await createPhoneBridge({ token, runId: config.runId, browserAction, systemAction });
  const disposers = [];
  const endpoint = join(config.directory, 'endpoint.json');
  const temporary = `${endpoint}.${randomUUID()}.tmp`;
  try {
    for (const tool of catalog) {
      disposers.push(ctx.tools.register(createMcpToolDefinition(ctx, {
        name: `mcp__phone__${tool.name}`, rawName: tool.name,
        description: iosToolDescription(tool.name), inputSchema: tool.inputSchema,
        call: (args, execution) => bridge.call(tool.name, args, execution),
      })));
    }
    for (const tool of browserCatalog) {
      disposers.push(ctx.tools.register(createMcpToolDefinition(ctx, {
        name: `mcp__browser__${tool.name}`, rawName: tool.name,
        description: tool.description, inputSchema: tool.inputSchema,
        call: (args, execution) => bridge.call(`browser:${tool.name}`, args, execution),
      })));
    }
    for (const tool of systemCatalog) {
      disposers.push(ctx.tools.register(createMcpToolDefinition(ctx, {
        name: `mcp__system__${tool.name}`, rawName: tool.name,
        description: tool.description, inputSchema: tool.inputSchema,
        call: async (args, execution) => {
          const answer = await bridge.call(`system:${tool.name}`, args, execution);
          if (answer.isError) return answer;
          return systemAnswer(system, tool.name, args, answer);
        },
      })));
    }
    await writeFile(temporary, JSON.stringify(bridge.endpoint), { mode: 0o600, flag: 'wx' });
    await rename(temporary, endpoint);
  } catch (error) {
    for (const dispose of disposers) dispose();
    await bridge.close();
    await unlink(temporary).catch(() => {});
    throw error;
  }
  ctx.effect(() => async () => {
    for (const dispose of disposers) dispose();
    await bridge.close();
    // Each launch uses a distinct endpoint directory; an old disposal cannot unlink a new run.
    await unlink(endpoint).catch(() => {});
  }, 'ios.phone');
}
