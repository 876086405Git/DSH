// Install Guard — 源码语义扫描（常量折叠 + 文件级污点配对 + 远程代码执行检测）
//
// 为什么不是纯正则：正则只能看见字面量。`String.fromCharCode(46,115,115,104)`、
// `Buffer.from('...','base64')`、`['.s','sh'].join('')` 这类写法把关键字符串拆开，
// 正则一眼看过去什么都没有。
//
// 这里做三件事（**不是完整 AST**，是「词法级常量折叠 + 文件级语义配对」）：
//   1. 折叠：把运行期才拼出来的字符串在扫描时算出来，再交给原来的正则；
//   2. 污点配对：同一文件里既读敏感数据、又有网络出口 → 报警（文件级，不追踪变量）；
//   3. 远程代码执行：抓到远程内容后又 eval / new Function 的，直接判死。
//
// 诚实的边界：运行时才生成的字符串（依赖外部输入）、加密载荷、原生模块里的逻辑，
// 静态扫描一律看不见。这一层能把「脚本小子级」的混淆堵掉，堵不了定向攻击。

const SENSITIVE = /(?:process\.env|os\.homedir\(\)|\.ssh\b|id_rsa|id_ed25519|Login Data|\.aws[\\/]credentials|\.config[\\/]gcloud)/i;
const NET_SINK = /(?:fetch\s*\(|https?\.request|https?\.get\s*\(|\.request\s*\(|\.post\s*\(|require\s*\(\s*["'](?:node:)?https?["']|from\s+["'](?:node:)?https?["']|net\.connect|axios\.|XMLHttpRequest|WebSocket\s*\(|import\s*\(\s*["']https?:)/i;
const DATA_MOVER = /(?:JSON\.stringify|Object\.entries|Object\.keys|homedir\(\)|process\.env|\benv\b)/;
const RCE = /(?:\bnew\s+Function\s*\(|\beval\s*\(|\bvm\.run)/;
const RCE_FEED = /(?:fetch\s*\(|await\s+import\s*\(|require\s*\(\s*["']https?:|Buffer\.from\s*\([^)]*base64|readFileSync)/;

/// 把 `\x41`、`\u0041`、`\u{1F600}` 还原成字符。
function unescapeLiteral(body) {
  return body
    .replace(/\\x([0-9a-fA-F]{2})/g, (_, hex) => String.fromCharCode(Number.parseInt(hex, 16)))
    .replace(/\\u\{([0-9a-fA-F]+)\}/g, (_, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))
    .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(Number.parseInt(hex, 16)));
}

/// `String.fromCharCode(46, 115, ...)` → `"."`, `"s"`, ...
export function foldFromCharCode(text) {
  return text.replace(/String\.fromCharCode\(\s*((?:\d+\s*,\s*)*\d+)\s*\)/g, (match, list) => {
    try {
      const codes = list.split(',').map((part) => Number(part.trim()));
      if (codes.length === 0 || codes.some((n) => !Number.isFinite(n) || n < 0 || n > 0x10ffff)) return match;
      return JSON.stringify(String.fromCharCode(...codes));
    } catch {
      return match;
    }
  });
}

/// `Buffer.from('Li4u','base64')` / `atob('Li4u')` → 解出来的字符串。
export function foldBase64(text) {
  return text.replace(
    /(?:atob|Buffer\.from)\(\s*(["'])([A-Za-z0-9+/=]{8,})\1\s*(?:,\s*["']base64["'])?\s*\)/g,
    (match, quote, payload) => {
      try {
        const decoded = Buffer.from(payload, 'base64').toString('utf8');
        // 只折叠「明显是可读文本」的结果，二进制乱码折了反而干扰匹配
        if (!decoded || /[\u0000-\u0008\u000e-\u001f]/.test(decoded)) return match;
        return JSON.stringify(decoded);
      } catch {
        return match;
      }
    },
  );
}

/// `['.s', 'sh'].join('')` → `".ssh"`
export function foldArrayJoin(text) {
  return text.replace(
    /\[\s*((?:["'][^"']*["']\s*,\s*)+["'][^"']*["'])\s*\]\.join\(\s*["']{2}\s*\)/g,
    (match, list) => {
      const parts = [...list.matchAll(/["']([^"']*)["']/g)].map((m) => m[1]);
      return parts.length ? JSON.stringify(parts.join('')) : match;
    },
  );
}

/// `"a" + "b" + 'c'` → `"abc"`
export function foldConcat(text) {
  const literal = /(["'])((?:\\.|(?!\1)[^\\])*)\1/;
  const chain = new RegExp(`(?:${literal.source}\\s*\\+\\s*)+${literal.source}`, 'g');
  return text.replace(chain, (match) => {
    const parts = [];
    const re = new RegExp(literal.source, 'g');
    let m;
    while ((m = re.exec(match)) !== null) parts.push(m[2]);
    return JSON.stringify(parts.join(''));
  });
}

/// 把字符串字面量里的转义还原（`"\x2e\x73\x73\x68"` → `".ssh"`）。
export function foldEscapes(text) {
  return text.replace(/(["'])((?:\\.|(?!\1)[^\\])*)\1/g, (match, quote, body) => {
    const decoded = unescapeLiteral(body);
    return decoded === body ? match : JSON.stringify(decoded);
  });
}

/// 多轮折叠：后一轮可能出现新的可折叠片段（`["a"+"b"].join("")`）。
export function foldObfuscation(text) {
  let current = String(text == null ? '' : text);
  for (let round = 0; round < 4; round += 1) {
    const next = foldBase64(foldFromCharCode(foldArrayJoin(foldEscapes(current))));
    const settled = foldConcat(next);
    if (settled === current) break;
    current = settled;
  }
  return current;
}

/// 文件级污点配对：同一文件既读敏感数据又发起网络请求（不追踪变量，只看同文件共存）。
export function detectTaint(text) {
  const source = String(text || '');
  if (!SENSITIVE.test(source)) return null;
  if (!NET_SINK.test(source)) return null;
  if (!DATA_MOVER.test(source)) return null;
  return {
    id: 'priv-env-exfil',
    level: 'warn',
    why: '同一文件里既读敏感数据（env / 家目录 / 凭据）又发起网络请求，需人工确认是否外传',
  };
}

/// 远程代码执行：抓到远程内容后又 eval / new Function / vm.run。
export function detectRemoteCode(text) {
  const source = String(text || '');
  if (!RCE.test(source)) return null;
  if (!RCE_FEED.test(source)) return null;
  return {
    id: 'mal-remote-code',
    level: 'block',
    why: '读取远程 / 动态内容后交给 eval / new Function 执行（远程代码执行）',
  };
}
