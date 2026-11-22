// Runs assets/islands/island.js for a navigated island (a conversation view,
// a sidebar panel, a settings section, a right pane tab) against a model of
// DSH Web 0.2.1-rc.4's page (node, no DOM library) and prints what the
// island said and did, as JSON. Used by
// test/plugins/islands/island_view_target_test.dart and
// island_names_test.dart.
//
//   node island_page_harness.mjs <island.js> <scenario JSON>
//
// The model follows rc.4's client sources (the runtime rootfs, r12):
//   view      `[data-conversation-tabs]` (role=tablist) of `button[role=tab]`,
//             label in a `span`, no id; the More button (aria-label
//             「更多会话视图」) beside it opens a `role=menu` portal of
//             `button[role=menuitem]` rows. Picking stores the view's id in
//             the conversation's state (`setView`), persisted at once to
//             localStorage `dsh.conversation.<session>`; the
//             `conversation.view` slot draws the view stored there, else Chat.
//   panel     the sidebar's one `nav` (「全局面板」) of rows
//             `button[aria-label=<label>][aria-current=page]`, no id; picking
//             sets the layout's active panel (memory only) and `main` draws
//             it, else the conversation (key "conversation").
//   settings  `[data-shortcut-modal=settings]` with a nav of
//             `button[aria-current=true]`, label in `span`, no id; the
//             `settings.section` slot draws the active one, else the first.
//   rightbar  dockkit panes; a tab body is `[data-sidebar-right-tab=<tabN>]`
//             around the `sidebar.right.pane.tab` slot; the guide tab's
//             entries are `button[data-sidebar-right-guide-entry=<kind>]`;
//             the layout is persisted at once to
//             `dsh.sidebar-right.v1.<session>` (`bySession.<s>.layout`).
//
// Scenario (all):
//   target    'view' | 'panel' | 'settings' | 'rightbar' (default 'view')
//   cell      the id asked for;  names  its names (zh, en)
//   occupants {slot: [{cell, label}]}  what dsh-go-bridge reports (adds the bridge)
//   run       virtual ms to run (default 60000)
// view:      views [{id, label, menu?}], stored, persist (false: a pick is
//            not recorded), rewrites [ms], later {at, view}, pagehide
// panel:     panels [{id, label}], active, sessions [titles] (conversation
//            rows in the sidebar), ignoreClicks
// settings:  sections [{id, label}] (the first shows first), ignoreClicks,
//            sectionButtons [texts] (buttons inside the section drawn),
//            webOpenOk (false: opener reports failure), webOnly (no then step)
// rightbar:  types [{id, kind, title}], open [kind] (tabs already in the
//            pane), split kind (another pane, before ours, showing it),
//            expanded, bridge 'openTab' | 'openTab-fail' (else none),
//            layoutPersist (false: the layout is not written)
//
// Output: {messages, clicks, shown, island, stored, layout, trace}
//   messages  what island.js posted (ready / empty / error), without size / hit
//   clicks    every click on a modelled control
//   shown     what the page draws at the end (view, panel, section, active tab kind)
//   island    what the outlet the island shows draws (its content's model id)
import fs from 'node:fs';
import vm from 'node:vm';

const [islandPath, scenarioJson] = process.argv.slice(2);
const s = JSON.parse(scenarioJson);
const target = s.target || 'view';
const session = s.session || 's1';
const out = { messages: [], clicks: [] };

// ---- a virtual clock --------------------------------------------------------

let now = 1000;
let seq = 0;
const timers = new Map();
function schedule(fn, ms, every) {
  const id = ++seq;
  timers.set(id, { at: now + Math.max(0, +ms || 0), fn, every, id });
  return id;
}
const setTimeoutV = (fn, ms) => schedule(fn, ms, 0);
const setIntervalV = (fn, ms) => schedule(fn, ms, Math.max(1, +ms || 1));
const clearTimer = (id) => { timers.delete(id); };
const later = (fn) => setTimeoutV(fn, 16); // React draws a change a moment later

async function settle() {
  for (let i = 0; i < 4; i++) await new Promise((r) => setImmediate(r));
}

