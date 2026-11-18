#!/usr/bin/env node
// Rehearses scripts/publish-release.sh with nothing real: a fake dist/ and
// made-up keys. Nothing leaves this machine.
//
//  1. Dry runs (Aliyun OSS + GitHub, Tencent COS, China off, dl off, missing
//     settings): every step printed, nothing run — curl, rclone, npx, gh,
//     ossutil and coscli are all booby-trapped.
//  2. Real runs against fakes: `wrangler dev` (local R2 and KV), a static
//     server for the public download bucket, the Hong Kong bucket and GitHub's
//     downloads, fake ossutil / coscli / gh (test/publish-fakes/). Public mode
//     with OSS, key mode with COS: publish, publish again (skips what's there),
//     a changed APK under the same version is refused, a corrupt copy on one
//     route stops the release.
//
// The made-up dist has an APK and a delta patch from the version before.
//
//   npm run smoke:publish                 both
//   npm run smoke:publish -- --dry-run-only

import { spawn, spawnSync } from 'node:child_process';
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const worker = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fakes = join(worker, 'test/publish-fakes');
const script = join(worker, 'scripts/publish-release.sh');
const state = mkdtempSync(join(process.env.SMOKE_TMP ?? tmpdir(), 'dshgo-publish-'));
const dryOnly = process.argv.includes('--dry-run-only');

