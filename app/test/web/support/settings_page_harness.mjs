// Runs the real assets/web/dsh_web_open.js against the settings page model.
// No DOM library; navigation and label resolution belong to the bridge.
//
//   node settings_page_harness.mjs <bridge.js> <scenario JSON>
//
// DSH Web: sidebar Settings, or Account menu -> Settings; a portal dialog
// [data-shortcut-modal=settings] with nav buttons (labels in spans, no ids).
// Selecting a section updates aria-current and the section content later.
//
// Scenario: open, sections [{id, label, icon?}], entry ('direct' | 'account' | 'none'),
// locale ('zh' | 'en'), opened, active, bootMs, entryMs, menuMs, dialogMs,
// sectionsMs (since boot), selectMs, ignoreClicks, occupants [{cell, label}],
// sectionButtons [labels], outsideButtons [labels], touchAt, touchType,
// reopenAt, reopen, untilMs. Null menuMs/dialogMs means it never renders.
import fs from 'node:fs';
import vm from 'node:vm';

const [bridgePath, scenarioJson] = process.argv.slice(2);
const s = JSON.parse(scenarioJson);
const out = { presses: [], reports: [], doneAt: null, selectorErrors: [] };
let now = 1000;
const t0 = now;
let seq = 0;
const timers = new Map();
function setTimer(fn, ms) {
  const id = ++seq;
  timers.set(id, { id, at: now + Math.max(0, ms || 0), fn });
  return id;
}
const clearTimer = (id) => timers.delete(id);
const elapsed = () => now - t0;

