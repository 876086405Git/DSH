// Self-authored data validation only. No network or execution on import.
// The Host must enforce navigation policy, task ownership, and approval.
const invalid = () => Object.assign(new Error('浏览器工具参数无效或超过限制。'), { code: 'ERR_IOS_BROWSER_ARGUMENTS' });
const unsupported = () => Object.assign(new Error('不支持此浏览器工具。'), { code: 'ERR_IOS_BROWSER_UNSUPPORTED' });
const keys = (args, allowed) => {
  if (!args || typeof args !== 'object' || Array.isArray(args) || ![Object.prototype, null].includes(Object.getPrototypeOf(args)) || Object.keys(args).some(key => !allowed.includes(key))) throw invalid();
};
const text = (value, max, empty = false) => {
  if (typeof value !== 'string' || (!empty && !value) || value.includes('\0') || Buffer.byteLength(value, 'utf8') > max) throw invalid();
  return value;
};
const epoch = value => {
  if (!Number.isSafeInteger(value) || value < 1) throw invalid();
  return value;
};
const reference = value => {
  const ref = text(value, 8);
  if (!/^e[1-9a-z][0-9a-z]*$/.test(ref)) throw invalid();
  const number = Number.parseInt(ref.slice(1), 36);
  if (number < 1 || number > 256 || `e${number.toString(36)}` !== ref) throw invalid();
  return ref;
};
const option = value => {
  if (typeof value !== 'string' || !/^o[0-9a-z]{1,2}$/.test(value)) throw invalid();
  const number = Number.parseInt(value.slice(1), 36);
  if (number > 63 || `o${number.toString(36)}` !== value) throw invalid();
  return value;
};
export const pressKeys = Object.freeze(['Enter', 'Escape', 'Tab', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'Backspace', 'Delete']);
export function actionFor(name, args = {}) {
  if (typeof name !== 'string') throw unsupported();
  const tool = name.startsWith('mcp__browser__') ? name.slice('mcp__browser__'.length) : name;
  if (tool === 'open') {
    keys(args, ['url']); let url;
    try { url = new URL(text(args.url, 4096)); } catch { throw invalid(); }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw invalid();
    // This is syntactic only: root URL policy/Host must still reject private
    // addresses, redirects, forbidden ports, and unapproved destinations.
    return { kind: 'browser-open', url: url.href };
  }
  if (tool === 'read') {
    keys(args, ['maxBytes']); const maxBytes = args.maxBytes ?? 49152;
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 2048 || maxBytes > 262144) throw invalid();
    return { kind: 'browser-read', maxBytes };
  }
  if (['screenshot', 'back', 'close'].includes(tool)) {
    keys(args, []); return { kind: `browser-${tool}` };
  }
  if (tool === 'handoff') {
    keys(args, ['text']);
    return { kind: 'browser-handoff', ...(args.text === undefined ? {} : { text: text(args.text, 2048, true) }) };
  }
  if (!['click', 'fill', 'select', 'scroll', 'press'].includes(tool)) throw unsupported();
  const field = { fill: 'text', select: 'text', scroll: 'direction', press: 'key' }[tool];
  keys(args, ['ref', 'epoch', ...(field ? [field] : [])]);
  const action = { kind: `browser-${tool}`, ref: reference(args.ref), epoch: epoch(args.epoch) };
  if (tool === 'fill') action.text = text(args.text, 16384, true);
  // The current Swift wire carries a String, so select exactly one opaque option.
  if (tool === 'select') action.text = option(args.text);
  if (tool === 'scroll') {
    if (!['up', 'down', 'left', 'right'].includes(args.direction)) throw invalid();
    action.direction = args.direction;
  }
  if (tool === 'press') {
    if (!pressKeys.includes(args.key)) throw invalid();
    action.key = args.key;
  }
  return action;
}
