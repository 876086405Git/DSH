// Install Guard — 安全性检查（隐私泄露 / 恶意代码 / 病毒特征）
//
// 两条数据来源：
//  1. package.json（注册表可读）：安装脚本、依赖、可追溯性；
//  2. 源码文件（本地路径安装可读；registry 包默认不下载，仅靠 manifest 判断）。
//
// 全部是纯函数：输入 manifest / 文件列表，输出条目。I/O 由调用方负责，
// 这样测试可以直接构造样本，不需要真的去装包。

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
  { re: /\bcertutil\b[^\n]*-urlcache/i, why: 'certutil 下载（Windows 常见载荷投递）' },
  { re: /\b(?:bitsadmin|mshta|regsvr32)\b[^\n]*(?:http|\/i:)/i, why: 'LOLBin 远程加载' },
];

const INSTALL_HOOKS = ['preinstall', 'install', 'postinstall', 'prepare', 'prepublish'];

/// 源码里的隐私读取与数据外传特征。
const SOURCE_RULES = [
  {
    id: 'priv-ssh',
    re: /(?:\.ssh[^\n]{0,40}(?:id_rsa|id_ed25519|authorized_keys|known_hosts)|\.aws[\\/]credentials|\.config[\\/]gcloud)/i,
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
    const distance = levenshtein(localA, localB);
    if (distance > 0 && distance <= 1) out.push(other);
  }
  return out;
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
  }
  return found;
}

/// 扫描源码文本（每条规则命中一次即记录）。
export function scanSourceText(text, fileLabel) {
  const hits = [];
  if (typeof text !== 'string' || !text) return hits;
  for (const rule of SOURCE_RULES) {
    if (rule.re.test(text)) hits.push({ id: rule.id, level: rule.level, why: rule.why, file: fileLabel });
  }
  return hits;
}

/// 安全性检查主体。
export function checkSecurity({ manifest, env, sourceHits }) {
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
    checks.push(pass('sec-deps', '未启用恶意包名单', '配置项 maliciousPackages 为空，跳过该检查。'));
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

  // 4) 源码扫描（本地路径安装才有内容）
  const hits = Array.isArray(sourceHits) ? sourceHits : [];
  const blocking = hits.filter((h) => h.level === 'block');
  const warning = hits.filter((h) => h.level !== 'block');
  if (hits.length === 0) {
    checks.push(pass('sec-source', '源码未命中隐私/恶意特征', '未发现凭据读取、环境变量外传、混淆执行等模式'));
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
