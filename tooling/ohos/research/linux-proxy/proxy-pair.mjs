import { spawn } from 'node:child_process';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { createProxyFixtures } from './proxy-fixture.mjs';

const [output, node, nativeDirectory, assets, archive, publication, baseline, retainedDirectory] = process.argv.slice(2);
const privateDirectory = retainedDirectory || join(output, 'private-linux');
const home = join(output, 'child-home'), tmp = join(output, 'child-tmp');
const environment = {
  PATH: node.slice(0, node.lastIndexOf('/')) + ':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
  HOME: home, TMPDIR: tmp, LANG: 'C.UTF-8', LD_PRELOAD: publication,
  DSH_GO_OHOS_SIM_PLATFORM: 'openharmony', DSH_GO_OHOS_SIM_ADDONS: JSON.stringify([join(nativeDirectory, 'libdsh_linux.so')]),
};
const commands = [], checks = [], results = [];
const expect = (pass, name) => { if (!pass) throw Object.assign(new Error(name), { code: 'ERR_PROXY_PAIR_ASSERTION' }); checks.push(name); };
const fixture = await createProxyFixtures({ directory: join(output, 'private-fixture') });
const originalArgv = ['python3', '-c', `import sys,urllib.request\ntry:\n data=urllib.request.urlopen('http://proxy-target.invalid:${fixture.settings.httpOriginPort}/nonce',timeout=4).read(128)\n if data!=b'DSH_PROXY_RESEARCH_NONCE_V1\\n':sys.exit(78)\n print('PROXY_HTTP_OK')\nexcept Exception:\n print('PROXY_HTTP_FAILURE');sys.exit(77)\n`];
// Only this pipe payload contains proxy addresses or authentication values.
const pipeInput = JSON.stringify({ ...fixture.settings, originalArgv, classifyOriginalGh: !!retainedDirectory });
const digest = value => createHash('sha256').update(value).digest('hex');
const writeJSON = (name, value) => writeFile(join(output, name), JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
await writeJSON('CHILD-ENVIRONMENT.json', { values: environment,
  sha256: digest(JSON.stringify(Object.fromEntries(Object.entries(environment).sort(([a], [b]) => a.localeCompare(b))))),
  inProcessMutation: 'Fixed test proxy aliases are supplied by an anonymous pipe and assigned in the research child; actual endpoint and credentials are deliberately not recorded.' });

async function run(phase) {
  const target = join(output, phase); await mkdir(target);
  const argv = ['--jitless', '--import', join(output, 'source/runtime/ohos/sim/preload.mjs'),
    join(output, 'guest-proxy.mjs'), nativeDirectory, assets, archive, privateDirectory, target, phase];
  const startNs = process.hrtime.bigint().toString();
  const child = spawn(node, argv, { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  // Native/library startup errors are not blindly persisted: an error may
  // contain a URL. Count output, retain only the child's closed-schema RESULT.
  let stdoutBytes = 0, stderrBytes = 0, timedOut = false, overBudget = false;
  child.stdout.on('data', bytes => { stdoutBytes += bytes.length; if (stdoutBytes + stderrBytes > 8 * 1024 * 1024) { overBudget = true; child.kill('SIGTERM'); } });
  child.stderr.on('data', bytes => { stderrBytes += bytes.length; if (stdoutBytes + stderrBytes > 8 * 1024 * 1024) { overBudget = true; child.kill('SIGTERM'); } });
  child.stdin.on('error', () => {}); child.stdin.end(pipeInput);
  const timer = setTimeout(() => { timedOut = true; child.kill('SIGTERM'); }, 420000);
  const ended = await new Promise(resolve => { child.once('error', () => resolve({ code: null, signal: null, spawnError: true })); child.once('close', (code, signal) => resolve({ code, signal, spawnError: false })); });
  clearTimeout(timer);
  const record = { phase, executable: node, argv, startNs, endNs: process.hrtime.bigint().toString(),
    exitCode: ended.code, signal: ended.signal, spawnError: ended.spawnError, timedOut, overBudget,
    stdoutBytesDiscarded: stdoutBytes, stderrBytesDiscarded: stderrBytes,
    outputPolicy: 'Content discarded at receipt; no credentials or arbitrary tool errors persisted.' };
  commands.push(record); await writeJSON('COMMANDS.json', commands);
  let result;
  try { result = JSON.parse(await readFile(join(target, 'RESULT.json'), 'utf8')); }
  catch { throw Object.assign(new Error('child has no confirmed result; retained disks are untouched'), { code: 'ERR_PROXY_PAIR_NO_RESULT' }); }
  results.push(result);
  expect(ended.code === 0 && result.passed && !timedOut && !overBudget, 'research child completes: ' + phase);
  return result;
}

let result;
try {
  let red;
  if (baseline === 'yes') red = await run('baseline');
  const green = await run(red || retainedDirectory ? 'resume' : 'install');
  const events = fixture.events();
  const observed = item => events.filter(event => BigInt(event.atNs) >= BigInt(item.startNs) && BigInt(event.atNs) <= BigInt(item.endNs));
  if (red) {
    const first = red.cases.find(item => item.name === 'inherited-http-original');
    const second = green.cases.find(item => item.name === 'inherited-http-original');
    expect(first.job.outcome.exitCode === 77 && observed(first).length === 0, 'old inherited guest loopback reaches neither actual host proxy nor origin');
    expect(first.originalProbeSha256 === second.originalProbeSha256, 'red and green issue the same original request including argv cwd env stdin and requestId');
    expect(red.pid !== green.pid && BigInt(commands[1].startNs) > BigInt(commands[0].endNs), 'old Node exits before the new lifetime starts');
    expect(red.active.persistentInstanceId === green.active.persistentInstanceId && JSON.stringify(red.target) === JSON.stringify(green.target), 'same retained target identity across source comparison');
    expect(red.active.epoch !== green.active.epoch && red.downloads === 1 && green.downloads === 0, 'fresh directboot epoch with no download or replacement');
  }
  const network = [];
  for (const item of green.cases) {
    const measured = observed(item), proxy = measured.filter(row => row.boundary === 'proxy'), origin = measured.filter(row => row.boundary === 'origin');
    if (item.name === 'install-public-test-ca') { expect(measured.length === 0, 'test CA installation performs no network'); continue; }
    if (item.name === 'gh-original-hostname-classifier') {
      expect(measured.length === 0 && item.classification?.invalidHostname === true, 'actual original hostname error is classified only in memory before transport');
      network.push({ case: item.name, proxyEvents: 0, originEvents: 0, classification: item.classification }); continue;
    }
    if (item.name === 'inherited-http-original') expect(proxy.some(row => row.transport === 'http' && row.operation === 'request' && row.authorized) && origin.some(row => row.route === 'nonce'), 'inherited App HTTP proxy maps to the actual host listener');
    else if (item.name === 'git-http-connect' || item.name === 'gh-http-connect') expect(proxy.some(row => row.transport === 'http' && row.operation === 'connect' && row.authorized) && origin.some(row => row.transport === 'https'), 'HTTP proxy CONNECT and verified origin TLS: ' + item.name);
    else if (item.name === 'git-https-proxy' || item.name === 'gh-https-proxy') expect(proxy.some(row => row.transport === 'https' && row.operation === 'connect' && row.authorized) && origin.some(row => row.transport === 'https'), 'TLS to proxy plus CONNECT and verified origin TLS: ' + item.name);
    else if (item.name.startsWith('git-bypass-')) expect(proxy.length === 0 && origin.some(row => row.transport === 'https' && row.hostRole === item.name.slice(11)), 'real Git bypasses proxy for the tested domestic hostname');
    else if (item.name === 'python-domestic-bypass') expect(proxy.length === 0 && ['gitee.com', 'repo.gitee.com', 'huaweicloud.com', 'repo.huaweicloud.com'].every(host => origin.some(row => row.hostRole === host)), 'real urllib bypasses proxy for all four hostnames with only DNS redirected by explicit fixture');
    else if (item.name === 'direct-removes-inherited-proxy') expect(proxy.length === 0 && origin.some(row => row.hostRole === 'host-alias'), 'direct mode removes inherited proxy fallback in an actual guest client');
    else expect(false, 'unknown research network case');
    // A real client may first negotiate Basic with an unauthenticated CONNECT
    // and retry after 407. The fixture never forwards that initial challenge.
    expect(proxy.length === 0 || proxy.some(row => row.authorized), 'a proxied client path includes actual successful authentication');
    network.push({ case: item.name, proxyEvents: proxy.length,
      authenticationChallenges: proxy.filter(row => !row.authorized).length,
      originEvents: origin.length, events: measured });
  }
  result = { passed: true, checks, network, baseline: red ? { pid: red.pid, checks: red.checks.length } : null,
    green: { pid: green.pid, checks: green.checks.length, cases: green.cases.length },
    proxyAuthentication: 'ephemeral memory-only fixture, validated by actual proxy; values never saved',
    disclosureScope: 'Only closed safe schemas are written. No raw start/env, control request/response, proxy URL/header/password, arbitrary child output, or private certificate key is deliverable.',
    scope: 'Actual host loopback proxy, authenticated production HTTP control, production owner/backend/native/guest and actual Git/gh/urllib. Archive transport and private test CA/origin/DNS mapping are explicit fixtures. No phone/App UI/public remote account or unrestricted network claim.' };
} catch (error) {
  result = { passed: false, checks, completedPhases: results.map(value => ({ phase: value.phase, passed: value.passed })),
    errorCode: typeof error?.code === 'string' && /^[A-Z0-9_]+$/.test(error.code) ? error.code : 'ERR_PROXY_PAIR_FAILURE',
    safeEvents: fixture.events(), retirementNotInferred: true };
  process.exitCode = 1;
} finally {
  await writeJSON('RESULT.json', result);
  await fixture.close();
}
