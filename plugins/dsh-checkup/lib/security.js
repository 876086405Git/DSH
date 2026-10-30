// Install Guard — 安全性检查（隐私泄露 / 恶意代码 / 病毒特征）
//
// 两条数据来源：
//  1. package.json（注册表可读）：安装脚本、依赖、可追溯性；
//  2. 源码文件（本地路径安装可读；registry 包默认不下载，仅靠 manifest 判断）。
//
// 全部是纯函数：输入 manifest / 文件列表，输出条目。I/O 由调用方负责，
// 这样测试可以直接构造样本，不需要真的去装包。

import { foldConcat, foldObfuscation, detectTaint, detectRemoteCode } from './source-scan.js';

const pass = (id, title, detail, category = 'security') => ({ id, category, level: 'pass', title, detail });
const warn = (id, title, detail, hint, category = 'security') => ({ id, category, level: 'warn', title, detail, hint });
const block = (id, title, detail, hint, category = 'security') => ({ id, category, level: 'block', title, detail, hint });

/// 安装期脚本里的高危命令特征（下载即执行 / 混淆执行 / 提权）。
const DANGEROUS_SCRIPT_PATTERNS = [
  { re: /\bcurl\b[^\n|]*\|\s*(?:ba)?sh\b/i, why: 'curl 管道到 shell（下载即执行）' },
  { re: /\bwget\b[^\n|]*\|\s*(?:ba)?sh\b/i, why: 'wget 管道到 shell（下载即执行）' },
  { re: /powershell(?:\.exe)?[^\n]*(?:-enc|-encodedcommand)\b/i, why: 'PowerShell 编码命令（常被用于隐藏载荷）' },
  { re: /base64\s+(?:-d|--decode)[^\n]*\|\s*(?:ba)?sh\b/i, why: 'base64 解码后交给 shell' },
  { re: /\bnode\s+-e\s+["'][^"']*(?:eval|child_process|require\(["']https?)/i, why: 'node -e 内联执行网络/子进程代码' },
  { re: /\brm\s+-rf\s+\/(?:\s|$)/, why: 'rm -rf /' },
  // 家目录 / 根目录 / 当前目录 / 通配符：`rm -rf /` 之外的实际破坏面
  {
    re: /\brm\s+(?:-[A-Za-z]+\s+)+["']?(?:~|\$HOME|%USERPROFILE%|\/|\*|\.)["']?\s*(?:$|[;&|])/i,
    why: 'rm -rf 指向家目录 / 根目录 / 当前目录（会清空用户数据）',
  },
  // 内联执行：node -e / python -c 里调子进程或动态加载（原正则遇到引号就截断，这里不截）。
  // 只认「子进程 / 动态求值 / 远程加载」这几类实锤写法：`require('./postinstall')` 这种
  // 本地相对 require 是正常构建脚本（core-js 就是这么写的），不能一刀切。
  {
    re: /\b(?:node|nodejs)\s+(?:-e|--eval)\s+[\s\S]{0,300}?(?:child_process|execSync|execFileSync|spawn\s*\(|fork\s*\(|\beval\s*\(|new\s+Function|require\s*\(\s*["']https?:)/i,
    why: 'node -e 内联执行子进程 / 动态求值 / 远程加载',
  },
  {
    re: /\b(?:python3?|py)\s+-c\s+[\s\S]{0,300}?(?:subprocess|os\.system|eval\s*\(|exec\s*\()/i,
    why: 'python -c 内联执行系统命令',
  },
  { re: /\bcertutil\b[^\n]*-urlcache/i, why: 'certutil 下载（Windows 常见载荷投递）' },
  { re: /\b(?:bitsadmin|mshta|regsvr32)\b[^\n]*(?:http|\/i:)/i, why: 'LOLBin 远程加载' },
];

const INSTALL_HOOKS = ['preinstall', 'install', 'postinstall', 'prepare', 'prepublish'];

/// 源码里的隐私读取与数据外传特征。
const SOURCE_RULES = [
  {
    id: 'priv-ssh',
    // 不再要求「.ssh 与 id_rsa 相距 40 字符内」：那个窗口让 `".ssh"` 与后续 `"id_rsa"` 分开写就绕过。
    // 分开成两个强特征：凭据目录 / 私钥文件名本身。
    re: /\.ssh\b|\.aws[\\/]credentials|\.config[\\/]gcloud|\bid_(?:rsa|ed25519)\b|authorized_keys/i,
    why: '读取 SSH 私钥 / 云厂商凭据',
    level: 'block',
  },
  {
    id: 'priv-browser',
    re: /(?:Login Data|Cookies|Local State)[^\n]{0,40}(?:sqlite|leveldb|copyFile|readFile)/i,
    why: '读取浏览器 Cookie / 密码库',
    level: 'block',
  },
  {
    id: 'priv-env-exfil',
    re: /(?:process\.env|os\.environ)[^\n]{0,120}(?:fetch|axios|https?\.request|requests\.post|WebSocket)|(?:fetch|axios|https?\.request|requests\.post)[^\n]{0,120}(?:process\.env|os\.environ)/i,
    why: '把环境变量发往网络',
    level: 'block',
  },
  {
    id: 'mal-eval-b64',
    re: /eval\s*\(\s*(?:Buffer\.from|atob|Buffer\.from\([^)]*,\s*['"]base64)/i,
    why: 'base64 解码后 eval（典型混淆载荷）',
    level: 'block',
  },
  {
    id: 'mal-download-exec',
    re: /(?:child_process|execSync|execFileSync)[^\n]{0,120}(?:curl|wget|Invoke-WebRequest|DownloadString)/i,
    why: '子进程下载并执行远程内容',
    level: 'block',
  },
  {
    id: 'mal-spawn-shell',
    re: /spawn\s*\(\s*['"](?:cmd|powershell|bash|sh)['"]\s*,\s*\[[^\]]*(?:\/c|\/k|-c|-Command)/i,
    why: '以 shell 解释器执行拼接命令',
    level: 'warn',
  },
];

/// 与已装包名高度相似的包（typosquatting / 抢注）。
function levenshtein(a, b) {
  const m = a.length;
  const n = b.length;
  if (m === 0) return n;
  if (n === 0) return m;
  let prev = Array.from({ length: n + 1 }, (_, i) => i);
  for (let i = 1; i <= m; i += 1) {
    const cur = [i];
    for (let j = 1; j <= n; j += 1) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    }
    prev = cur;
  }
  return prev[n];
}

/// 判断「差一个字符」属于哪一类。抢注/仿冒的典型手法是增删字符、调换顺序、同形替换；
/// 单纯把某个字母换成另一个字母（cad → cat）通常是两个不同的正常包，不该报。
const HOMOGLYPHS = new Set(['0o', 'o0', '1l', 'l1', '1i', 'i1', '3e', 'e3', '4a', 'a4', '5s', 's5', '7t', 't7', 'rn-m', 'vv-w']);

function typoClass(a, b) {
  if (Math.abs(a.length - b.length) === 1) return 'insert-delete';
  if (a.length !== b.length) return 'far';
  const diff = [];
  for (let i = 0; i < a.length; i += 1) if (a[i] !== b[i]) diff.push(i);
  if (diff.length !== 1) return 'far';
  const i = diff[0];
  // 相邻两字符互换：dsh-armsory / dsh-armory
  if (a[i] === b[i + 1] && a[i + 1] === b[i]) return 'transpose';
  const pair = `${a[i]}${b[i]}`;
  if (HOMOGLYPHS.has(pair)) return 'homoglyph';
  // m / rn、w / vv 这类多字符同形
  if ((a[i] === 'm' || b[i] === 'm') && /rn|vv/.test(`${a[i]}${a[i + 1] || ''}${b[i]}${b[i + 1] || ''}`)) return 'homoglyph';
  return 'substitute';
}

export function findLookalikes(name, installedNames = []) {
  if (typeof name !== 'string' || !name.includes('/') === false) {
    // scoped 包也照常比较，这里不做特殊处理
  }
  const base = String(name || '').toLowerCase();
  if (!base) return [];
  const out = [];
  for (const other of installedNames) {
    const candidate = String(other || '').toLowerCase();
    if (!candidate || candidate === base) continue;
    // 只比较同名段：`@scope/a` 与 `a` 视为不同命名空间，避免噪音
    const localA = base.split('/').pop();
    const localB = candidate.split('/').pop();
    if (!localA || !localB) continue;
    // 太短的末段（cad / cat、ui / ux）差一个字符是正常命名，不是仿冒；
    // 真正有意义的抢注信号出现在有辨识度的名字上（≥6 字符）。
    if (Math.min(localA.length, localB.length) < 6) continue;
    const distance = levenshtein(localA, localB);
    if (distance !== 1) continue;
    // 只把「增删 / 换序 / 同形替换」当仿冒；单纯换字母通常是另一个正常包。
    const kind = typoClass(localA, localB);
    if (kind === 'far' || kind === 'substitute') continue;
    out.push(other);
  }
  return out;
}

/// 「先下载到文件，再执行」的两步式载荷：管道形态的正则抓不到它。
/// 判据：命令里出现 curl/wget 写文件，且同一个命令串里又执行了那个文件（或给过 +x）。
function detectTwoStepDownload(command) {
  const target = /(?:curl|wget)\b[^\n]*?(?:-o|-O|--output|--output-document)\s+["']?([^\s"';|&]+)["']?/i.exec(command);
  if (!target) return '';
  const file = String(target[1]).replace(/^\.\//, '');
  const base = file.split(/[\\/]/).pop();
  if (!base) return '';
  const escaped = base.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // 执行点必须出现在分隔符之后（`;`、`&&`、`|`、行首），避免把 `-o x.sh` 本身当成执行。
  const execRe = new RegExp(
    `(?:^|[;&|(]\\s*)(?:\\./|bash\\s+|sh\\s+|zsh\\s+|node\\s+|python3?\\s+|pwsh\\s+|powershell(?:\\s+-\\w+)*\\s+)?["']?${escaped}["']?`,
    'i',
  );
  if (execRe.test(command)) return `先下载 ${base} 再执行`;
  if (/chmod\s+\+x/i.test(command)) return `先下载 ${base} 再赋可执行权限`;
  return '';
}

/// 扫描 package.json 的安装脚本。
export function scanInstallScripts(manifest) {
  const scripts = manifest && manifest.scripts && typeof manifest.scripts === 'object' ? manifest.scripts : {};
  const found = [];
  for (const hook of INSTALL_HOOKS) {
    const command = scripts[hook];
    if (typeof command !== 'string' || !command.trim()) continue;
    for (const rule of DANGEROUS_SCRIPT_PATTERNS) {
      if (rule.re.test(command)) {
        found.push({ hook, command: command.slice(0, 200), why: rule.why });
        break;
      }
    }
    const twoStep = detectTwoStepDownload(command);
    if (twoStep) found.push({ hook, command: command.slice(0, 200), why: twoStep });
  }
  return found;
}

/// 把相邻字符串字面量拼接折叠成一段：`"." + "s" + "sh"` → `".ssh"`。
/// 实现在 source-scan.js（那里还做了 Base64 / fromCharCode / join / 转义还原）。
export const collapseStringConcats = foldConcat;

/// 扫描源码文本：原文与折叠后的变体各跑一遍正则，再补上文件级语义检测。
export function scanSourceText(text, fileLabel) {
  if (typeof text !== 'string' || !text) return [];
  const folded = foldObfuscation(text);
  const variants = folded === text ? [text] : [text, folded];

  const hits = new Map();
  for (const rule of SOURCE_RULES) {
    if (!variants.some((v) => rule.re.test(v))) continue;
    hits.set(rule.id, { id: rule.id, level: rule.level, why: rule.why, file: fileLabel });
  }

  // 语义层：常量折叠解决不了的部分（同一文件既有敏感读又有网络出口 / 远程内容动态执行）
  const taint = detectTaint(folded);
  if (taint && !hits.has(taint.id)) hits.set(taint.id, { ...taint, file: fileLabel });
  const rce = detectRemoteCode(folded);
  if (rce) hits.set(rce.id, { ...rce, file: fileLabel });

  const list = [...hits.values()];

  // 规则表 / 恶意样本文件：同一个文件里命中 ≥3 条不同特征时，本插件自己的 lib/security.js
  // （里面就是这些正则的原文）会被自己判死。降级为提醒，既不假绿也不误杀。
  const blocks = list.filter((hit) => hit.level === 'block');
  if (blocks.length >= 3) {
    for (const hit of blocks) {
      hit.level = 'warn';
      hit.why = `${hit.why}（同一文件命中多条特征，疑似规则表 / 恶意样本文件，降级为提醒）`;
    }
  }
  return list;
}

/// 安全性检查主体。
export function checkSecurity({ manifest, env, sourceHits, sourceScanned }) {
  const checks = [];
  if (!manifest || typeof manifest !== 'object') {
    checks.push(pass('sec-manifest', '未取得包元数据', '无法扫描安装脚本与依赖，本次只做运行期检查。'));
    return checks;
  }

  const label = `${manifest.name || '?'}@${manifest.version || '?'}`;

  // 1) 安装脚本里的高危命令
  const scriptHits = scanInstallScripts(manifest);
  if (scriptHits.length === 0) {
    const hooks = Object.keys(manifest.scripts || {}).filter((k) => INSTALL_HOOKS.includes(k));
    checks.push(
      pass(
        'sec-scripts',
        '安装脚本无高危命令',
        hooks.length ? `存在安装钩子（${hooks.join(', ')}），未命中下载即执行 / 编码执行等特征` : '未声明安装期钩子',
      ),
    );
  } else {
    checks.push(
      block(
        'sec-scripts',
        '安装脚本包含高危命令',
        scriptHits.map((h) => `${h.hook}: ${h.command}（${h.why}）`).join('；'),
        '不要在来源不明时安装；确认作者意图后再放行。',
        'security',
      ),
    );
  }

  // 2) 依赖里是否有已知恶意包
  const malicious = Array.isArray(env?.maliciousPackages) ? env.maliciousPackages : [];
  const deps = { ...(manifest.dependencies || {}), ...(manifest.optionalDependencies || {}) };
  const depNames = Object.keys(deps);
  const maliciousHits = depNames.filter((name) => malicious.some((bad) => bad === name || name.startsWith(`${bad}/`)));
  if (malicious.length === 0) {
    // 空名单时这条根本没有比对过任何依赖，不能显示成绿色的「通过」。
    checks.push(
      warn(
        'sec-deps',
        '未启用恶意依赖名单',
        '配置项 maliciousPackages 为空，本项没有比对过任何依赖',
        '在体检中心填一份名单后本项才会真正生效。',
        'security',
      ),
    );
  } else if (maliciousHits.length === 0) {
    checks.push(pass('sec-deps', '依赖未命中恶意包名单', `${depNames.length} 个依赖已比对 ${malicious.length} 条名单`));
  } else {
    checks.push(
      block('sec-deps', '依赖命中恶意包名单', maliciousHits.join(', '), '不要安装；向作者与仓库反馈。', 'security'),
    );
  }

  // 3) typosquatting
  const lookalikes = findLookalikes(manifest.name, env?.installedNames || []);
  if (lookalikes.length === 0) {
    checks.push(pass('sec-typosquat', '包名与已装插件无混淆嫌疑', '未发现仅差一个字符的同名段'));
  } else {
    checks.push(
      warn(
        'sec-typosquat',
        '包名与已装插件高度相似',
        `与 ${lookalikes.slice(0, 5).join(', ')} 仅差 1 个字符，存在抢注/仿冒风险`,
        '核对作者与仓库地址后再安装。',
        'security',
      ),
    );
  }

  // 4) 源码扫描（只有本地路径安装才有内容）
  const hits = Array.isArray(sourceHits) ? sourceHits : [];
  const blocking = hits.filter((h) => h.level === 'block');
  const warning = hits.filter((h) => h.level !== 'block');
  if (hits.length === 0) {
    if (sourceScanned === false) {
      // registry 安装不下载包体，一个文件都没读过 —— 不能显示成「未命中」的绿灯。
      checks.push(
        warn(
          'sec-source',
          '未扫描源码（registry 安装不含包体）',
          'registry 只返回 package.json，本次没有任何源码被扫描',
          '需要源码级检查时改用本地目录安装；或装完再对 node_modules/<包名> 跑一次检查。',
          'security',
        ),
      );
    } else {
      checks.push(pass('sec-source', '源码未命中隐私/恶意特征', '已扫描源码，未发现凭据读取、环境变量外传、混淆执行等模式'));
    }
  } else if (blocking.length > 0) {
    checks.push(
      block(
        'sec-source',
        '源码命中隐私泄露或恶意代码特征',
        blocking.map((h) => `${h.file}: ${h.why}`).join('；'),
        '立即停止安装，检查该文件内容。',
        'security',
      ),
    );
  } else {
    checks.push(
      warn(
        'sec-source',
        '源码命中可疑特征（需人工确认）',
        warning.map((h) => `${h.file}: ${h.why}`).join('；'),
        '确认这些调用只用于合法用途。',
        'security',
      ),
    );
  }

  // 5) 可追溯性（隐私/恶意代码的追责基础）
  const repository = manifest.repository;
  const repoUrl = typeof repository === 'string' ? repository : repository && repository.url;
  const hasAuthor = Boolean(manifest.author);
  if (repoUrl && hasAuthor) {
    checks.push(pass('sec-traceability', '来源可追溯', `${repoUrl}`));
  } else {
    checks.push(
      warn(
        'sec-traceability',
        '来源信息不完整',
        `缺少 ${[repoUrl ? null : 'repository', hasAuthor ? null : 'author'].filter(Boolean).join(' / ')}，出问题时无法追责`,
        '优先选择提供仓库地址与作者的插件。',
        'security',
      ),
    );
  }

  return checks;
}