async function runUntil(limit) {
  await settle();
  for (;;) {
    let next = null;
    for (const t of timers.values()) if (!next || t.at < next.at || (t.at === next.at && t.id < next.id)) next = t;
    if (!next || next.at > limit) break;
    now = Math.max(now, next.at);
    if (next.every) next.at = now + next.every;
    else timers.delete(next.id);
    try { next.fn(); } catch (e) { out.thrown = String(e && e.stack || e); }
    await settle();
  }
  now = Math.max(now, limit);
}

// ---- elements ---------------------------------------------------------------

function parseSelector(list) {
  return list.split(',').map((part) => {
    const words = part.trim().split(/\s+/);
    const tests = words.map((word) => {
      const m = /^([a-zA-Z]+|\*)?((?:\[[^\]]+\])*)$/.exec(word);
      if (!m) throw new Error('selector the model does not know: ' + part);
      const tag = m[1] && m[1] !== '*' ? m[1].toUpperCase() : null;
      const attrs = [];
      const re = /\[([\w-]+)(?:([\^~]?)="([^"]*)")?\]/g;
      let a;
      while ((a = re.exec(m[2] || ''))) attrs.push({ name: a[1], op: a[2] || '', value: a[3] });
      return (el) => {
        if (tag && el.tagName !== tag) return false;
        return attrs.every(({ name, op, value }) => {
          const v = el.getAttribute(name);
          if (v === null) return false;
          if (value === undefined) return true;
          if (op === '^') return v.startsWith(value);
          if (op === '~') return v.split(/\s+/).includes(value);
          return v === value;
        });
      };
    });
    // Descendant combinator: the last word matches the element, the others an ancestor each, in order.
    return (el) => {
      if (!tests[tests.length - 1](el)) return false;
      let i = tests.length - 2;
      for (let p = el.parentElement; p && i >= 0; p = p.parentElement) if (tests[i](p)) i--;
      return i < 0;
    };
  });
}

class El {
  constructor(tag, attrs = {}, text = '') {
    this.tagName = tag.toUpperCase();
    this.attrs = { ...attrs };
    this.kids = [];
    this.parentElement = null;
    this.ownText = text;
    this.box = null; // {width, height}
    this.onclick = null;
    this.style = { props: {}, setProperty(k, v) { this.props[k] = v; }, removeProperty(k) { delete this.props[k]; } };
  }
  get children() { return this.kids.slice(); }
  get firstElementChild() { return this.kids[0] || null; }
  get nextElementSibling() {
    const p = this.parentElement;
    return p ? p.kids[p.kids.indexOf(this) + 1] || null : null;
  }
  get isConnected() {
    let e = this;
    while (e.parentElement) e = e.parentElement;
    return e === html;
  }
  get textContent() { return this.ownText + this.kids.map((k) => k.textContent).join(''); }
  set textContent(v) { this.ownText = String(v); this.kids = []; }
  get id() { return this.attrs.id || ''; }
  set id(v) { this.attrs.id = String(v); }
  get className() { return this.attrs.class || ''; }
  getAttribute(n) { return n in this.attrs ? String(this.attrs[n]) : null; }
  setAttribute(n, v) { this.attrs[n] = String(v); }
  hasAttribute(n) { return n in this.attrs; }
  removeAttribute(n) { delete this.attrs[n]; }
  toggleAttribute(n, force) {
    const on = force === undefined ? !(n in this.attrs) : !!force;
    if (on) this.attrs[n] = ''; else delete this.attrs[n];
    return on;
  }
  append(...els) {
    for (const e of els) {
      if (e.parentElement) e.remove();
      e.parentElement = this;
      this.kids.push(e);
    }
    return this;
  }
  appendChild(e) { this.append(e); return e; }
  clear() { for (const k of this.children) k.remove(); }
  remove() {
    const p = this.parentElement;
    if (!p) return;
    p.kids.splice(p.kids.indexOf(this), 1);
    this.parentElement = null;
  }
  contains(o) {
    for (let e = o; e; e = e.parentElement) if (e === this) return true;
    return false;
  }
  descendants() {
    const all = [];
    const walk = (e) => { for (const k of e.kids) { all.push(k); walk(k); } };
    walk(this);
    return all;
  }
  querySelectorAll(selector) {
    if (selector === ':scope > *') return this.children;
    const tests = parseSelector(selector);
    return this.descendants().filter((e) => tests.some((t) => t(e)));
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  matches(selector) { return parseSelector(selector).some((t) => t(this)); }
  closest(selector) {
    for (let e = this; e; e = e.parentElement) if (e.matches(selector)) return e;
    return null;
  }
  getBoundingClientRect() {
    const b = this.isConnected && this.box ? this.box : { width: 0, height: 0 };
    return { left: 0, top: 0, width: b.width, height: b.height, right: b.width, bottom: b.height };
  }
  getClientRects() { return this.isConnected ? [this.getBoundingClientRect()] : []; }
  // A click runs the handlers on the way up, as a bubbling click does.
  click() {
    if (this.clickName) out.clicks.push(this.clickName);
    for (let e = this; e; e = e.parentElement) if (e.onclick) e.onclick();
  }
}

const html = new El('html');
const head = new El('head');
const body = new El('body');
html.append(head, body);

/** A control: a button with [attrs], [label] in a span (an icon before it when [icon]). */
function button(attrs, label, clickName, onclick, icon) {
  const b = new El('button', { type: 'button', ...attrs });
  if (icon) b.append(new El('svg', { 'aria-hidden': 'true' }));
  if (label !== undefined) b.append(new El('span', {}, label));
  b.clickName = clickName;
  b.onclick = onclick;
  return b;
}

/** A slot outlet (display: contents) drawing one box for [model]. */
function outlet(slot) {
  const el = new El('div', { 'data-slot': slot });
  el.display = 'contents';
  return el;
}
function draw(slotEl, model) {
  slotEl.clear();
  const box = new El('div', { class: 'content' });
  box.model = model;
  box.box = { width: 360, height: 640 };
  slotEl.append(box);
  return box;
}

// ---- storage ------------------------------------------------------------------

function storage() {
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => { map.set(k, String(v)); },
    removeItem: (k) => { map.delete(k); },
  };
}
const localStorage = storage();
const sessionStorage = storage();
localStorage.setItem('dsh.sessions.current', JSON.stringify({ sessionId: session }));

