// Run against the prepared, patched runtime. No full Host, package manager or model request.
import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs';
import { createRequire } from 'node:module';
import { join, resolve, sep } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
if (!prefix) throw new Error('Set DSH_TEST_PREFIX or DSH_PREFIX to the prepared runtime');
const base = join(resolve(prefix), 'node_modules/@deepseek-ai');
const installedRequire = createRequire(join(base, 'dsh/package.json'));
const load = name => import(pathToFileURL(installedRequire.resolve('@deepseek-ai/' + name)));
const [{ Context }, { createRuntimeResolution, PluginPackages }] = await Promise.all([
  load('cordis'), load('dsh-app-boot'),
]);
const name = '@fixture/engine-package';

async function fixture(t, { declaration, linked = false } = {}) {
  const root = fs.mkdtempSync(join(tmpdir(), 'profile-root-installation-'));
  let ctx;
  t.after(async () => {
    await ctx?.fiber.dispose();
    fs.rmSync(root, { recursive: true, force: true });
  });
  const home = join(root, 'home');
  const dir = join(home, 'profiles/web');
  const installation = join(root, 'installation/node_modules');
  const anchor = join(installation, '@fixture/dsh/package.json');
  function put(path, packageName, version, extra = {}) {
    fs.mkdirSync(path, { recursive: true });
    fs.writeFileSync(join(path, 'package.json'), JSON.stringify({
      name: packageName, version, main: './index.js', ...extra,
    }));
    fs.writeFileSync(join(path, 'index.js'), 'module.exports = {};\n');
    return path;
  }
  put(join(installation, '@fixture/dsh'), '@fixture/dsh', '2.0.0', {
    dependencies: { [name]: '2.0.0' },
  });
  const fresh = put(join(installation, name), name, '2.0.0');
  const local = join(dir, 'node_modules', name);
  const old = put(linked ? join(root, 'external-copy') : local, name, '1.0.0');
  if (linked) {
    fs.mkdirSync(join(dir, 'node_modules/@fixture'), { recursive: true });
    fs.symlinkSync(old, local, 'dir');
  }
  put(dir, 'fixture-profile', '1.0.0', declaration ? {
    [declaration]: { [name]: 'file:' + old },
  } : {});
  const profile = { dir, layers: [], skippedBundles: [] };
  const resolution = await createRuntimeResolution({ installAnchor: anchor, profile, home });
  ctx = new Context();
  await ctx.plugin(PluginPackages, { resolution });
  const selected = parent => ctx.pluginPackages.packageOf(name, pathToFileURL(parent).href);
  return { root, dir, old, fresh, resolution, selected, put, rootURL: dir + sep };
}

test('an undeclared old root copy yields to installation, while third-party dependencies keep their lookup', async t => {
  const f = await fixture(t);
  assert.equal(f.selected(f.rootURL).dir, f.fresh);
  assert.equal(f.selected(f.rootURL).version, '2.0.0');
  const consumer = f.put(join(f.dir, 'node_modules/consumer'), 'consumer', '1.0.0', {
    dependencies: { [name]: '1.0.0' },
  });
  assert.equal(f.selected(join(consumer, 'index.js')).dir, f.old, 'hoisted dependency stays local');
  const privateConsumer = f.put(join(f.dir, 'node_modules/private-consumer'), 'private-consumer', '1.0.0');
  const privateCopy = f.put(join(privateConsumer, 'node_modules', name), name, '1.0.0');
  assert.equal(f.selected(join(privateConsumer, 'index.js')).dir, privateCopy, 'private dependency stays local');
});

test('each direct declaration category retains the old profile package', async t => {
  for (const declaration of ['dependencies', 'peerDependencies', 'optionalDependencies']) {
    await t.test(declaration, async t => {
      const f = await fixture(t, { declaration });
      assert.equal(fs.realpathSync(f.selected(f.rootURL).dir), f.old);
      assert.equal(f.selected(f.rootURL).version, '1.0.0');
    });
  }
});

test('current external links retain the old package, including the explicit file: layout used by r7', async t => {
  for (const declaration of [undefined, 'dependencies']) {
    await t.test(declaration ?? 'undeclared external link', async t => {
      const f = await fixture(t, { declaration, linked: true });
      assert.equal(fs.realpathSync(f.selected(f.rootURL).dir), f.old);
      assert.equal(f.selected(f.rootURL).version, '1.0.0');
    });
  }
});

test('declarations without installed packages do not change the installed-only local names contract', async t => {
  const f = await fixture(t);
  const names = ['dependency-not-installed', 'peer-not-installed', 'optional-not-installed'];
  const fields = ['dependencies', 'peerDependencies', 'optionalDependencies'];
  const manifest = JSON.parse(fs.readFileSync(join(f.dir, 'package.json'), 'utf8'));
  for (let i = 0; i < fields.length; i++) manifest[fields[i]] = { [names[i]]: '*' };
  fs.writeFileSync(join(f.dir, 'package.json'), JSON.stringify(manifest));
  const next = await f.resolution.computeLatestResolution();
  assert.deepEqual([...next.declaredPackageNames], names);
  assert.deepEqual([...next.localPackageNames], []);
});
