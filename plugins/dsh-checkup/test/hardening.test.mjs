// 安全加固自检（第 1 轮审计修复的 10 项）
//
// 覆盖能在离线环境验证的部分：
//   #4 连接器命令不存在 → block
//   #10 专家 persona 块标量按缩进解析（三种写法 + 反例）
// 其余（#1 token / #2 Origin / #3 路径白名单 / #5 body 上限）需要活的 HTTP 实例，
// 由 test/hardening-http.mjs 在重启后跑。
import { checkArmory } from '../lib/armory.js';
import { readPersonaLength } from '../lib/index.js';

let failures = 0;
const ok = (label, condition, extra) => {
  if (condition) console.log(`  ok   ${label}`);
  else {
    failures += 1;
    console.log(`  FAIL ${label}${extra === undefined ? '' : ' -> ' + JSON.stringify(extra)}`);
  }
};

const healthy = {
  connectors: [
    { id: 'mcp-a', serverName: 'a', transport: 'stdio', command: 'uvx', commandExists: true },
  ],
  skills: [],
  plugins: [],
  experts: [],
};
const find = (checks, id) => checks.find((c) => c.id === id);

console.log('\n[#4] 连接器命令不存在必须拦');
{
  const base = checkArmory(healthy);
  ok('命令存在 → pass', find(base, 'arm-connector-shape').level === 'pass', find(base, 'arm-connector-shape').level);

  const gone = checkArmory({
    ...healthy,
    connectors: [{ id: 'mcp-a', serverName: 'a', transport: 'stdio', command: 'C:/nope/uvx.exe', commandExists: false }],
  });
  const row = find(gone, 'arm-connector-shape');
  ok('命令不存在 → block', row.level === 'block', row.level);
  ok('标题点明命令不存在', String(row.title).includes('命令'), row.title);
  ok('详情带连接的 serverName', String(row.detail).includes('a'), row.detail);

  // 反向插桩：commandExists 缺失（undefined）时不得误判
  const unknown = checkArmory({
    ...healthy,
    connectors: [{ id: 'mcp-a', serverName: 'a', transport: 'stdio', command: 'uvx' }],
  });
  ok('commandExists 未知时按 pass（不猜）', find(unknown, 'arm-connector-shape').level === 'pass');

  // 非 stdio 的连接器不该因为 commandExists=false 被拦
  const http = checkArmory({
    ...healthy,
    connectors: [{ id: 'mcp-h', serverName: 'h', transport: 'streamable-http', command: '', commandExists: false }],
  });
  ok('http 连接器不看 command', find(http, 'arm-connector-shape').level === 'pass', find(http, 'arm-connector-shape').level);
}

console.log('\n[#10] persona 块标量解析');
{
  const block = [
    '  config:',
    '    persona:',
    '      prefix: |',
    '        你是一位资深架构师。',
    '        工作原则：先读代码再动手。',
    '        注意 note: 这行含冒号，不应截断。',
    '    plugin: dsh-armory',
  ].join('\n');
  const len = readPersonaLength(block);
  ok('块标量能读到正文长度', len > 20, len);
  ok('含冒号的正文行不被截断（长度算进后半段）', len > 40, len);

  const single = '  config:\n    prefix: "短文本"\n';
  ok('单行标量能读', readPersonaLength(single) === 3, readPersonaLength(single));

  const empty = '  config:\n    prefix: |\n';
  ok('空块标量 = 0', readPersonaLength(empty) === 0, readPersonaLength(empty));

  ok('没有 prefix 时 = 0', readPersonaLength('  config:\n    plugin: x\n') === 0);

  // 反向插桩：旧的「下一个 word: 行」正则会在 `Note:` 这行提前截断，
  // 新实现按缩进取块，应把后半段也读进来。
  const trap = [
    '  config:',
    '    prefix: |',
    '      第一行正文',
    '      Note: 这行会让旧正则提前截断',
    '      最后一行也要算进去',
    '    plugin: dsh-armory',
  ].join('\n');
  const newLen = readPersonaLength(trap);
  const oldBody = (() => {
    const m = /prefix:\s*(?:\|[\s\S]{0,4000}?)(?=\n\s{0,8}\w+:)/.exec(trap);
    if (!m) return 0;
    // 去掉 prefix: | 前缀，只算正文
    return m[0].replace(/^[^|]*\|\s*/, '').replace(/\s+/g, '').length;
  })();
  const fullBody = '第一行正文Note这行会让旧正则提前截断最后一行也要算进去'.replace(/\s+/g, '').length;
  ok('新实现读到完整正文', newLen >= fullBody, { newLen, fullBody });
  ok('旧正则会截断（证明插桩有效）', oldBody < newLen, { oldBody, newLen });
}

console.log('\n==============================');
console.log(failures === 0 ? 'ALL PASS' : `${failures} FAILURES`);
process.exit(failures === 0 ? 0 : 1);