// ---- the official page --------------------------------------------------------

const sidebar = new El('aside', { 'data-slot': 'sidebar' });
body.append(sidebar);
const model = { shown: () => null };

const windowExtra = {};

// rc.1 long-tail owners: the footer renders its list directly, settings uses
// aria-controls/selected tabs, plugin details are explicitly package-marked.
if (target === 'footer' || target === 'overlay') {
  const slot = outlet(target === 'footer' ? 'sidebar.footer.action' : 'shell.overlay');
  const box = new El('div');
  (target === 'footer' ? sidebar : body).append(box);
  box.append(slot);
  draw(slot, s.cell);
  model.shown = () => s.cell;
  windowExtra.__dshAppOpen = (web) => { if (web.sidebar) out.clicks.push('open sidebar'); };
}
if (target === 'settings-plugin') {
  let active = 'other';
  let dialog;
  windowExtra.__dshAppOpen = (web) => {
    if (web.settings !== 'plugins' || dialog) return;
    out.clicks.push('open settings:plugins');
    dialog = new El('div', { 'data-shortcut-modal': 'settings', role: 'dialog' });
    const tabs = new El('div', { role: 'tablist' });
    const buttons = [];
    const panels = [];
    function render() {
      for (let i = 0; i < buttons.length; i++) {
        const selected = buttons[i].cell === active;
        buttons[i].setAttribute('aria-selected', String(selected));
        panels[i].toggleAttribute('hidden', !selected);
      }
    }
    for (const id of ['other', s.cell]) {
      const panelId = ':r1:-panel-' + id;
      const b = button({ role: 'tab', id: ':r1:-tab-' + id, 'aria-controls': panelId }, id, 'settings-tab:' + id, () => {
        if (s.ignoreClicks) return;
        active = id;
        later(render);
      });
      b.cell = id;
      buttons.push(b);
      tabs.append(b);
      const panel = new El('div', { id: panelId, role: 'tabpanel' });
      const slot = outlet('settings.plugins.tab');
      panel.append(slot);
      draw(slot, id);
      panels.push(panel);
    }
    dialog.append(tabs, ...panels);
    body.append(dialog);
    render();
  };
  model.shown = () => active;
}
if (target === 'plugin-detail') {
  const main = outlet('main');
  const card = new El('li', { 'data-plugin-package': s.package });
  card.append(button({ 'aria-label': 'View plugin' }, s.package, 'plugin:' + s.package, () => {
    if (s.ignoreClicks) return;
    const detail = new El('div', { 'data-plugin-detail': s.package });
    const slot = outlet('plugins.detail.section');
    detail.append(slot);
    draw(slot, s.cell);
    main.clear();
    main.append(detail);
  }));
  main.append(card);
  body.append(main);
  windowExtra.__dshAppOpen = (web) => { if (web.panel) out.clicks.push('open panel:' + web.panel); };
  model.shown = () => main.querySelector('[data-plugin-detail]') ? s.package : null;
}

