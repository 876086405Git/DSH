import { parentPort, workerData } from 'node:worker_threads';
import { Bash, defineCommand } from './build/just-bash/index.js';
import { createFilesystem } from './filesystem.mjs';
import { shellCommands, unavailableMessage } from './commands.mjs';
import { executeRg } from './rg.mjs';
import { createOwnedGitClient } from './owned-client.mjs';
import { executeGit } from './git.mjs';
import { createFetch } from '../net/fetch.mjs';
import { createHttpDispatcher } from '../net/dispatcher.mjs';
import { nodeCommand } from './node-command.mjs';
import { nodeScriptAvailable } from './node-script.mjs';

const { argv, cwd, roots, stdin, env, policy } = workerData;
const ownedGitClient = createOwnedGitClient(parentPort);
const filesystem = createFilesystem(roots, policy);
const nodeAvailable = nodeScriptAvailable();
const bash = new Bash({
  fs: filesystem.fs,
  cwd,
  env,
  commands: shellCommands.filter(name => name !== 'node' || nodeAvailable),
  python: false,
  javascript: false,
  defenseInDepth: false,
  customCommands: [
    defineCommand('rg', executeRg),
    defineCommand('git', async (args, context) => {
      const dispatcher = createHttpDispatcher({ proxyEnv: Object.fromEntries(context.env) });
      try { return await executeGit(args, { ...context, ownedGit: ownedGitClient.api, fetch: createFetch(dispatcher) }); }
      finally { await dispatcher.destroy(); }
    }),
    ...(nodeAvailable ? [defineCommand('node', nodeCommand({ roots,
      workspaceRoots: [policy?.workspaceRoot ?? cwd], readOnly: policy?.mode === 'read-only' }))] : []),
  ],
  executionLimits: { maxExecutionTimeMs: Infinity, maxOutputSize: 64 * 1024 * 1024 },
});
filesystem.seal();

const write = (stream, content, encoding) => content.length === 0 ? Promise.resolve() : new Promise((resolve, reject) => {
  stream.write(content, encoding, error => error ? reject(error) : resolve());
});
const deliver = result => {
  const encoding = result.stdoutKind === 'bytes' || result.stdoutEncoding === 'binary' ? 'latin1' : 'utf8';
  return Promise.all([write(process.stdout, result.stdout, encoding),
    write(process.stderr, result.stderr, result.stderrKind === 'bytes' ? 'latin1' : 'utf8')]);
};

try {
  // argv 通过 args 原样传递；脚本仅在 bash/sh -c 的语法位置由解释器解析。
  // 私有构建只在该外层 shell 的语句完成后调用 deliver；内部管道、替换、
  // 重定向及复合语句仍先完成路由。await write 回调保留真实管道背压。
  const result = await bash.exec(argv[0], {
    args: argv.slice(1), cwd, env, replaceEnv: true, stdin, rawScript: true,
    ohosStatementOutput: argv[0] === 'bash' || argv[0] === 'sh' ? deliver : undefined,
  });
  if (result.exitCode === 127) result.stderr += result.stderrKind === 'bytes'
    ? Buffer.from(unavailableMessage + '\n').toString('latin1') : unavailableMessage + '\n';
  // 已交付语句已从私有累积器移除；此处只剩退出/错误等尚未交付的尾部。
  await deliver(result);
  parentPort.postMessage({ exitCode: result.exitCode });
} catch (error) {
  parentPort.postMessage({ failure: { name: error.name, message: error.message, code: error.code, stack: error.stack } });
} finally {
  ownedGitClient.close();
  parentPort.close();
}
