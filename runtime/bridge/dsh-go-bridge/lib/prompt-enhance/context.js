// dsh-go 提示词增强 · Host 半侧之二：会话上文装配。
//
// 与桌面插件的差别：dsh-go 的上下文由 App 装配（Flutter 内存里只有可见正文，
// 天然不含 runtime-context / time-context / agent-instructions 与 reasoning），
// Host 只负责按同一套上限规则裁剪与标注，不读引擎事件流。

export const MAX_CONTEXT_MESSAGES = 6;
export const MAX_CONTEXT_CHARS = 9000;
export const MAX_CONTEXT_MESSAGE_CHARS = 1200;
export const MAX_LAST_MESSAGE_CHARS = 4000;

const ROLE = { user: '用户', assistant: '助手' };

/** 字符数按码点算，星形字符只算一个。 */
export function charLength(text) {
  return Array.from(String(text == null ? '' : text)).length;
}

/** 从中间省略，保证结果不超过 [max]（含省略号）。 */
function clipMiddle(text, max) {
  const chars = Array.from(text);
  if (chars.length <= max) return text;
  if (max <= 1) return '…';
  const keep = max - 1;
  const head = Math.ceil(keep / 2);
  const tail = keep - head;
  return chars.slice(0, head).join('') + '…' + (tail > 0 ? chars.slice(chars.length - tail).join('') : '');
}

/**
 * 把 App 传来的消息裁成一段上下文块。
 * @param {unknown} messages `[{ role: 'user'|'assistant', text: string, focus?: boolean }]`
 * @returns {{ block: string, used: boolean, messageCount: number, blockChars: number }}
 */
export function buildContextBlock(messages) {
  const list = Array.isArray(messages) ? messages : [];
  const rows = [];
  for (const item of list) {
    if (item === null || typeof item !== 'object') continue;
    const role = item.role === 'user' || item.role === 'assistant' ? item.role : undefined;
    const text = typeof item.text === 'string' ? item.text.trim() : '';
    if (role === undefined || text === '') continue;
    rows.push({ role, text });
  }
  if (rows.length === 0) return { block: '', used: false, messageCount: 0, blockChars: 0 };

  // 只保留最近 MAX_CONTEXT_MESSAGES 条；最后一条是「上一条消息」，额度单独放宽。
  const recent = rows.slice(-MAX_CONTEXT_MESSAGES);
  const lastIndex = recent.length - 1;
  const rendered = recent.map((row, index) => ({
    role: row.role,
    text: clipMiddle(row.text, index === lastIndex ? MAX_LAST_MESSAGE_CHARS : MAX_CONTEXT_MESSAGE_CHARS),
    last: index === lastIndex,
  }));

  // 从最新往回累计到 MAX_CONTEXT_CHARS，再恢复成时间顺序。
  const picked = [];
  let total = 0;
  for (let index = rendered.length - 1; index >= 0; index -= 1) {
    const row = rendered[index];
    const cost = charLength(row.text) + 32;
    if (total + cost > MAX_CONTEXT_CHARS && picked.length > 0) break;
    picked.push(row);
    total += cost;
  }
  picked.reverse();

  const lines = picked.map((row) => {
    const label = row.last
      ? '上一条消息·' + ROLE[row.role] + '（重点）'
      : ROLE[row.role];
    return '【' + label + '】' + row.text;
  });
  const block = lines.join('\n\n');
  return { block, used: true, messageCount: picked.length, blockChars: charLength(block) };
}

/** 导出给测试用。 */
export const __internal = { clipMiddle };