if (target === 'view') {
  const key = 'dsh.conversation.' + session;
  const views = s.views || [];
  // The conversation's state: rehydrated from storage at boot, persisted whole on every change.
  let state = { draft: '', view: null, viewRequest: null };
  if (s.stored != null) {
    state = { ...state, view: s.stored };
    localStorage.setItem(key, JSON.stringify(state));
  }
  const persist = () => { if (s.persist !== false) localStorage.setItem(key, JSON.stringify(state)); };
  // resolveActiveView: the stored view when it is registered, else Chat.
  const active = () => (views.find((v) => v.id === state.view) || views.find((v) => v.id === 'chat') || {}).id;

  const conversation = new El('div', { 'data-slot': 'conversation.session' });
  conversation.display = 'contents';
  const header = new El('div', { class: 'header' });
  const tabsRow = new El('div', { class: 'tabs' });
  const row = new El('div', { role: 'tablist', 'data-conversation-tabs': '' });
  const viewArea = new El('div', { class: 'viewArea' });
  const slot = outlet('conversation.view');
  body.append(conversation);
  conversation.append(header, viewArea);
  header.append(tabsRow);
  tabsRow.append(row);
  viewArea.append(slot);

  const selectView = (id) => {
    state = { ...state, view: id };
    persist();
    later(render);
  };
  const tabs = [];
  for (const v of views.filter((x) => !x.menu)) {
    const tab = button({ role: 'tab', 'aria-selected': 'false' }, v.label, 'tab:' + v.id, () => selectView(v.id));
    tab.viewId = v.id;
    tabs.push(tab);
    row.append(tab);
  }
  const overflow = views.filter((x) => x.menu);
  if (overflow.length) {
    const more = button({ 'aria-label': '更多会话视图', 'aria-haspopup': 'menu' }, undefined, 'more', () => {
      if (body.querySelector('[role="menu"]')) return;
      const menu = new El('div', { role: 'menu' });
      for (const v of overflow) {
        const wrap = new El('div', { class: 'itemWrap' });
        const item = new El('button', { type: 'button', role: 'menuitem' });
        const label = new El('span', { class: 'itemLabel' });
        const name = new El('span', { class: 'entryName' });
        name.append(new El('span', { class: 'entryTitle' }, v.label));
        label.append(name);
        item.append(label);
        item.clickName = 'row:' + v.id;
        item.onclick = () => { menu.remove(); selectView(v.id); };
        wrap.append(item);
        menu.append(wrap);
      }
      later(() => body.append(menu));
    });
    more.append(new El('svg', { 'aria-hidden': 'true' }));
    tabsRow.append(more);
  }
  let drawn = null;
  function render() {
    const id = active();
    for (const tab of tabs) tab.setAttribute('aria-selected', String(tab.viewId === id));
    if (id === drawn) return;
    drawn = id;
    draw(slot, id);
  }
  render();
  for (const at of s.rewrites || []) setTimeoutV(persist, at);
  if (s.later) {
    setTimeoutV(() => {
      const saved = JSON.parse(localStorage.getItem(key) || '{}');
      localStorage.setItem(key, JSON.stringify({ ...saved, view: s.later.view }));
    }, s.later.at);
  }
  model.shown = () => drawn;
  model.stored = () => JSON.parse(localStorage.getItem(key) || 'null');
}