// The two newest versions in the changelog: the script takes notes from there.
const changelog = readFileSync(join(worker, '../../docs/changelog.md'), 'utf8');
const [VERSION, OLDER] = [...changelog.matchAll(/^## (\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)\b/gm)].map((m) => m[1]);

const patchName = (version) => `dsh-go-${version}-from-0.9.0-arm64.dshdelta`;

function makeDist(version) {
  const dir = join(state, `dist-${version}`);
  mkdirSync(dir, { recursive: true });
  const sums = [];
  const file = (name, size) => {
    const bytes = randomBytes(size);
    writeFileSync(join(dir, name), bytes);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    sums.push(`${sha256}  ${name}`);
    return { name, size, sha256 };
  };
  const assets = { arm64: file(`dsh-go-${version}-arm64.apk`, 900_000) };
  const patch = file(patchName(version), 70_000);
  writeFileSync(join(dir, 'SHA256SUMS'), sums.join('\n') + '\n');
  writeFileSync(join(dir, 'update.json'), JSON.stringify({
    schema: 1, version: `${version}+10291200`, tag: `v${version}`, title: `DSH Go ${version}`, publishedAt: '2026-10-29T04:00:00Z',
    notes: '', page: `https://github.com/ccch1mneyyy/dsh-go/releases/tag/v${version}`, assets,
    patches: { arm64: [{ from: 'ab'.repeat(32), fromVersion: '0.9.0+10200000', ...patch }] },
  }, null, 2));
  return dir;
}

// Made-up keys, in files as the script wants them.
const keys = join(state, 'keys');
mkdirSync(keys, { mode: 0o700 });
const secret = (name, value) => (writeFileSync(join(keys, name), value + '\n', { mode: 0o600 }), join(keys, name));
const fake = {
  cf: secret('cf.token', 'fake-cf-' + randomBytes(12).toString('hex')),
  channel: 'dshc_' + randomBytes(32).toString('base64url'),
  id: 'LTAIfake' + randomBytes(8).toString('hex'),
  secret: randomBytes(20).toString('base64url'),
  key: 'dsh-sm9ke234',
};
const files = {
  cf: fake.cf,
  channel: secret('channel.token', fake.channel),
  id: secret('cn.id', fake.id),
  secret: secret('cn.secret', fake.secret),
  key: secret('beta.key', fake.key),
};
const log = join(state, 'cli.log');

const CN = {
  oss: { CN_PROVIDER: 'oss', CN_BUCKET: 'dshgo-cn', CN_REGION: 'cn-hongkong' },
  cos: { CN_PROVIDER: 'cos', CN_BUCKET: 'dshgo-cn-1250000000', CN_REGION: 'ap-hongkong' },
};

function publish(dist, args, env) {
  // Never anything of the caller's: no real tokens reach the script.
  const clean = Object.fromEntries(Object.entries(process.env).filter(([k]) => !/^(CN_|DL_|GH_|BETA_|CF_|CLOUDFLARE|GITHUB_|R2_)/.test(k)));
  const r = spawnSync(script, [dist, ...args], {
    cwd: worker,
    encoding: 'utf8',
    timeout: 300_000,
    env: {
      ...clean, FAKE_LOG: log, FAKE_KEY_ID: fake.id, FAKE_KEY_SECRET: fake.secret, WRANGLER_SEND_METRICS: 'false',
      CF_TOKEN_FILE: files.cf, CF_ACCOUNT_ID: '0123456789abcdef0123456789abcdef', BETA_TOKEN_FILE: files.channel, BETA_KEY_FILE: files.key,
      CN_ACCESS_KEY_ID_FILE: files.id, CN_ACCESS_KEY_SECRET_FILE: files.secret, ...env,
    },
  });
  const out = (r.stdout ?? '') + (r.stderr ?? '');
  return { code: r.status, out };
}

let passed = 0;
function check(ok, what, detail = '') {
  if (!ok) throw new Error(`${what}${detail ? `\n${detail}` : ''}`);
  passed++;
  console.log(`ok - ${what}`);
}
const noSecrets = (text) => ![fake.secret, fake.id, fake.channel, readFileSync(fake.cf, 'utf8').trim()].some((s) => text.includes(s));

// ── 1. Dry runs ──────────────────────────────────────────────────────────
function dryRuns() {
  const trapped = join(state, 'trapped-bin');
  mkdirSync(trapped);
  for (const tool of ['curl', 'rclone', 'npx', 'gh', 'ossutil', 'coscli', 'wrangler']) symlinkSync(join(fakes, 'forbidden'), join(trapped, tool));
  const PATH = `${trapped}:${process.env.PATH}`;
  const dist = makeDist(VERSION);
  writeFileSync(log, '');

  const oss = publish(dist, ['--dry-run', '--github'], { PATH, ...CN.oss, CN_BASE_URL: 'https://dshgo-cn.oss-cn-hongkong.aliyuncs.com/' });
  console.log(oss.out.replace(/^/gm, '  | '));
  check(oss.code === 0, 'dry run (OSS + GitHub) exits 0', oss.out);
  const apk = `dsh-go-${VERSION}-arm64.apk`;
  const immutable = "'Cache-Control: public, max-age=31536000, immutable'";
  for (const s of ['== 1/5 R2 dshgo-share/beta/', `dshgo-dl/download/${VERSION}/`, '== 2/5 China oss dshgo-cn', '== 3/5 GitHub', '== 4/5 check', '== 5/5 go live', 'ossutil cp', 'gh release create', '--draft', 'gh release edit', '--draft=false',
    `download China ${apk}`, `download dl ${apk}`, `download dl ${patchName(VERSION)}`, `download R2 ${patchName(VERSION)}`, 'routes: global dl cn github', '"routes": [',
    `r2:dshgo-dl/download/${VERSION}/${apk} --header-upload 'Content-Type: application/vnd.android.package-archive' --header-upload ${immutable}`,
    `r2:dshgo-dl/download/${VERSION}/${patchName(VERSION)} --header-upload 'Content-Type: application/octet-stream' --header-upload ${immutable}`,
    `r2:dshgo-dl/download/${VERSION}/update.json --header-upload 'Content-Type: application/json; charset=utf-8' --header-upload ${immutable}`,
    "r2:dshgo-dl/update.json --header-upload 'Content-Type: application/json; charset=utf-8' --header-upload 'Cache-Control: public, max-age=300'",
    `"url": "https://dl.dshtui.com/download/${VERSION}/${apk}"`, `"name": "${patchName(VERSION)}"`]) {
    check(oss.out.includes(s), `dry run prints: ${s}`);
  }
  check(oss.out.indexOf('gh release edit') > oss.out.lastIndexOf('gh release download'), 'dry run: GitHub goes public only after every download');
  check(oss.out.indexOf('r2:dshgo-dl/update.json') > oss.out.indexOf('--draft=false'), "dry run: dl's update.json goes up once GitHub is public");
  check(oss.out.lastIndexOf('beta/update.json') > oss.out.indexOf('r2:dshgo-dl/update.json'), 'dry run: beta/update.json goes up last');
  check(oss.out.indexOf('r2:dshgo-dl/update.json') > oss.out.lastIndexOf('download China'), "dry run: dl's update.json only after every download");

  const cos = publish(dist, ['--dry-run'], { PATH, ...CN.cos, CN_BASE_URL: 'https://dshgo-cn-1250000000.cos.ap-hongkong.myqcloud.com' });
  check(cos.code === 0 && cos.out.includes("coscli cp") && cos.out.includes('Content-Type:application/vnd.android.package-archive#Cache-Control:') && cos.out.includes('GitHub (off'), 'dry run (COS, no GitHub)', cos.out);
  check(cos.out.includes('https://dshgo-cn-1250000000.cos.ap-hongkong.myqcloud.com/' + VERSION), 'dry run: CN_BASE_URL gets its trailing slash');

  const off = publish(dist, ['--dry-run', '--no-dl'], { PATH, CN_BASE_URL: '' });
  check(off.code === 0 && off.out.includes('skipped: CN_BASE_URL is empty') && off.out.includes('routes: global\n') && !off.out.includes('dshgo-dl'), 'dry run with --no-dl and no China route: R2 only', off.out);
  const noDl = publish(dist, ['--dry-run'], { PATH, CN_BASE_URL: '', DL_BASE_URL: '' });
  check(noDl.code === 0 && noDl.out.includes('routes: global\n') && !noDl.out.includes('dshgo-dl'), 'an empty DL_BASE_URL turns dl off', noDl.out);
  const fromWrangler = publish(dist, ['--dry-run'], { PATH });
  check(fromWrangler.code === 0 && fromWrangler.out.includes('skipped: CN_BASE_URL is empty in wrangler.jsonc'), "CN_BASE_URL defaults to wrangler.jsonc's", fromWrangler.out);
  check(fromWrangler.out.includes('routes: global dl (dl: dshgo-dl, https://dl.dshtui.com/)'), "dl is on by default, DL_BASE_URL from wrangler.jsonc's", fromWrangler.out);
  const otherDl = publish(dist, ['--dry-run'], { PATH, CN_BASE_URL: '', DL_BUCKET: 'my-dl', DL_BASE_URL: 'https://dl.example.com' });
  check(otherDl.out.includes(`r2:my-dl/download/${VERSION}/`) && otherDl.out.includes(`download dl ${patchName(VERSION)}`) && otherDl.out.includes(`"url": "https://dl.example.com/download/${VERSION}/`), 'DL_BUCKET and DL_BASE_URL (its trailing slash added)', otherDl.out);
  // A prerelease: the beta channel gets it, dl's root update.json doesn't.
  const BETA = '9.9.9-beta.1';
  const changelogFile = join(state, 'changelog.md');
  writeFileSync(changelogFile, `## ${BETA} · 2026-11-01\n\n### 中文\n\n- 测试\n\n### English\n\n- Test\n`);
  const pre = publish(makeDist(BETA), ['--dry-run'], { PATH, CN_BASE_URL: '', CHANGELOG: changelogFile });
  check(pre.code === 0 && pre.out.includes(`r2:dshgo-dl/download/${BETA}/update.json`) && !pre.out.includes('r2:dshgo-dl/update.json') && pre.out.includes('r2:dshgo-share/beta/update.json'), "a prerelease leaves dl's root update.json alone", pre.out);
  const badDl = publish(dist, ['--dry-run'], { PATH, CN_BASE_URL: '', DL_BASE_URL: 'http://dl.example.com/' });
  check(badDl.code === 1 && badDl.out.includes('DL_BASE_URL must be https://'), 'DL_BASE_URL must be https', badDl.out);

  const placeholder = publish(dist, ['--dry-run'], { PATH, CN_BASE_URL: '', CF_ACCOUNT_ID: '00000000000000000000000000000000' });
  check(placeholder.code === 1 && placeholder.out.includes('no Cloudflare account id'), 'the placeholder account is refused before anything runs', placeholder.out);
  const missing = publish(dist, ['--dry-run'], { PATH, CN_BASE_URL: 'https://dshgo-cn.oss-cn-hongkong.aliyuncs.com/', CN_ACCESS_KEY_SECRET_FILE: join(keys, 'nope') });
  check(missing.code === 1 && ['CN_PROVIDER', 'CN_BUCKET', 'CN_REGION', 'CN_ACCESS_KEY_SECRET_FILE'].every((s) => missing.out.includes(s)), 'missing settings are all listed at once', missing.out);
  const stale = makeDist(OLDER);
  writeFileSync(join(stale, 'SHA256SUMS'), readFileSync(join(stale, 'SHA256SUMS'), 'utf8').replace(/^\w+(  dsh-go-[^\n]*\.dshdelta)$/m, `${'0'.repeat(64)}$1`));
  const mismatch = publish(stale, ['--dry-run'], { PATH, CN_BASE_URL: '' });
  check(mismatch.code === 1 && mismatch.out.includes(`${patchName(OLDER)}: SHA-256 differs from SHA256SUMS`), 'a patch unlike SHA256SUMS is refused', mismatch.out);
  const skip = publish(dist, ['--dry-run', '--skip-verify'], { PATH, CN_BASE_URL: '' });
  check(skip.code === 1 && skip.out.includes('--skip-verify needs --no-latest'), 'nothing goes live unchecked', skip.out);
  check(publish(dist, ['--dry-run', '--skip-verify', '--no-latest'], { PATH, CN_BASE_URL: '' }).code === 0, '--skip-verify --no-latest is fine');

  check(readFileSync(log, 'utf8') === '', 'dry runs ran nothing (no curl, rclone, npx, gh, ossutil, coscli)', readFileSync(log, 'utf8'));
  check(noSecrets(oss.out + cos.out), 'dry runs print no secret');
}

// ── 2. Real runs against fakes ───────────────────────────────────────────
const workerEnv = { cwd: worker, env: { ...process.env, CLOUDFLARE_API_TOKEN: '', WRANGLER_SEND_METRICS: 'false' }, encoding: 'utf8' };
const port = () => 8700 + Math.floor(Math.random() * 400);

async function up(url) {
  const deadline = Date.now() + 90_000;
  for (;;) {
    try {
      if ((await fetch(url)).status < 500) return;
    } catch {}
    if (Date.now() > deadline) throw new Error(`${url} did not come up`);
    await new Promise((r) => setTimeout(r, 400));
  }
}

async function realRun(mode, provider) {
  const dir = join(state, `run-${mode}`);
  const persist = join(dir, 'persist');
  const served = join(dir, 'served');
  for (const d of ['cn', 'gh', 'dl']) mkdirSync(join(served, d), { recursive: true });
  writeFileSync(log, '');
  const betaSecret = randomBytes(32).toString('base64url');
  for (const [k, v] of [
    [`beta:chan:${createHash('sha256').update(fake.channel).digest('hex')}`, { label: 'smoke-app' }],
    [`beta:key:${createHmac('sha256', betaSecret).update(`key\n${fake.key}`).digest('hex')}`, { label: 'smoke' }],
  ]) {
    const r = spawnSync('npx', ['wrangler', 'kv', 'key', 'put', k, JSON.stringify(v), '--binding', 'QUOTA', '--local', '--persist-to', persist], workerEnv);
    if (r.status !== 0) throw new Error(r.stderr);
  }
  const sport = port();
  const wport = sport + 400;
  const cnBase = `http://127.0.0.1:${sport}/cn/`;
  const dlBase = `http://127.0.0.1:${sport}/dl/`;
  const ghBase = `http://127.0.0.1:${sport}/gh`;
  const origin = `http://127.0.0.1:${wport}`;
  const server = spawn('python3', [join(fakes, 'static_server.py'), served, String(sport)], { stdio: 'ignore' });
  const dev = spawn('npx', ['wrangler', 'dev', '--local', '--ip', '127.0.0.1', '--port', String(wport), '--persist-to', persist,
    '--var', `BETA_SECRET:${betaSecret}`, '--var', `DOWNLOAD_ACCESS:${mode === 'key' ? 'key' : 'public'}`, '--var', `CN_BASE_URL:${cnBase}`, '--var', `DL_BASE_URL:${dlBase}`, '--show-interactive-dev-session=false'],
  { ...workerEnv, stdio: ['ignore', 'pipe', 'pipe'] });
  let devOut = '';
  dev.stdout.on('data', (d) => (devOut += d));
  dev.stderr.on('data', (d) => (devOut += d));
  const env = {
    PATH: `${fakes}:${process.env.PATH}`, ...CN[provider], FAKE_BUCKET: CN[provider].CN_BUCKET, FAKE_REGION: CN[provider].CN_REGION,
    FAKE_CN_ROOT: join(served, 'cn'), FAKE_GH_ROOT: join(served, 'gh'),
    R2_LOCAL_PERSIST: persist, BETA_ORIGIN: origin, CN_BASE_URL: cnBase, GITHUB_DOWNLOAD_BASE: ghBase,
    DL_LOCAL_ROOT: join(served, 'dl'), DL_BASE_URL: dlBase,
  };
  // spawnSync blocks the event loop, so a kept-alive socket can be closed under
  // fetch's feet while a publish runs: one retry.
  const get = (url, init) => fetch(url, init).catch(() => fetch(url, init));
  const feed = async () => (await get(`${origin}/beta/update.json`, { headers: { Authorization: `Bearer ${fake.channel}` } })).json();
  try {
    await up(`http://127.0.0.1:${sport}/`);
    await up(`${origin}/robots.txt`).catch((e) => { throw new Error(`${e.message}\n${devOut.slice(-3000)}`); });
    const dist = makeDist(VERSION);
    const tag = `v${VERSION}`;

    const first = publish(dist, ['--github'], env);
    console.log(first.out.replace(/^/gm, '  | '));
    check(first.code === 0 && first.out.includes(`published ${VERSION}: global dl cn github`), `${mode}/${provider}: publishes to R2, dl, China and GitHub`, first.out);
    check(first.out.includes({ public: `${origin}/download offers ${VERSION}`, key: `${origin}/beta (access key) offers ${VERSION}` }[mode]), `${mode}: the live page offers it on every route`);
    check(noSecrets(first.out + readFileSync(log, 'utf8')), `${mode}: no secret in the output or on any command line`);
    const apk = `dsh-go-${VERSION}-arm64.apk`;
    const files = `SHA256SUMS ${apk} ${patchName(VERSION)}`;
    check(readdirSync(join(served, 'cn', VERSION)).sort().join(' ') === files, `${mode}: China has every file in SHA256SUMS`);
    check(readdirSync(join(served, 'dl', 'download', VERSION)).sort().join(' ') === `${files} update.json`, `${mode}: dl has every file in SHA256SUMS, and update.json`);
    const dl = JSON.parse(readFileSync(join(served, 'dl', 'update.json'), 'utf8'));
    check(dl.version === `${VERSION}+10291200` && dl.assets.arm64.url === `${dlBase}download/${VERSION}/${apk}` && dl.page === `https://github.com/ccch1mneyyy/dsh-go/releases/tag/${tag}`
      && dl.notesByLocale.zh && !('routes' in dl) && dl.patches.arm64[0].name === patchName(VERSION) && !('url' in dl.patches.arm64[0]), `${mode}: dl's update.json: absolute APK URLs on dl, the patches as release_assets.py wrote them`);
    check(readFileSync(join(served, 'dl', 'download', VERSION, 'update.json'), 'utf8') === readFileSync(join(served, 'dl', 'update.json'), 'utf8'), `${mode}: dl keeps the version's copy`);
    const gh = JSON.parse(readFileSync(join(served, 'gh', tag, 'update.json'), 'utf8'));
    const release = JSON.parse(readFileSync(join(served, 'gh', tag, '.release.json'), 'utf8'));
    check(!existsSync(join(served, 'gh', '_drafts', tag)) && release.title === `DSH Go ${VERSION}` && /### 中文\n[\s\S]+\n### English\n/.test(release.notes), `${mode}: GitHub release published, notes from the changelog`);
    check(!('url' in gh.assets.arm64) && !('routes' in gh) && gh.notesByLocale.en, `${mode}: GitHub's update.json lets the app use GitHub URLs`);
    check(existsSync(join(served, 'gh', tag, patchName(VERSION))) && gh.patches.arm64[0].sha256 === dl.patches.arm64[0].sha256 && release.notes.includes('`*.dshdelta`'), `${mode}: GitHub has the patch too, and says what it is`);
    check(!existsSync(join(served, 'gh', tag, `dsh-go-${VERSION}-x64.apk`)) && existsSync(join(served, 'gh', tag, `dsh-go-${VERSION}-arm64.apk`))
      && Object.keys(gh.assets).join(' ') === 'arm64'
      && !release.notes.includes('### 其他版本下载') && !release.notes.includes('-x64.apk')
      && release.notes.includes(`${ghBase}/${tag}/dsh-go-${VERSION}-arm64.apk`)
      && release.notes.includes('update.json') && release.notes.includes('SHA256SUMS')
      && release.notes.includes('无需手动下载'), `${mode}: GitHub offers only arm64 with a clear install link and helper-file explanation`);
    const latest = await feed();
    check(JSON.stringify(latest.routes) === '["global","dl","cn","github"]' && latest.assets.arm64.url === `${origin}/beta/${VERSION}/dsh-go-${VERSION}-arm64.apk` && latest.patches.arm64.length === 1, `${mode}: beta/update.json lists the routes; the app's URLs are as before`);
    const calls = readFileSync(log, 'utf8');
    check(calls.indexOf('--draft=false') > calls.lastIndexOf('release download'), `${mode}: GitHub went public after every file was downloaded back`);

    // What a visitor gets from workerd itself.
    if (mode === 'public') {
      const old = await get(`${origin}/beta?lang=en`, { redirect: 'manual' });
      check(old.status === 302 && old.headers.get('location') === '/download?lang=en', 'public: the old /beta link redirects to /download');
      const page = await (await get(`${origin}/download?via=cn`)).text();
      check(page.includes(`href="/download/get?via=cn&amp;v=${VERSION}"`) && /id="via-0" value="cn" checked/.test(page), 'public: ?via=cn picks the China route');
      const hop = await get(`${origin}/download/get?via=cn&v=${VERSION}`, { redirect: 'manual' });
      check(hop.status === 302 && hop.headers.get('location') === `${cnBase}${VERSION}/dsh-go-${VERSION}-arm64.apk`, 'public: the China button is counted and redirects to the bucket');
      const global = await get(`${origin}/download/get?via=global&v=${VERSION}`, { redirect: 'manual' });
      check(global.status === 302 && global.headers.get('location') === `${dlBase}download/${VERSION}/dsh-go-${VERSION}-arm64.apk`, 'public: the Global button redirects to the public bucket');
      const file = `${origin}/download/${VERSION}/dsh-go-${VERSION}-arm64.apk`;
      const part = await get(file, { headers: { Range: 'bytes=100-199' } });
      check(part.status === 206 && part.headers.get('content-range') === `bytes 100-199/900000` && (await part.arrayBuffer()).byteLength === 100, 'public: Range gives 206');
      const full = await get(file);
      const bytes = Buffer.from(await full.arrayBuffer());
      check(full.headers.get('cache-control') === 'public, max-age=31536000, immutable' && bytes.length === 900_000, 'public: the APK is cacheable');
      const past = await get(file, { headers: { Range: 'bytes=900000-' } });
      await past.arrayBuffer();
      check(past.status === 416, 'public: a range past the end is 416');
    }

    // A rerun refreshes the notes of the published release from the changelog.
    const releaseFile = join(served, 'gh', tag, '.release.json');
    writeFileSync(releaseFile, JSON.stringify({ ...JSON.parse(readFileSync(releaseFile, 'utf8')), notes: 'stale' }));
    const again = publish(dist, ['--github'], env);
    const skipped = (again.out.match(/already there/g) ?? []).length;
    // R2, dl and China: the APK, the patch, SHA256SUMS; GitHub: those, while update.json is replaced on a published release.
    check(again.code === 0 && skipped === 12, `${mode}: publishing again skips what's there (${skipped} files)`, again.out);
    const reupload = readFileSync(log, 'utf8').split('\n').filter((l) => l.startsWith('gh release upload') && l.includes('--clobber') && l.includes('update.json'));
    check(reupload.length > 0, `${mode}: publishing again replaces update.json on GitHub`, again.out);
    check(JSON.parse(readFileSync(releaseFile, 'utf8')).notes === release.notes, `${mode}: publishing again restores the release notes`, again.out);

    const apkFile = join(dist, apk);
    appendFileSync(apkFile, 'changed');
    const m = JSON.parse(readFileSync(join(dist, 'update.json'), 'utf8'));
    const sha = createHash('sha256').update(readFileSync(apkFile)).digest('hex');
    writeFileSync(join(dist, 'SHA256SUMS'), readFileSync(join(dist, 'SHA256SUMS'), 'utf8').replace(m.assets.arm64.sha256, sha));
    Object.assign(m.assets.arm64, { size: m.assets.arm64.size + 7, sha256: sha });
    writeFileSync(join(dist, 'update.json'), JSON.stringify(m));
    const changed = publish(dist, ['--github'], env);
    check(changed.code === 1 && changed.out.includes('already up with another size'), `${mode}: a changed APK under the same version is refused`, changed.out);

    // The Hong Kong bucket holds a broken copy of the older version: nothing goes live.
    const older = makeDist(OLDER);
    const name = `dsh-go-${OLDER}-arm64.apk`;
    mkdirSync(join(served, 'cn', OLDER));
    const broken = readFileSync(join(older, name));
    broken[1234] ^= 0xff;
    writeFileSync(join(served, 'cn', OLDER, name), broken);
    const corrupt = publish(older, ['--github'], env);
    check(corrupt.code === 1 && corrupt.out.includes(`China ${name} doesn't match`), `${mode}: a corrupt copy on one route stops the release`, corrupt.out);
    check((await feed()).version.startsWith(`${VERSION}+`) && existsSync(join(served, 'gh', '_drafts', `v${OLDER}`))
      && JSON.parse(readFileSync(join(served, 'dl', 'update.json'), 'utf8')).version.startsWith(`${VERSION}+`), `${mode}: the page, the app, dl and GitHub stay on ${VERSION}`);
  } catch (e) {
    e.message += `${e.cause ? ` (${e.cause.message ?? e.cause})` : ''}\n--- wrangler dev ---\n${devOut.slice(-3000)}`;
    throw e;
  } finally {
    dev.kill('SIGTERM');
    server.kill('SIGTERM');
  }
}

try {
  console.log(`publish smoke: ${VERSION} (and ${OLDER}) in ${state}`);
  dryRuns();
  if (!dryOnly) {
    await realRun('public', 'oss');
    await realRun('key', 'cos');
  }
  console.log(`publish smoke: all ${passed} passed`);
  rmSync(state, { recursive: true, force: true });
} catch (e) {
  console.error(`publish smoke: FAILED ${e.message}\n(kept ${state})`);
  process.exit(1);
}
