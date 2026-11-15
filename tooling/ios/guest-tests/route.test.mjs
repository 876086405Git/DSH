import test from 'node:test';
import assert from 'node:assert/strict';
import { Bash, defineCommand, parse } from '../../../runtime/ohos/process/build/just-bash/index.js';
import { shellCommands } from '../../../runtime/ohos/process/commands.mjs';
import { planScript, routingTransform } from '../../../runtime/ios/guest/route.mjs';
import { guestDescription } from '../../../runtime/ios/guest/metadata.mjs';

const options = { shellCommands, parse };
const plan = source => planScript(parse(source), options);

for (const source of [
  'cat /etc/os-release', 'ls /', 'command -v apk', 'command -V apk',
  'cat input | grep virtual', 'apk --version | sed -n "1p"',
  'apk add --no-cache jq && jq --version', 'cat input > output',
  'git status', 'rg pattern .', 'awk \'{print $1}\' input',
  'tool=apk; "$tool" --version', '"$TOOL" --version',
  'source setup.sh; apk --version', 'eval "$SCRIPT"',
  'sh script.sh', 'sh -c \'command -v apk\'',
]) {
  test(`ordinary scripts select one Linux backend: ${source}`, () => {
    assert.equal(plan(source).route, 'guest');
  });
}

for (const source of [
  'node script.mjs', 'node script.mjs | cat', 'cat input | node script.cjs > output',
  'node script.mjs > output; cat output', 'command node script.mjs',
  'sh -c \'node script.mjs\'',
]) {
  test(`statically identified Node Worker script stays virtual: ${source}`, () => {
    assert.equal(plan(source).route, 'virtual');
  });
}

for (const source of [
  'echo before > marker; node script.mjs; apk --version',
  'node script.mjs; "$TOOL" --version',
  'node script.mjs | sed -n "1p"', 'node script.mjs; source setup.sh',
  'node script.mjs; eval "$SCRIPT"', 'node script.mjs; sh script.sh',
  'node script.mjs; git status',
]) {
  test(`Node mixed or opaque scripts reject before execution: ${source}`, () => {
    assert.equal(plan(source).route, 'unsupported');
  });
}

async function run(argv, { guest = true, stdin = '' } = {}) {
  let nodeCalls = 0;
  const bash = new Bash({
    cwd: '/workspace', files: { '/workspace/input': 'virtual\n', '/workspace/script.sh': 'echo file-ran > marker\n' },
    commands: shellCommands, defenseInDepth: false, python: false, javascript: false,
    customCommands: [defineCommand('node', async () => {
      nodeCalls++;
      return { exitCode: 0, stdout: 'worker\n', stderr: '' };
    })],
  });
  const routing = guest && routingTransform(argv, options);
  if (routing) bash.registerTransformPlugin(routing.plugin);
  const result = await bash.exec(argv[0], { args: argv.slice(1), rawScript: true, stdin });
  return { result, decision: routing?.decision, nodeCalls, fs: bash.fs };
}

test('real Bash transform suppresses guest expansions, redirections and all statements', async () => {
  for (const source of [
    'echo before > marker; cat /etc/os-release',
    'echo "$(echo substituted > marker)"; command -v apk',
    'cat input | grep virtual > marker',
  ]) {
    const { result, decision, fs } = await run(['bash', '-c', source]);
    assert.equal(decision.route, 'guest');
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, '');
    assert.equal(await fs.exists('/workspace/marker'), false);
  }
});

test('real Bash transform rejects a mixed script without running its prefix or Worker', async () => {
  const { decision, nodeCalls, fs } = await run(['bash', '-c', 'echo before > marker; node script.mjs; apk --version']);
  assert.equal(decision.route, 'unsupported');
  assert.equal(nodeCalls, 0);
  assert.equal(await fs.exists('/workspace/marker'), false);
});

test('real Bash transform retains the complete virtual Node pipeline', async () => {
  const { result, decision, nodeCalls } = await run(['bash', '-c', 'node script.mjs | cat']);
  assert.equal(decision.route, 'virtual');
  assert.equal(nodeCalls, 1);
  assert.equal(result.stdout, 'worker\n');
});

test('file, stdin and alternate shell flags transfer before virtual file reads or effects', async () => {
  for (const argv of [['sh', 'script.sh'], ['bash', '-s'], ['sh'], ['bash', '--', 'script.sh'], ['sh', '-ec', 'echo flags > marker']]) {
    const { result, decision, fs } = await run(argv, { stdin: 'echo stdin-ran > marker\n' });
    assert.equal(decision.route, 'guest', JSON.stringify(argv));
    assert.equal(result.stdout, '');
    assert.equal(result.stderr, '');
    assert.equal(await fs.exists('/workspace/marker'), false);
  }
});

test('without installed guest routing, the existing virtual pipeline still runs', async () => {
  const { result, decision } = await run(['bash', '-c', 'cat input | grep virtual'], { guest: false });
  assert.equal(decision, undefined);
  assert.equal(result.exitCode, 0);
  assert.equal(result.stdout, 'virtual\n');
});

test('non-shell subprocesses are not redirected by the shell transform', async () => {
  const { result, decision } = await run(['cat', 'input']);
  assert.equal(decision, undefined);
  assert.equal(result.stdout, 'virtual\n');
});

test('ready metadata explains the real backend, ash semantics and no-fallback rule', () => {
  const description = guestDescription({ source: 'ios-native-owner', available: true, enforcement: 'partial' });
  assert.match(description, /默认整段在 Linux \/bin\/sh/);
  assert.match(description, /Alpine ash/);
  assert.match(description, /失败不会回退/);
  assert.match(description, /Node Worker/);
  assert.match(description, /完全权限也不会扩大/);
});