if (target === 'panel') {
  let activePanel = s.active ?? null;
  const nav = new El('nav', { 'aria-label': '全局面板' });
  const sessions = new El('div', { class: 'workspaces' });
  sidebar.append(nav, sessions);
  const rows = (s.panels || []).map((p) => {
    const row = button({ 'aria-label': p.label }, p.label, 'panel:' + p.id, () => {
      if (s.ignoreClicks) return;
      activePanel = p.id;
      later(render);
    }, true);
    row.panelId = p.id;
    nav.append(row);
    return row;
  });
  for (const title of s.sessions || []) sessions.append(button({}, title, 'session:' + title, () => {}));
  const slot = outlet('main');
  body.append(slot);
  let drawn = null;
  function render() {
    for (const row of rows) {
      if (row.panelId === activePanel) row.setAttribute('aria-current', 'page');
      else row.removeAttribute('aria-current');
    }
    const id = activePanel ?? 'conversation';
    if (id === drawn) return;
    drawn = id;
    draw(slot, id);
  }
  render();
  model.shown = () => drawn;
}

if (target === 'settings') {
  const sections = s.sections || [];
  let activeId = null;
  let dialog = null;
  let slot = null;
  const navButtons = [];
  function render() {
    for (const b of navButtons) {
      if (b.sectionId === activeId) b.setAttribute('aria-current', 'true');
      else b.removeAttribute('aria-current');
    }
    const id = sections.find((x) => x.id === activeId)?.id ?? sections[0]?.id;
    if (slot.firstElementChild?.model === id) return;
    const box = draw(slot, id);
    // Controls inside the section drawn (a general item's own buttons).
    for (const text of s.sectionButtons || []) box.append(button({}, text, 'in section:' + text, () => {}));
  }
  // The open bridge (dsh_web_open.js) opens settings on a section: the modal comes up a moment later.
  windowExtra.__dshAppOpen = (web) => {
    if (!web.settings || dialog) return;
    out.clicks.push('open settings:' + web.settings);
    activeId = web.settings === true ? sections[0]?.id : web.settings;
    later(() => {
      dialog = new El('div', { 'data-shortcut-modal': 'settings', role: 'dialog', 'aria-modal': 'true' });
      const nav = new El('nav');
      const list = new El('div', { class: 'navList' });
      nav.append(list);
      for (const x of sections) {
        const b = button({}, x.label, 'section:' + x.id, () => {
          if (s.ignoreClicks) return;
          activeId = x.id;
          later(render);
        }, true);
        b.sectionId = x.id;
        navButtons.push(b);
        list.append(b);
      }
      const content = new El('div', { class: 'content' });
      const options = new El('div', { class: 'options' });
      slot = outlet('settings.section');
      options.append(slot);
      content.append(button({}, '关闭', 'close', () => {}, true), options);
      dialog.append(nav, content);
      body.append(dialog);
      render();
    });
  };
  model.shown = () => slot?.firstElementChild?.model ?? null;
}

