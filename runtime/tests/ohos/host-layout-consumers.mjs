// Actual pinned DSH consumers, using the environment captured inside HostCore.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile, writeFile } from 'node:fs/promises';

const [prefix, guestRoot, environmentFile, output] = process.argv.slice(2);
const environment = JSON.parse(await readFile(environmentFile, 'utf8'));
for (const [key, value] of Object.entries(environment)) assert.equal(process.env[key], value, key);
const require = createRequire(join(prefix, 'package.json'));
const load = name => import(pathToFileURL(require.resolve(name)));
const paths = await load('@deepseek-ai/dsh-home-paths');
const { FileSystemSkillProvider } = await load('@deepseek-ai/dsh-skill-filesystem');
const { discoverBaselineInstructionFiles, loadBaselineInstructions } = await load('@deepseek-ai/dsh-agent-instructions');
const desired = { home: join(guestRoot, 'root'), dsh: join(guestRoot, 'root/.dsh'),
  agents: join(guestRoot, 'root/.agents'), workspace: join(guestRoot, 'root/workspace') };
const actual = { home: homedir(), dsh: paths.resolveDshHome(), agents: paths.resolveAgentsHome() };
assert.equal(actual.home, desired.home);
assert.equal(actual.dsh, desired.dsh);
assert.equal(actual.agents, desired.agents);
assert.equal(paths.expandHomePath('~/中文'), join(desired.home, '中文'));
const control = { signal: new AbortController().signal, invalidate() {} };
// Only the optional Cordis fs service is absent. The real provider reads Node fs.
const provider = new FileSystemSkillProvider({ get() { return undefined; } }, control, { watch: false });
const roots = await provider.roots(desired.workspace);
const skills = await provider.list({ cwd: desired.workspace });
const rendered = await loadBaselineInstructions({ cwd: desired.workspace, maxBytes: 32768 });
const discovered = await discoverBaselineInstructionFiles({ cwd: desired.workspace });
await provider.dispose();
assert(roots.some(row => row.source === 'user-agents' && row.path === join(desired.agents, 'skills')));
assert(skills.some(row => row.name === 'dsh-home-proof'));
assert(skills.some(row => row.name === 'agents-home-proof'));
assert(rendered.text.includes('DSH_GLOBAL_FIXTURE_中文'));
assert(rendered.text.includes('AGENTS_GLOBAL_FIXTURE_中文'));
assert(discovered.some(row => row.absolutePath === join(desired.agents, 'AGENTS.md')));
await writeFile(output, JSON.stringify({
  scope: 'Real fixed DSH path helpers, skill provider and instruction loader on Linux; Host-captured environment. Not Ark or a device.',
  desired, actual, roots, skillSources: skills.map(row => ({ name: row.name, source: row.source, path: row.path })),
  discovered, instructionText: rendered.text, assertionsPassed: true,
}, null, 2) + '\n');
console.log('Actual DSH HOME, DSH_HOME, DSH_AGENTS_HOME, skills and AGENTS.md consumers matched the guest layout.');
