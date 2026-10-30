// Install Guard — 已知漏洞查询（OSV）
//
// 手工名单只能覆盖「作者见过的那几个包」。这里接 OSV（Google 维护的开源漏洞库，
// 聚合 GHSA / CVE / npm advisory），按「包名 + 版本」问一次：这个版本有没有已知漏洞。
//
// 设计取舍：
//   · 默认开启，但**查询失败不阻止安装**（只 warn），否则断网就把插件市场废了；
//   · 按 name@version 缓存 24 小时，同一包重复预检不再打网络；
//   · 判定用「有无已知漏洞」而不是 CVSS 分值：OSV 的 severity 字段各家写法不一，
//     解析不到的按 warn 处理，能解析到 HIGH/CRITICAL 的才 block。

const OSV_URL = 'https://api.osv.dev/v1/query';
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;
const cache = new Map();

const block = (id, title, detail, hint, category = 'security') => ({ id, category, level: 'block', title, detail, hint });
const warn = (id, title, detail, hint, category = 'security') => ({ id, category, level: 'warn', title, detail, hint });
const pass = (id, title, detail, category = 'security') => ({ id, category, level: 'pass', title, detail });

/// 从 OSV 记录里尽力取严重级别（GHSA 用 CRITICAL/HIGH/MODERATE/LOW，CVE 常见 HIGH 等）。
export function severityOf(vuln) {
  const raw = [
    vuln?.database_specific?.severity,
    vuln?.ecosystem_specific?.severity,
    ...(Array.isArray(vuln?.affected) ? vuln.affected.map((row) => row?.database_specific?.severity) : []),
    ...(Array.isArray(vuln?.affected) ? vuln.affected.map((row) => row?.ecosystem_specific?.severity) : []),
  ]
    .map((value) => String(value || '').toUpperCase())
    .find((value) => value === 'CRITICAL' || value === 'HIGH' || value === 'MODERATE' || value === 'MEDIUM' || value === 'LOW');
  if (raw === 'CRITICAL' || raw === 'HIGH') return 'high';
  if (raw === 'MODERATE' || raw === 'MEDIUM' || raw === 'LOW') return 'medium';
  return 'unknown';
}

/// 简化一条 OSV 记录，供报告使用。
export function describeVuln(vuln) {
  return {
    id: String(vuln?.id || ''),
    summary: String(vuln?.summary || vuln?.details || '').slice(0, 200),
    severity: severityOf(vuln),
    aliases: Array.isArray(vuln?.aliases) ? vuln.aliases.slice(0, 5) : [],
  };
}

/**
 * 查询一个包版本在 OSV 里的已知漏洞。
 * @returns {Promise<{vulns: object[], cached?: boolean} | {error: string}>}
 */
export async function queryOsv({ name, version, fetchImpl = fetch, timeoutMs = 6000 }) {
  const packageName = String(name || '').trim();
  const packageVersion = String(version || '').trim();
  if (!packageName || !packageVersion) return { vulns: [] };

  const key = `${packageName}@${packageVersion}`;
  const hit = cache.get(key);
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) return { vulns: hit.vulns, cached: true };

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(OSV_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ package: { name: packageName, ecosystem: 'npm' }, version: packageVersion }),
      signal: controller.signal,
    });
    if (!res.ok) return { error: `HTTP ${res.status}` };
    const doc = await res.json();
    const vulns = Array.isArray(doc?.vulns) ? doc.vulns.map(describeVuln) : [];
    cache.set(key, { vulns, at: Date.now() });
    return { vulns };
  } catch (error) {
    return { error: error?.name === 'AbortError' ? '查询超时' : String(error?.message || error) };
  } finally {
    clearTimeout(timer);
  }
}

/// 纯函数：把查询结果变成一条检查项。
export function checkVulnerabilities({ name, version, vulns, error } = {}) {
  const label = name ? `${name}@${version || '?'}` : '该包';
  if (error) {
    return [
      warn(
        'sec-vulns',
        '漏洞库查询失败（本次未核对）',
        `${label}：${error}`,
        '这不代表安全，只代表没查到；网络恢复后重试。',
      ),
    ];
  }
  const list = Array.isArray(vulns) ? vulns : [];
  if (list.length === 0) {
    return [pass('sec-vulns', '未发现已知漏洞（OSV）', `${label} 在 OSV 里没有对该版本的记录`)];
  }
  const high = list.filter((row) => row.severity === 'high');
  const detail = list
    .slice(0, 8)
    .map((row) => `${row.id}${row.aliases?.length ? `(${row.aliases[0]})` : ''} ${row.summary ? `· ${row.summary}` : ''}`.trim())
    .join('；');
  // 同一个 id 只允许出现一条（面板按 id 分组、逐项调级都靠它唯一）。
  if (high.length > 0) {
    return [
      block(
        'sec-vulns',
        '该版本存在高危已知漏洞',
        `${label} 命中 ${high.length} 条高危（共 ${list.length} 条）：${detail}`,
        '升级到修复版本再安装；无法升级时确认漏洞是否影响你的使用场景。',
      ),
    ];
  }
  return [
    warn(
      'sec-vulns',
      '该版本存在已知漏洞',
      `${label} 命中 ${list.length} 条：${detail}`,
      '多数可升级修复；确认影响面后再装。',
    ),
  ];
}

/// 清空缓存（测试与手动刷新用）。
export function clearOsvCache() {
  cache.clear();
}