if (target === 'rightbar') {
  const key = 'dsh.sidebar-right.v1.' + session;
  const types = s.types || [];
  let minted = 0;
  const tab = (kind) => ({ id: 'tab' + ++minted, kind, contentId: 'page:' + kind, title: kind });
  const layout = { nodes: {}, tabs: {}, rootId: 'pane1', floats: [], activePaneId: 'pane1', expanded: !!s.expanded, mode: 'push' };
  const addTab = (paneId, kind) => {
    const t = tab(kind);
    layout.tabs[t.id] = t;
    layout.nodes[paneId].tabs.push(t.id);
    layout.nodes[paneId].activeTabId = t.id;
    return t;
  };
  if (s.split) {
    layout.nodes.pane2 = { kind: 'pane', id: 'pane2', host: 'dock', tabs: [] };
    addTab('pane2', s.split);
  }
  layout.nodes.pane1 = { kind: 'pane', id: 'pane1', host: 'dock', tabs: [] };
  for (const kind of s.open || []) addTab('pane1', kind);
  const persist = () => {
    if (s.layoutPersist === false) return;
    localStorage.setItem(key, JSON.stringify({ bySession: { [session]: { layout, minted: { tab: minted } } } }));
  };
  persist();
  const change = () => { persist(); later(render); };

  const expand = button({ 'aria-label': '打开右侧边栏' }, undefined, 'expand', () => {
    layout.expanded = true;
    // An expansion of an empty column seeds it with the guide.
    if (layout.nodes.pane1.tabs.length === 0) addTab('pane1', 'guide');
    change();
  }, true);
  const rightbar = new El('div', { 'data-slot': 'rightbar' });
  // The conversation the pane belongs to is on screen.
  const conversation = new El('div', { 'data-slot': 'conversation.session' });
  conversation.display = 'contents';
  body.append(conversation, expand, rightbar);

  function guideBody(paneId, tabId) {
    const guide = new El('div', { 'data-sidebar-right-guide': '' });
    guide.box = { width: 360, height: 640 };
    guide.model = 'guide';
    for (const type of types) {
      const entry = button({ 'data-sidebar-right-guide-entry': type.kind }, undefined, 'entry:' + type.kind, () => {
        // Opens that type as a page in the guide tab's place.
        const pane = layout.nodes[paneId];
        delete layout.tabs[tabId];
        pane.tabs = pane.tabs.filter((id) => id !== tabId);
        addTab(paneId, type.kind);
        layout.activePaneId = paneId;
        change();
      });
      const text = new El('span', { class: 'entryText' });
      text.append(new El('span', { class: 'entryTitle' }, type.title));
      entry.append(new El('span', { class: 'entryIcon' }), text);
      guide.append(entry);
    }
    return guide;
  }

  function render() {
    rightbar.clear();
    if (!layout.expanded) return;
    for (const paneId of Object.keys(layout.nodes).sort().reverse()) {
      const pane = layout.nodes[paneId];
      const el = new El('div', { 'data-dockkit-pane': paneId });
      const strip = new El('div', { role: 'tablist' });
      for (const id of pane.tabs) {
        const title = new El('span', { 'data-sidebar-right-tab': id }, layout.tabs[id].title);
        strip.append(title);
      }
      if (paneId === 'pane1') {
        strip.append(button({ 'aria-label': '新标签页' }, undefined, 'new tab', () => {
          addTab('pane1', 'guide');
          layout.activePaneId = 'pane1';
          change();
        }, true));
      }
      el.append(strip);
      const active = pane.activeTabId && layout.tabs[pane.activeTabId];
      if (active) {
        const tabBody = new El('div', { 'data-sidebar-right-tab': active.id });
        const slot = outlet('sidebar.right.pane.tab');
        if (active.kind === 'guide') slot.append(guideBody(paneId, active.id));
        else draw(slot, active.kind);
        tabBody.append(slot);
        el.append(tabBody);
      }
      rightbar.append(el);
    }
  }
  render();

  if (s.bridge === 'openTab' || s.bridge === 'openTab-fail') {
    windowExtra.openTab = async (cell) => {
      out.clicks.push('bridge openTab:' + cell);
      const type = types.find((t) => t.id === cell);
      if (s.bridge === 'openTab-fail' || !type) return { ok: false, reason: 'unknown-tab' };
      const t = addTab('pane1', type.kind);
      layout.activePaneId = 'pane1';
      layout.expanded = true;
      change();
      return { ok: true, id: type.id, kind: type.kind, tabId: t.id };
    };
  }
  model.shown = () => {
    const pane = layout.nodes[layout.activePaneId];
    return pane.activeTabId ? layout.tabs[pane.activeTabId].kind : null;
  };
  model.layout = () => JSON.parse(localStorage.getItem(key) || 'null');
}

// ---- the window ----------------------------------------------------------------

