// 设置面板后端：配置校验 + 写回 profile patch 的正确性（用临时文件，不碰真实配置）
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { normalizeSettings, writeProfileConfig } from '../lib/index.js';
import { loadYaml } from './_paths.mjs';

const yaml = loadYaml();

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra ? ' -> ' + JSON.stringify(extra) : ''}`);
  }
};

const dir = mkdtempSync(join(tmpdir(), 'checkup-'));
const baseConfig = {
  preflightEnabled: true,
  blockOnWarn: false,
  registries: ['https://registry.npmmirror.com', 'https://registry.npmjs.org'],
  lookupTimeoutMs: 8000,
  lookupAttempts: 2,
  knownBad: ['dsh-broken@0.1.2'],
};

console.log('\n[A] normalizeSettings 校验');
{
  const merged = normalizeSettings({ blockOnWarn: true, lookupTimeoutMs: '12000', lookupAttempts: '3' }, baseConfig);
  ok('布尔/数字字符串被正确归一', merged.blockOnWarn === true && merged.lookupTimeoutMs === 12000 && merged.lookupAttempts === 3);

  const dedup = normalizeSettings({ registries: ['https://a.example/', 'https://a.example', 'https://b.example'] }, baseConfig);
  ok('registries 去重 + 去尾斜杠', JSON.stringify(dedup.registries) === JSON.stringify(['https://a.example', 'https://b.example']), dedup.registries);

  let threw = false;
  try { normalizeSettings({ registries: ['ftp://bad', 'not-a-url'] }, baseConfig); } catch { threw = true; }
  ok('非法 registry 地址被拒绝', threw);

  threw = false;
  try { normalizeSettings({ lookupTimeoutMs: 999 }, baseConfig); } catch { threw = true; }
  ok('超时越界被拒绝', threw);

  threw = false;
  try { normalizeSettings({ lookupAttempts: 9 }, baseConfig); } catch { threw = true; }
  ok('重试越界被拒绝', threw);

  const list = normalizeSettings({ knownBad: [' a@1.0.0 ', 'a@1.0.0', '', 'b'] }, baseConfig);
  ok('黑名单去空白去重', JSON.stringify(list.knownBad) === JSON.stringify(['a@1.0.0', 'b']), list.knownBad);
}

console.log('\n[B] writeProfileConfig — 空文件追加');
{
  const file = join(dir, 'patch-empty.yml');
  writeFileSync(file, '');
  const result = await writeProfileConfig(file, baseConfig);
  const text = readFileSync(file, 'utf8');
  const doc = yaml.parse(text);
  ok('返回 appended', result === 'appended', result);
  ok('解析出 1 个条目', Array.isArray(doc) && doc.length === 1, doc);
  ok('id/name 正确', doc[0].id === 'checkup' && doc[0].name === 'dsh-checkup', doc[0]);
  ok('config 完整写入', doc[0].config.lookupTimeoutMs === 8000 && doc[0].config.knownBad[0] === 'dsh-broken@0.1.2', doc[0].config);
}

console.log('\n[C] writeProfileConfig — 已有条目更新且不破坏其他条目');
{
  const file = join(dir, 'patch-exist.yml');
  writeFileSync(
    file,
    [
      '# 用户 patch',
      '- id: better-sidebar',
      '  name: dsh-better-sidebar',
      '  config:',
      '    agentOpenTools: true',
      '- id: checkup',
      '  name: dsh-checkup',
      '  config:',
      '    lookupTimeoutMs: 5000',
      '- id: ui-theme',
      '  name: "@deepseek-ai/dsh-client-ui-theme"',
      '  config:',
      '    preference: dark',
      '',
    ].join('\n'),
  );

  const next = { ...baseConfig, lookupTimeoutMs: 15000, blockOnWarn: true };
  const result = await writeProfileConfig(file, next);
  const doc = yaml.parse(readFileSync(file, 'utf8'));
  const byId = Object.fromEntries(doc.map((entry) => [entry.id, entry]));

  ok('返回 updated', result === 'updated', result);
  ok('checkup 配置已更新', byId['checkup'].config.lookupTimeoutMs === 15000 && byId['checkup'].config.blockOnWarn === true);
  ok('checkup 的 name 保留', byId['checkup'].name === 'dsh-checkup');
  ok('前后条目未被破坏', byId['better-sidebar'].config.agentOpenTools === true && byId['ui-theme'].config.preference === 'dark');
  ok('条目数仍是 3', doc.length === 3, doc.length);
}

console.log('\n[D] 重复保存幂等');
{
  const file = join(dir, 'patch-idempotent.yml');
  writeFileSync(file, '');
  await writeProfileConfig(file, baseConfig);
  const first = readFileSync(file, 'utf8');
  await writeProfileConfig(file, baseConfig);
  const second = readFileSync(file, 'utf8');
  ok('两次保存结果一致', first === second);
  ok('不会被追加成两条', yaml.parse(second).length === 1, yaml.parse(second).length);
}

rmSync(dir, { recursive: true, force: true });
console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
