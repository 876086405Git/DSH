// dsh-go 提示词增强 · Host 半侧之三：字数上限与三层执行（约束 / 压缩重写 / 硬截断）。
//
// 公式来自桌面插件 1.5.0：
//   limit = clamp(round(输入字数 × 1.5) + 80, 150, 800)

export const MIN_LIMIT = 150;
export const MAX_LIMIT = 800;
/** 模型输出 token 上限（与插件一致）。 */
export const MAX_OUTPUT_TOKENS = 8192;

/** 字符数（码点），与 App 侧、插件口径一致：含标点与换行。 */
export function charLength(text) {
  return Array.from(String(text == null ? '' : text)).length;
}

/** 本次输出的字符数上限。 */
export function outputLimit(inputChars) {
  const raw = Math.round((Number.isFinite(inputChars) ? inputChars : 0) * 1.5) + 80;
  return Math.min(MAX_LIMIT, Math.max(MIN_LIMIT, raw));
}

/** 一次调用的输出 token 预算：推理过程也占 token，故保底 2048。 */
export function tokenBudget(limit) {
  return Math.min(MAX_OUTPUT_TOKENS, Math.max(2048, Math.ceil(limit * 1.5) + 600));
}

const SENTENCE_END = new Set(['。', '！', '？', '；', '\n', '.', '!', '?', ';']);
const CLAUSE_END = new Set(['，', '、', ',', '：', ':']);

/**
 * 硬截断兜底：按句末优先、其次标点，补省略号，保证结果 ≤ [limit]。
 * @param {string} text
 * @param {number} limit
 * @returns {{ text: string, trimmed: boolean }}
 */
export function hardTrim(text, limit) {
  const value = String(text == null ? '' : text);
  const chars = Array.from(value);
  if (chars.length <= limit) return { text: value, trimmed: false };

  const budget = Math.max(1, limit - 1); // 留一个位置给省略号
  const head = chars.slice(0, budget);

  let cut = -1;
  for (let index = head.length - 1; index >= 0; index -= 1) {
    if (SENTENCE_END.has(head[index])) { cut = index + 1; break; }
  }
  if (cut < 0) {
    for (let index = head.length - 1; index >= 0; index -= 1) {
      if (CLAUSE_END.has(head[index])) { cut = index; break; }
    }
  }
  if (cut <= 0) cut = head.length;

  let out = head.slice(0, cut).join('').trimEnd();
  if (out === '') out = head.join('').trimEnd();
  out = out + '…';
  // 极端情况：句末切点后仍有超长内容时，再按硬长度收一次。
  const outChars = Array.from(out);
  if (outChars.length > limit) out = outChars.slice(0, limit - 1).join('') + '…';
  return { text: out, trimmed: true };
}