const windowHandlers = {};
const documentHandlers = {};
const document = {
  documentElement: html,
  head,
  body,
  querySelector: (sel) => html.querySelector(sel),
  querySelectorAll: (sel) => html.querySelectorAll(sel),
  getElementById: (id) => html.descendants().find((e) => e.attrs.id === id) || null,
  createElement: (tag) => new El(tag),
  addEventListener: (type, fn) => { (documentHandlers[type] = documentHandlers[type] || []).push(fn); },
};
const window = {
  DshGoIsland: {
    postMessage: (raw) => {
      const msg = JSON.parse(raw);
      if (msg.t !== 'size' && msg.t !== 'hit') out.messages.push(msg);
    },
  },
  addEventListener: (type, fn) => { (windowHandlers[type] = windowHandlers[type] || []).push(fn); },
  innerWidth: 360,
  innerHeight: 760,
  devicePixelRatio: 2,
};
if (windowExtra.__dshAppOpen) {
  window.__dshAppOpen = (web) => {
    windowExtra.__dshAppOpen(web);
    window.__dshAppOpening = Promise.resolve(s.webOpenOk !== false);
  };
}
if (s.occupants || windowExtra.openTab) {
  window.__dshGoBridge = {
    version: 1,
    occupants: (slot) => ((s.occupants && s.occupants[slot]) || []).map((o) => {
      const filters = (out.filters || []).filter((f) => f.slot === slot);
      if (!filters.length) return { ...o }; // Preserve a legacy entry with no masked field.
      return {
        ...o,
        masked: !!o.masked || filters.some((f) => !f.allow.some((a) => a.package === o.package && a.cell === o.cell)),
      };
    }),
    ...(s.filter && s.filter !== 'missing' ? { filter: (slot, allow) => {
      (out.filters ||= []).push({ slot, allow });
      return s.filter === 'ok';
    } } : {}),
    ...(windowExtra.openTab ? { openTab: windowExtra.openTab } : {}),
  };
}
const style = (el) => ({
  display: el.display || 'block',
  visibility: 'visible',
  pointerEvents: 'auto',
  transform: 'none',
  filter: 'none',
  contain: 'none',
  perspective: 'none',
  willChange: 'auto',
  backdropFilter: 'none',
  overflowY: 'visible',
  paddingBottom: '0px',
});
const context = vm.createContext({
  window,
  document,
  localStorage,
  sessionStorage,
  location: { href: 'http://127.0.0.1:3080/?token=t', origin: 'http://127.0.0.1:3080' },
  getComputedStyle: style,
  requestAnimationFrame: (fn) => setTimeoutV(fn, 16),
  setTimeout: setTimeoutV,
  clearTimeout: clearTimer,
  setInterval: setIntervalV,
  clearInterval: clearTimer,
  MutationObserver: class { observe() {} disconnect() {} },
  Date: { now: () => now },
  URL,
});
new vm.Script(fs.readFileSync(islandPath, 'utf8'), { filename: islandPath }).runInContext(context);

const configs = {
  view: { slot: 'conversation.view', stretch: 'child', target: { session, then: { view: { id: s.cell, names: s.names } } } },
  panel: { slot: 'main', stretch: 'child', target: { then: { panel: s.names } } },
  settings: { slot: 'settings.section', stretch: 'scroller', target: { web: { settings: true }, then: { settings: s.names } } },
  rightbar: { slot: 'sidebar.right.pane.tab', stretch: 'child', target: { session, then: { rightbar: s.names } } },
  overlay: { slot: 'shell.overlay', stretch: 'none', mode: 'overlay', target: {} },
  footer: { slot: 'sidebar.footer.action', stretch: 'parent', target: { web: { sidebar: true }, then: { sidebar: true } } },
  'settings-plugin': { slot: 'settings.plugins.tab', stretch: 'parent', target: { web: { settings: 'plugins' }, then: { settingsPlugin: s.cell } } },
  'plugin-detail': { slot: 'plugins.detail.section', stretch: 'scroller', target: { web: { panel: 'plugins' }, then: { plugin: s.package } } },
};
window.__dshGoIsland.init({
  ...configs[target],
  ...(s.webOnly ? { target: { web: { settings: true } } } : {}),
  cell: s.cell,
  mode: target === 'overlay' ? 'overlay' : 'page',
  package: s.package,
  mask: false,
  pad: [16, 12],
  labels: {
    moreViews: ['更多会话视图', 'More conversation views'],
    openRightbar: ['打开右侧边栏', 'Open right sidebar'],
    newTab: ['新标签页', 'New tab'],
  },
  load: 1,
  bootMs: 9000,
  slotMs: 4000,
});
await runUntil(now + (s.run || 60000));
if (s.pagehide) for (const fn of windowHandlers.pagehide || []) fn();

out.shown = model.shown();
const marked = html.descendants().find((e) => (e.getAttribute('data-dsh-go-island') || '').split(' ').includes('shown'));
out.island = marked && marked.firstElementChild ? marked.firstElementChild.model ?? null : null;
if (model.stored) out.stored = model.stored();
if (model.layout) out.layout = model.layout();
out.trace = window.__dshGoIsland.inspect ? window.__dshGoIsland.inspect().trace : [];
process.stdout.write(JSON.stringify(out));
process.exit(0);
