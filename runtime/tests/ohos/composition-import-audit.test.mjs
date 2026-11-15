import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import test from 'node:test';
import { auditImports } from '../../ohos/package/audit-imports.mjs';

const esbuild = resolve(process.env.OHOS_ESBUILD_PREFIX);
const sha256 = value => createHash('sha256').update(value).digest('hex');

async function fixture(files, body) {
  const directory = await mkdtemp(join(tmpdir(), 'ohos-import-audit-'));
  const root = join(directory, 'payload');
  await mkdir(root);
  try {
    for (const [name, value] of Object.entries(files)) {
      const path = join(root, name);
      await mkdir(dirname(path), { recursive: true });
      await writeFile(path, value);
    }
    await body(root, directory);
  } finally { await rm(directory, { recursive: true, force: true }); }
}

test('every retained file is checked, including static exports outside the boot graph', async () => {
  await fixture({ 'entry.mjs': "import 'node:fs';\n",
    'unused.mjs': "export { missing } from './not-shipped.mjs';\n" }, async root => {
    const report = await auditImports(root, esbuild);
    assert.equal(report.passed, false);
    assert.equal(report.files.length, 2);
    assert(report.errors.some(row => row.importer === 'unused.mjs' && row.specifier === './not-shipped.mjs'));
  });
});

test('syntax parsing ignores comments and strings; same-basename JS/MJS both survive', async () => {
  await fixture({ 'same.js': "// import 'not-a-module';\nexport const text = \"import('also-not-a-module')\";\n",
    'same.mjs': "import './same.js'; export { text } from './same.js';\n" }, async root => {
    const report = await auditImports(root, esbuild);
    assert.equal(report.passed, true, JSON.stringify(report.errors));
    assert.equal(report.files.length, 2);
    assert(report.imports.every(row => row.specifier === './same.js'));
  });
});

test('the gate does not expand a computed path into non-JavaScript assets', async () => {
  await fixture({ 'assets/texture.avif': Buffer.from([0, 255, 137, 0]),
    'index.mjs': "export const load = name => import('./assets/' + name);\n" }, async root => {
    const report = await auditImports(root, esbuild);
    assert.equal(report.passed, true, JSON.stringify(report.errors));
    assert.equal(report.files.length, 1);
    assert.match(report.scope, /nonliteral specifiers need execution coverage/);
  });
});

test('ESM extensionless and directory paths fail instead of borrowing require resolution', async () => {
  await fixture({ 'index.mjs': "import './helper'; import './directory';\n",
    'helper.js': 'export const ok = true;\n', 'directory/index.js': 'export const ok = true;\n' }, async root => {
    const report = await auditImports(root, esbuild);
    assert.equal(report.passed, false);
    assert.deepEqual(report.errors.map(row => row.specifier).sort(), ['./directory', './helper']);
  });
});

test('Node package conditions and importer-relative resolution determine actual targets', async () => {
  await fixture({
    'sub/entry.mjs': "import 'conditional-package';\n",
    'sub/entry.cjs': "require('conditional-package');\n",
    'sub/node_modules/conditional-package/package.json': JSON.stringify({ name: 'conditional-package',
      exports: { node: { import: './node.mjs', require: './node.cjs' }, default: './missing-browser.mjs' } }),
    'sub/node_modules/conditional-package/node.mjs': 'export const ok = true;\n',
    'sub/node_modules/conditional-package/node.cjs': 'module.exports = true;\n',
  }, async root => {
    const report = await auditImports(root, esbuild);
    assert.equal(report.passed, true, JSON.stringify(report.errors));
    assert.equal(report.imports.find(row => row.importer === 'sub/entry.mjs').resolved,
      'sub/node_modules/conditional-package/node.mjs');
    assert.equal(report.imports.find(row => row.importer === 'sub/entry.cjs').resolved,
      'sub/node_modules/conditional-package/node.cjs');
  });
});

test('a static import cannot escape the payload through a path or a symlink', async () => {
  await fixture({ 'index.mjs': "import '../outside.mjs'; import './linked.mjs';\n" }, async (root, directory) => {
    await writeFile(join(directory, 'outside.mjs'), 'export const outside = true;\n');
    await symlink(join(directory, 'outside.mjs'), join(root, 'linked.mjs'));
    const report = await auditImports(root, esbuild);
    assert.equal(report.passed, false);
    assert.equal(report.errors.length, 2);
    assert(report.imports.filter(row => row.missing).every(row => /escaped/.test(row.message)));
  });
});

test('missing literal require is recorded as a separate, explicitly limited audit surface', async () => {
  await fixture({ 'optional.cjs': "exports.load = () => require('not-installed-optional-package');\n" }, async root => {
    const report = await auditImports(root, esbuild);
    assert.equal(report.passed, true);
    assert.equal(report.unresolvedRequireCalls.length, 1);
    assert.equal(report.unresolvedRequireCalls[0].specifier, 'not-installed-optional-package');
    assert.match(report.scope, /Literal require calls are recorded separately/);
  });
});

test('unlisted dynamic import fails and the exact source/count/reason allowlist passes', async () => {
  const source = "export const one = () => import('./omitted.mjs');\nexport const two = () => import('./omitted.mjs');\n";
  await fixture({ 'index.mjs': source }, async root => {
    const before = await auditImports(root, esbuild);
    assert.equal(before.passed, false);
    assert.equal(before.errors.length, 2);
    const exception = { importer: 'index.mjs', specifier: './omitted.mjs', occurrences: 2,
      importerSha256: sha256(source), reason: 'Fixture public API never calls these private loaders.' };
    const after = await auditImports(root, esbuild, [exception]);
    assert.equal(after.passed, true, JSON.stringify(after.errors));
    for (const change of [{ occurrences: 1 }, { importerSha256: '0'.repeat(64) }, { reason: '' }]) {
      assert.equal((await auditImports(root, esbuild, [{ ...exception, ...change }])).passed, false);
    }
  });
});

test('an unused or now-resolvable dynamic exception is rejected', async () => {
  const source = "export const load = () => import('./included.mjs');\n";
  await fixture({ 'index.mjs': source, 'included.mjs': 'export const ok = true;\n' }, async root => {
    const exception = { importer: 'index.mjs', specifier: './included.mjs', occurrences: 1,
      importerSha256: sha256(source), reason: 'Old omission which no longer exists.' };
    const report = await auditImports(root, esbuild, [exception]);
    assert.equal(report.passed, false);
    assert.match(report.errors[0].message, /Unused or stale/);
  });
});

test('a dynamic exception can never excuse a static import', async () => {
  const source = "import './omitted.mjs';\n";
  await fixture({ 'index.mjs': source }, async root => {
    const report = await auditImports(root, esbuild, [{ importer: 'index.mjs', specifier: './omitted.mjs',
      occurrences: 1, importerSha256: sha256(source), reason: 'Invalid attempt to excuse a static dependency.' }]);
    assert.equal(report.passed, false);
    assert(report.errors.some(row => /Unresolved static/.test(row.message)));
  });
});

test('invalid retained JavaScript rejects the assembly', async () => {
  await fixture({ 'bad.mjs': 'export const = ;\n' }, async root => {
    const report = await auditImports(root, esbuild);
    assert.equal(report.passed, false);
    assert(report.errors.some(row => row.kind === 'parse'));
  });
});