// The same small selector vocabulary as plugins_page_harness.mjs. Unsupported
// selectors are exposed: waitFor in the real bridge otherwise catches them.
function splitOutside(text, sep) {
  const parts = [''];
  let depth = 0;
  for (const ch of text) {
    if (ch === '[') depth++;
    if (ch === ']') depth--;
    if (ch === sep && depth === 0) parts.push('');
    else parts[parts.length - 1] += ch;
  }
  return parts;
}
function parseCompound(text) {
  if (!/^(?:[a-z*]+)?(?:\[[a-z-]+(?:[\^*]?="[^"]*")?\])*$/.test(text)) {
    out.selectorErrors.push(text);
    throw new Error('selector the model does not know: ' + text);
  }
  return {
    tag: (text.match(/^[a-z*]+/i) || ['*'])[0],
    attrs: [...text.matchAll(/\[([a-z-]+)(?:([\^*]?=)"([^"]*)")?\]/gi)]
      .map((m) => ({ name: m[1], op: m[2], value: m[3] })),
  };
}
function matchCompound(el, c) {
  if (c.tag !== '*' && el.tagName !== c.tag.toUpperCase()) return false;
  return c.attrs.every((a) => {
    const v = el.getAttribute(a.name);
    if (v === null) return false;
    if (!a.op) return true;
    if (a.op === '=') return v === a.value;
    if (a.op === '^=') return v.startsWith(a.value);
    return v.includes(a.value);
  });
}
function matchChain(el, chain) {
  if (!matchCompound(el, chain[chain.length - 1])) return false;
  let i = chain.length - 2;
  for (let p = el.parentElement; p && i >= 0; p = p.parentElement) {
    if (matchCompound(p, chain[i])) i--;
  }
  return i < 0;
}
class El {
  constructor(tag, attrs = {}, kids = [], text = '') {
    this.tagName = tag.toUpperCase();
    this.attrs = attrs;
    this.kids = kids;
    this.ownText = text;
    this.parentElement = null;
    this.onClick = null;
    for (const child of kids) child.parentElement = this;
  }
  get children() { return this.kids; }
  get lastElementChild() { return this.kids.at(-1) || null; }
  get textContent() { return this.ownText + this.kids.map((k) => k.textContent).join(''); }
  getAttribute(n) { return n in this.attrs ? String(this.attrs[n]) : null; }
  hasAttribute(n) { return n in this.attrs; }
  get isConnected() {
    let root = this;
    while (root.parentElement) root = root.parentElement;
    return root === pageEl;
  }
  getClientRects() { return this.isConnected ? [{}] : []; }
  click() {
    out.presses.push({ at: elapsed(), name: this.clickName });
    this.onClick?.();
    render();
  }
  descendants() {
    const all = [];
    const walk = (el) => el.kids.forEach((k) => { all.push(k); walk(k); });
    walk(this);
    return all;
  }
  querySelectorAll(selector) {
    const chains = splitOutside(selector, ',')
      .map((part) => splitOutside(part.trim(), ' ').filter(Boolean).map(parseCompound));
    return this.descendants().filter((el) => chains.some((chain) => matchChain(el, chain)));
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}
const button = (label, name, onClick, attrs = {}, icon) => {
  const el = new El('button', attrs, [
    icon === undefined ? new El('svg') : new El('span', { 'aria-hidden': 'true' }, [], icon),
    new El('span', {}, [], label),
  ]);
  el.clickName = name;
  el.onClick = onClick;
  return el;
};

const sections = s.sections || [];
const english = s.locale === 'en';
const settingsName = english ? 'Settings' : '设置';
const accountName = english ? 'Account menu' : '账号菜单';
let activeId = s.active ?? sections[0]?.id ?? 'general';
let dialogRequestedAt = s.opened ? t0 - (s.dialogMs ?? 16) : null;
let menuRequestedAt = null;
let pageEl;
let dialogEl = null;
const readyAfter = (at, ms) => at !== null && ms !== null && now - at >= (ms ?? 16);
const booted = () => elapsed() >= (s.bootMs || 0);
const openDialog = () => { dialogRequestedAt = now; menuRequestedAt = null; };
function settingsDialog() {
  const nav = new El('nav', {}, [new El('div', {},
    elapsed() < (s.sectionsMs || 0) ? [] : sections.map((section) => button(
      section.label,
      'section:' + section.id,
      () => {
        if (s.ignoreClicks) return;
        setTimer(() => { activeId = section.id; render(); }, s.selectMs ?? 16);
      },
      activeId === section.id ? { 'aria-current': 'true' } : {},
      section.icon,
    )),
  )]);
  const content = new El('div', { 'data-slot': 'settings.section' }, [
    new El('h2', {}, [], activeId),
    ...(s.sectionButtons || []).map((label) => button(label, 'in section:' + label, () => {})),
  ]);
  dialogEl ||= new El('div', { 'data-shortcut-modal': 'settings', role: 'dialog' });
  dialogEl.kids = [nav, content];
  for (const child of dialogEl.kids) child.parentElement = dialogEl;
  return dialogEl;
}
function render() {
  const kids = [];
  const sidebarKids = [];
  const entryReady = booted() && elapsed() >= (s.entryMs || 0);
  if (entryReady && (s.entry || 'direct') === 'direct') {
    sidebarKids.push(button(settingsName, 'direct', openDialog, { 'aria-label': settingsName }));
  }
  if (booted()) kids.push(new El('aside', { 'data-slot': 'sidebar' }, sidebarKids));
  if (entryReady && s.entry === 'account') {
    kids.push(button(accountName, 'account', () => { menuRequestedAt = now; }, { 'aria-label': accountName }));
  }
  if (readyAfter(menuRequestedAt, s.menuMs)) {
    kids.push(new El('div', { role: 'menu' }, [button(settingsName, 'menu settings', openDialog, { role: 'menuitem' })]));
  }
  const dialogOpen = readyAfter(dialogRequestedAt, s.dialogMs);
  if (dialogOpen) kids.push(settingsDialog());
  kids.push(new El('main', {}, (s.outsideButtons || []).map((label) => button(label, 'outside:' + label, () => {}))));
  pageEl = new El('html', {}, kids);
  out.dialogOpen = dialogOpen;
  out.current = dialogOpen ? activeId : null;
}

const listeners = {};
const document = {
  querySelector: (selector) => pageEl.querySelector(selector),
  querySelectorAll: (selector) => pageEl.querySelectorAll(selector),
  addEventListener: (type, fn) => { (listeners[type] ||= []).push(fn); },
};
const storage = () => {
  const map = new Map();
  return {
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => map.set(key, String(value)),
    removeItem: (key) => map.delete(key),
  };
};
const window = {
  DshAppOpen: { postMessage: (raw) => out.reports.push({ at: elapsed(), ...JSON.parse(raw) }) },
};
if (s.occupants) {
  window.__dshGoBridge = {
    occupants: (slot) => slot === 'settings.section' ? s.occupants.map((o) => ({ ...o })) : [],
  };
}
const context = vm.createContext({
  window, document, Date: { now: () => now },
  localStorage: storage(), sessionStorage: storage(),
  location: { href: 'http://127.0.0.1:3080/?token=t', replace: () => {} },
  history: { state: null, replaceState: () => {} },
  URL, setTimeout: setTimer, clearTimeout: clearTimer,
});
render();
vm.runInContext(fs.readFileSync(bridgePath, 'utf8'), context, { filename: bridgePath });
function open(target) {
  window.__dshAppOpen(target);
  Promise.resolve(window.__dshAppOpening).then(
    () => { out.doneAt = elapsed(); },
    (error) => { out.thrown = String(error && error.stack || error); },
  );
}
if (s.touchAt != null) {
  setTimer(() => (listeners[s.touchType || 'pointerdown'] || []).forEach((fn) => fn({ isTrusted: true })), s.touchAt);
}
if (s.reopenAt != null) setTimer(() => open(s.reopen), s.reopenAt);
open(s.open);
const until = t0 + (s.untilMs ?? 60000);
for (;;) {
  await new Promise((resolve) => setImmediate(resolve));
  const next = [...timers.values()].sort((a, b) => a.at - b.at || a.id - b.id)[0];
  if (!next || next.at > until) break;
  timers.delete(next.id);
  now = Math.max(now, next.at);
  render();
  try { next.fn(); } catch (error) { out.thrown = String(error && error.stack || error); }
}
await new Promise((resolve) => setImmediate(resolve));
render();
out.pendingTimers = timers.size;
out.endAt = elapsed();
process.stdout.write(JSON.stringify(out));
