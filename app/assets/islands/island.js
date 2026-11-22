// dsh-go web island runtime (docs/design/plugin-seams.md §6). Injected by the
// app's IslandHandle after every load, right after the read-only
// `assets/web/dsh_web_open.js` (its __dshAppOpen does the session hop and the
// settings / panel / right-sidebar clicks). Idempotent per document.
//
//   window.__dshGoIsland.init(cfg)     once per load: navigate, find the slot,
//                                      hide everything else, report `ready`
//   window.__dshGoIsland.setTheme(t)   App light/dark, accent, tokens
//   window.__dshGoIsland.setInsets(i)  {top, bottom} CSS px the frame keeps clear
//
// Messages go to the app's `DshGoIsland` channel as JSON, `t` is the type:
//   ready {slot, cell, release, found}     empty / error {slot, code, detail}
//   size {h}     hit {rects, dpr}     link {url}     session {id}
//
// Only marks official nodes with data-dsh-go-island attributes (island.css
// reacts to them) and clicks official controls; never removes, moves or
// restyles them otherwise. The channel is visible to every frame on the page:
// the app treats whatever arrives as untrusted.
(function () {
  if (window.__dshGoIsland) return;

  var CHANNEL = 'DshGoIsland';
  var MARK = 'data-dsh-go-island';
  var FORM = 'data-dsh-go-island-form';

  var st = {
    cfg: null,
    phase: 'idle', // idle → opening → waiting → ready | failed
    slotEl: null,
    frame: null,
    marked: [],
    baseline: null, // <body> children before ready: never shown as layers
    theme: null,
    insets: { top: 0, bottom: 0 },
    lastSize: -1,
    lastHit: '',
    hitTimer: 0,
    hitAt: 0,
    sizeQueued: false,
    reapplyQueued: false,
    darkGuard: 0,
    touchedAt: 0,
  };

  // What happened on the way to ready (inspect().trace): a failed island
  // says which step missed.
  var t0 = Date.now();
  var trace = [];
  function step(name) {
    if (trace.length < 40) trace.push((Date.now() - t0) + ' ' + name);
  }

  // The last ready / empty / error this page said: said again under a newer
  // load id when the app injects into the same document twice.
  var terminal = null;

  function post(msg) {
    // A page on its way out (a hop's reload) has nothing more to say.
    if (st.leaving) return;
    if (msg && (msg.t === 'ready' || msg.t === 'empty' || msg.t === 'error')) terminal = msg;
    if (msg && msg.t !== 'size' && msg.t !== 'hit') {
      step('post ' + msg.t + (msg.code ? ' ' + msg.code : '') + (msg.detail ? ' ' + String(msg.detail).slice(0, 80) : ''));
    }
    // Which load of the page this is (the app drops what a page it already
    // navigated away from still says).
    if (msg && st.cfg && st.cfg.load != null) msg.load = st.cfg.load;
    try {
      if (window[CHANNEL]) window[CHANNEL].postMessage(JSON.stringify(msg));
    } catch (e) {}
  }

  function sleep(ms) {
    return new Promise(function (r) { setTimeout(r, ms); });
  }

  // The next frame, or 50 ms when the page draws no frames (a WebView that
  // is laid out but not on screen yet).
  function nextFrame(fn) {
    var done = false;
    var run = function () { if (!done) { done = true; fn(); } };
    requestAnimationFrame(run);
    setTimeout(run, 50);
  }

  function waitFor(find, ms) {
    var until = Date.now() + (ms || 8000);
    return new Promise(function (resolve) {
      (function tick() {
        var el = null;
        try { el = find(); } catch (e) {}
        if (el) return resolve(el);
        if (Date.now() > until) return resolve(null);
        setTimeout(tick, 120);
      })();
    });
  }

  function text(el) {
    return (el.textContent || '').replace(/\s+/g, ' ').trim();
  }

  // What a control goes by: its aria-label, own text, or a leaf's text.
  function namesOf(n) {
    var names = [n.getAttribute('aria-label') || '', text(n)];
    var leaves = n.querySelectorAll('*');
    for (var l = 0; l < leaves.length; l++) {
      if (!leaves[l].children.length) names.push(text(leaves[l]));
    }
    return names;
  }

  // Same matching as dsh_web_open.js: a name equal to a label, or starting
  // with it and a space.
  function byName(root, selector, labels) {
    if (!root || !labels || !labels.length) return null;
    var nodes = root.querySelectorAll(selector);
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var names = namesOf(n);
      for (var j = 0; j < labels.length; j++) {
        for (var k = 0; k < names.length; k++) {
          var name = names[k];
          if (name === labels[j] || name.indexOf(labels[j] + ' ') === 0) return n;
        }
      }
    }
    return null;
  }

  // Every control under [root] that goes by exactly one of [labels] (a
  // longer name starting with one is another control). A match inside
  // another (a menu row and its button) is the same control: the innermost
  // one counts, a click on it reaches both.
  function allByExactName(root, selector, labels) {
    var hits = [];
    if (!root || !labels || !labels.length) return hits;
    var nodes = root.querySelectorAll(selector);
    for (var i = 0; i < nodes.length; i++) {
      var names = namesOf(nodes[i]);
      for (var k = 0; k < names.length; k++) {
        if (labels.indexOf(names[k]) >= 0) {
          hits.push(nodes[i]);
          break;
        }
      }
    }
    return hits.filter(function (n) {
      return !hits.some(function (o) { return o !== n && within(o, n); });
    });
  }

  function within(el, ancestor) {
    for (var p = el.parentElement; p; p = p.parentElement) {
      if (p === ancestor) return true;
    }
    return false;
  }

  // The one control under [root] by exactly one of [names], waiting up to
  // [ms] for it: null when there is none, 'two' when more than one goes by
  // the name (which is which can't be told).
  async function onlyByName(root, selector, names, ms) {
    var found = await waitFor(function () {
      var hits = allByExactName(typeof root === 'function' ? root() : root, selector, names);
      return hits.length ? hits : null;
    }, ms);
    if (!found) return null;
    return found.length > 1 ? 'two' : found[0];
  }

  // Whether dsh-go-bridge reports another entry of [slot] than this
  // island's cell under one of [names]: a name that doesn't tell the two
  // apart, even when only one of them is drawn. Without the bridge (or its
  // labels) only the controls on the page are compared.
  function namedElsewhere(slot, names) {
    var bridge = window.__dshGoBridge;
    var cell = st.cfg && st.cfg.cell;
    if (!bridge || !bridge.occupants || !cell) return false;
    try {
      return bridge.occupants(slot).some(function (o) {
        return o && o.cell !== cell && typeof o.label === 'string' &&
          names.indexOf(o.label.replace(/\s+/g, ' ').trim()) >= 0;
      });
    } catch (e) {
      return false;
    }
  }

  // aria-current set, and not "false": the page says this control is where it is.
  function isCurrent(el) {
    var v = el.getAttribute('aria-current');
    return v !== null && v !== 'false';
  }

  // The first box an outlet draws (what changes when another entry is drawn there).
  function drawnIn(slot) {
    var slotEl = findSlot(slot);
    return slotEl ? firstBoxChild(slotEl) : null;
  }

  function hit(what, how) {
    step(what + ' ' + how);
    return true;
  }

  function miss(what, why) {
    step(what + ' miss: ' + why);
    return false;
  }

  function cssEscape(v) {
    return window.CSS && CSS.escape ? CSS.escape(v) : String(v).replace(/["\\]/g, '\\$&');
  }

  function release() {
    try { return (window.__DSH_BOOT__ && window.__DSH_BOOT__.release && window.__DSH_BOOT__.release.version) || null; } catch (e) { return null; }
  }

  // ---- marks ---------------------------------------------------------------

  function addMark(el, word) {
    var v = el.getAttribute(MARK) || '';
    var words = v ? v.split(' ') : [];
    if (words.indexOf(word) < 0) {
      words.push(word);
      el.setAttribute(MARK, words.join(' '));
      st.marked.push(el);
    }
  }

  function clearMarks() {
    var html = document.documentElement;
    var all = document.querySelectorAll('[' + MARK + ']');
    for (var i = 0; i < all.length; i++) {
      if (all[i] !== html) all[i].removeAttribute(MARK);
    }
    st.marked = [];
  }

  // ---- finding the slot ----------------------------------------------------

  // An outlet with something on screen: an element child with a box, looking
  // through nested display: contents wrappers.
  function rendered(el, depth) {
    if (!el || depth > 4) return false;
    for (var c = el.firstElementChild; c; c = c.nextElementSibling) {
      if (getComputedStyle(c).display === 'contents') {
        if (rendered(c, depth + 1)) return true;
      } else {
        var r = c.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) return true;
      }
    }
    return false;
  }

  function entries(el) {
    var n = 0;
    for (var c = el.firstElementChild; c; c = c.nextElementSibling) n++;
    return n;
  }

  function outlets(slot) {
    return Array.prototype.slice.call(document.querySelectorAll('[data-slot="' + cssEscape(slot) + '"]'));
  }

  function findSlot(slot) {
    var all = outlets(slot);
    for (var i = 0; i < all.length; i++) {
      if (ownTab(all[i], slot) && rendered(all[i], 0)) return all[i];
    }
    return null;
  }

  // rc.4's right pane draws every open tab (in every split pane) through the
  // one `sidebar.right.pane.tab` slot, each inside its tab's body
  // (`data-sidebar-right-tab="<tab id>"`): once the tab this island opened is
  // known, only the outlet in that tab is its own.
  var RIGHT_TAB = 'data-sidebar-right-tab';

  function ownTab(outlet, slot) {
    if (slot === 'settings.plugins.tab' && st.settingsPanel) {
      var panel = document.getElementById(st.settingsPanel);
      return !!panel && !panel.hasAttribute('hidden') && panel.contains(outlet);
    }
    if (slot !== 'sidebar.right.pane.tab' || !st.tabShown || !document.querySelector('[' + RIGHT_TAB + ']')) return true;
    for (var p = outlet.parentElement; p; p = p.parentElement) {
      var id = p.getAttribute && p.getAttribute(RIGHT_TAB);
      if (id !== null && id !== undefined) return id === st.tabShown;
    }
    return false;
  }

  // An island of several slots (`slots`, stretch 'common': the chat page's
  // 「插件」 sheet) shows every one of them that has something on screen.
  function slotsOf(cfg) {
    return cfg && cfg.slots && cfg.slots.length ? cfg.slots : [cfg.slot];
  }

  function findSlots(cfg) {
    var found = [];
    var keys = slotsOf(cfg);
    for (var i = 0; i < keys.length; i++) {
      var el = findSlot(keys[i]);
      if (el) found.push(el);
    }
    return found;
  }

  function findAny(cfg) {
    return findSlots(cfg)[0] || null;
  }

  // The nearest box holding all of [els].
  function commonFrame(els) {
    var chain = [];
    for (var p = els[0]; p && p !== document.body; p = p.parentElement) chain.push(p);
    var at = 0;
    for (var i = 1; i < els.length; i++) {
      var hit = -1;
      for (var q = els[i]; q && q !== document.body && hit < 0; q = q.parentElement) hit = chain.indexOf(q);
      if (hit < 0) return null;
      at = Math.max(at, hit);
    }
    var frame = chain[at];
    while (frame && frame !== document.body && getComputedStyle(frame).display === 'contents') frame = frame.parentElement;
    return frame && frame !== document.body ? frame : null;
  }

  function scrollable(el) {
    var cs = getComputedStyle(el);
    return /(auto|scroll|overlay)/.test(cs.overflowY) && el.clientHeight > 0;
  }

  // Nearest ancestor that lays out boxes (the outlet is display: contents).
  function boxParent(el) {
    var p = el.parentElement;
    while (p && p !== document.body && getComputedStyle(p).display === 'contents') p = p.parentElement;
    return p;
  }

  function firstBoxChild(el) {
    for (var c = el.firstElementChild; c; c = c.nextElementSibling) {
      if (getComputedStyle(c).display === 'contents') {
        var inner = firstBoxChild(c);
        if (inner) return inner;
      } else {
        return c;
      }
    }
    return null;
  }

  function frameFor(slotEl, stretch) {
    if (stretch === 'none') return null;
    if (stretch === 'child') return firstBoxChild(slotEl);
    if (stretch === 'parent') return boxParent(slotEl);
    // 'scroller': the nearest scrolling ancestor, else the box parent.
    for (var p = slotEl.parentElement; p && p !== document.body; p = p.parentElement) {
      if (scrollable(p)) return p;
    }
    return boxParent(slotEl);
  }

  // Marks the frame, the wrappers between it and the outlet, their siblings
  // (out of the layout) and the frame's ancestors (no transforms).
  function mark(slotEl, frame) {
    clearMarks();
    addMark(slotEl, 'shown');
    if (!frame) return;
    addMark(frame, 'frame');
    // An official container (not the plugin's own root) lays the slot out
    // as a plain block: a centring flex row would shrink and shift it.
    if (!slotEl.contains(frame)) addMark(frame, 'block');
    if (frame.contains(slotEl) && frame !== slotEl) {
      var path = [];
      for (var p = slotEl; p && p !== frame; p = p.parentElement) path.push(p);
      for (var i = 0; i < path.length; i++) {
        var node = path[i];
        var parent = node.parentElement;
        if (node !== slotEl) addMark(node, 'path');
        for (var s = parent.firstElementChild; s; s = s.nextElementSibling) {
          if (s !== node && s.tagName !== 'STYLE' && s.tagName !== 'SCRIPT') addMark(s, 'off');
        }
      }
    }
    for (var a = frame.parentElement; a && a !== document.documentElement; a = a.parentElement) {
      var cs = getComputedStyle(a);
      if (cs.transform !== 'none' || cs.filter !== 'none' || cs.contain !== 'none' ||
          cs.perspective !== 'none' || cs.willChange !== 'auto' ||
          (cs.backdropFilter && cs.backdropFilter !== 'none')) {
        addMark(a, 'chain');
      }
    }
  }

  // Several outlets in one frame: every wrapper on the way to any of them
  // stays (as a plain block), everything else between them goes, so their
  // entries stack in page order (the header's, then the composer's).
  function markMany(slotEls, frame) {
    clearMarks();
    var path = [];
    for (var i = 0; i < slotEls.length; i++) {
      addMark(slotEls[i], 'shown');
      for (var p = slotEls[i]; p && p !== frame; p = p.parentElement) {
        if (path.indexOf(p) < 0) path.push(p);
      }
    }
    addMark(frame, 'frame');
    addMark(frame, 'block');
    for (var j = 0; j < path.length; j++) {
      var node = path[j];
      if (slotEls.indexOf(node) < 0) addMark(node, 'path');
      var parent = node.parentElement;
      for (var s = parent.firstElementChild; s; s = s.nextElementSibling) {
        if (path.indexOf(s) < 0 && s.tagName !== 'STYLE' && s.tagName !== 'SCRIPT') addMark(s, 'off');
      }
    }
    for (var a = frame.parentElement; a && a !== document.documentElement; a = a.parentElement) {
      var cs = getComputedStyle(a);
      if (cs.transform !== 'none' || cs.filter !== 'none' || cs.contain !== 'none' ||
          cs.perspective !== 'none' || cs.willChange !== 'auto' ||
          (cs.backdropFilter && cs.backdropFilter !== 'none')) {
        addMark(a, 'chain');
      }
    }
  }

  function apply() {
    var cfg = st.cfg;
    var frame;
    if (cfg.stretch === 'common') {
      var all = findSlots(cfg);
      if (!all.length) return false;
      frame = all.length === 1 ? boxParent(all[0]) : commonFrame(all);
      if (!frame) return false;
      st.slotEls = all;
      st.slotEl = all[0];
      st.frame = frame;
      markMany(all, frame);
      uninert();
      frame.style.setProperty('--dsh-go-island-pad-x', (cfg.pad && cfg.pad[0] != null ? cfg.pad[0] : 16) + 'px');
      frame.style.setProperty('--dsh-go-island-pad-y', (cfg.pad && cfg.pad[1] != null ? cfg.pad[1] : 16) + 'px');
      return true;
    }
    var slotEl = findSlot(cfg.slot);
    if (!slotEl) return false;
    frame = frameFor(slotEl, cfg.stretch || 'scroller');
    st.slotEl = slotEl;
    st.slotEls = [slotEl];
    st.frame = frame;
    mark(slotEl, frame);
    uninert();
    if (frame) {
      frame.style.setProperty('--dsh-go-island-pad-x', (cfg.pad && cfg.pad[0] != null ? cfg.pad[0] : 16) + 'px');
      frame.style.setProperty('--dsh-go-island-pad-y', (cfg.pad && cfg.pad[1] != null ? cfg.pad[1] : 16) + 'px');
    }
    return true;
  }

  // React re-renders can replace the marked nodes: re-mark on the next frame
  // whenever the outlet or the frame left the document.
  function scheduleReapply() {
    if (st.reapplyQueued || st.phase !== 'ready') return;
    st.reapplyQueued = true;
    nextFrame(function () {
      st.reapplyQueued = false;
      if (st.phase !== 'ready') return;
      var ok = st.slotEl && st.slotEl.isConnected && (!st.frame || st.frame.isConnected) &&
        st.slotEl.getAttribute(MARK) && rendered(st.slotEl, 0);
      if (ok && st.cfg.stretch === 'common') {
        var now = findSlots(st.cfg);
        ok = now.length === st.slotEls.length && now.every(function (el, i) { return el === st.slotEls[i]; });
      }
      if (!ok && !apply()) {
        st.phase = 'failed';
        post({ t: 'empty', slot: st.cfg.slot, code: 'slot-missing', detail: 'gone' });
        return;
      }
      if (st.frame && !st.frame.getAttribute(MARK)) apply();
      markLayers();
      measure();
    });
  }

  // Menus and popovers the island's content opens are portals on <body>:
  // anything that arrives there after ready is shown.
  // Only right after a touch or key inside the island: the client's own
  // popups (onboarding, update prompts) arrive the same way and stay hidden.
  var LAYER_WINDOW = 3000;

  function layerRoots() {
    var roots = document.body ? [document.body] : [];
    if (st.cfg && st.cfg.mode !== 'overlay') {
      var overlays = outlets('shell.overlay');
      for (var i = 0; i < overlays.length; i++) roots.push(overlays[i]);
    }
    return roots;
  }

  function snapshotLayers() {
    var nodes = [];
    var roots = layerRoots();
    for (var i = 0; i < roots.length; i++) {
      for (var c = roots[i].firstElementChild; c; c = c.nextElementSibling) nodes.push(c);
    }
    return nodes;
  }

  function markLayers() {
    if (!st.baseline) return;
    var fresh = Date.now() - st.touchedAt <= LAYER_WINDOW;
    var roots = layerRoots();
    for (var i = 0; i < roots.length; i++) {
      for (var c = roots[i].firstElementChild; c; c = c.nextElementSibling) {
        if (st.baseline.indexOf(c) >= 0 || c.tagName === 'SCRIPT' || c.tagName === 'STYLE') continue;
        if (fresh) {
          if (!c.getAttribute(MARK)) addMark(c, 'layer');
        } else {
          // Arrived on its own: part of the official page from now on.
          st.baseline.push(c);
        }
      }
    }
  }

  // The official client makes everything outside an open modal inert (a
  // dialog, the narrow layout's sidebar drawer, a first-run notice): the
  // island's frame can sit under one and take no touches. In island mode no
  // official UI is visible or reachable, so the island's own chain is never
  // inert.
  function uninert() {
    var keep = st.frame || st.slotEl;
    if (!keep) return;
    for (var e = keep; e && e !== document.documentElement; e = e.parentElement) {
      if (e.hasAttribute && e.hasAttribute('inert')) {
        e.removeAttribute('inert');
        st.uninerted = (st.uninerted || 0) + 1;
      }
    }
  }

  function inertAbove(el) {
    for (var e = el; e && e !== document.documentElement; e = e.parentElement) {
      if (e.hasAttribute && e.hasAttribute('inert')) return true;
    }
    return false;
  }

  function inIsland(el) {
    return !!(el && el.closest && el.closest('[' + MARK + '~="frame"],[' + MARK + '~="shown"],[' + MARK + '~="layer"]'));
  }

  ['pointerdown', 'keydown', 'focusin'].forEach(function (type) {
    document.addEventListener(type, function (e) {
      if (st.phase === 'ready' && inIsland(e.target)) st.touchedAt = Date.now();
    }, true);
  });

  // ---- size (panel) and hit regions (overlay) -------------------------------

  function contentHeight() {
    var frame = st.frame;
    if (!frame) return 0;
    var top = frame.getBoundingClientRect().top;
    var bottom = 0;
    for (var c = frame.firstElementChild; c; c = c.nextElementSibling) {
      if (getComputedStyle(c).display === 'none') continue;
      var r = c.getBoundingClientRect();
      if (r.height > 0) bottom = Math.max(bottom, r.bottom);
    }
    var shown = st.slotEls || (st.slotEl ? [st.slotEl] : []);
    for (var s = 0; s < shown.length; s++) {
      var kids = shown[s].querySelectorAll(':scope > *');
      for (var i = 0; i < kids.length; i++) {
        var rr = kids[i].getBoundingClientRect();
        if (rr.height > 0) bottom = Math.max(bottom, rr.bottom);
      }
    }
    var pad = parseFloat(getComputedStyle(frame).paddingBottom) || 0;
    return Math.max(0, Math.ceil(bottom - top + frame.scrollTop + pad));
  }

  function measure() {
    if (st.phase !== 'ready' || !st.cfg || st.cfg.mode !== 'panel' || st.sizeQueued) return;
    st.sizeQueued = true;
    nextFrame(function () {
      st.sizeQueued = false;
      var h = contentHeight();
      if (Math.abs(h - st.lastSize) >= 1) {
        st.lastSize = h;
        post({ t: 'size', h: h });
      }
    });
  }

  var MAX_RECTS = 16;

  // Boxes that take touches under [el]: what an overlay island reports so the
  // app passes every other touch to the native UI underneath.
  function collectRects(el, depth, out) {
    if (!el || depth > 5) return;
    for (var c = el.firstElementChild; c; c = c.nextElementSibling) rectsOf(c, depth, out);
  }

  function rectsOf(c, depth, out) {
    var cs = getComputedStyle(c);
    if (cs.display === 'contents') return collectRects(c, depth + 1, out);
    if (cs.display === 'none' || cs.visibility === 'hidden') return;
    var r = c.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return;
    // A full-screen container that lets touches through: look inside.
    if (cs.pointerEvents === 'none' || r.width * r.height > window.innerWidth * window.innerHeight * 0.8) {
      return collectRects(c, depth + 1, out);
    }
    out.push([Math.round(r.left), Math.round(r.top), Math.ceil(r.width), Math.ceil(r.height)]);
  }

  function mergeRects(rects) {
    while (rects.length > MAX_RECTS) {
      // Union the two closest boxes.
      var best = null;
      for (var i = 0; i < rects.length; i++) {
        for (var j = i + 1; j < rects.length; j++) {
          var a = rects[i], b = rects[j];
          var x = Math.min(a[0], b[0]), y = Math.min(a[1], b[1]);
          var w = Math.max(a[0] + a[2], b[0] + b[2]) - x, h = Math.max(a[1] + a[3], b[1] + b[3]) - y;
          var grow = w * h - a[2] * a[3] - b[2] * b[3];
          if (!best || grow < best.grow) best = { i: i, j: j, r: [x, y, w, h], grow: grow };
        }
      }
      rects.splice(best.j, 1);
      rects[best.i] = best.r;
    }
    return rects;
  }

  function reportHits() {
    if (st.phase !== 'ready' || !st.cfg || st.cfg.mode !== 'overlay') return;
    var now = Date.now();
    var wait = 100 - (now - st.hitAt); // ≤ 10 Hz
    if (wait > 0) {
      if (!st.hitTimer) st.hitTimer = setTimeout(function () { st.hitTimer = 0; reportHits(); }, wait);
      return;
    }
    st.hitAt = now;
    var rects = [];
    if (st.slotEl) collectRects(st.slotEl, 0, rects);
    var layers = document.querySelectorAll('[' + MARK + '~="layer"]');
    for (var i = 0; i < layers.length; i++) rectsOf(layers[i], 0, rects);
    rects = mergeRects(rects);
    var key = JSON.stringify(rects);
    if (key === st.lastHit) return;
    st.lastHit = key;
    post({ t: 'hit', rects: rects, dpr: window.devicePixelRatio || 1 });
  }

  // ---- theme -----------------------------------------------------------------

  function themeStyle() {
    var s = document.getElementById('dsh-go-island-theme');
    if (!s) {
      s = document.createElement('style');
      s.id = 'dsh-go-island-theme';
      document.head.appendChild(s);
    }
    return s;
  }

  function applyTheme(theme) {
    if (!theme) return;
    st.theme = theme;
    st.darkGuard = 0;
    var tokens = theme.tokens || {};
    var decl = [];
    Object.keys(tokens).forEach(function (k) {
      if (/^--[a-z0-9-]+$/.test(k) && /^[#a-z0-9(),.\s%-]+$/i.test(String(tokens[k]))) {
        decl.push(k + ':' + tokens[k] + '!important');
      }
    });
    var scheme = theme.dark ? 'dark' : 'light';
    themeStyle().textContent =
      'html[data-dsh-go-island]{color-scheme:' + scheme + '!important}' +
      'html[data-dsh-go-island] body,html[data-dsh-go-island] body[data-ds-dark-theme]{' + decl.join(';') + '}';
    enforceScheme();
  }

  // DSH picks its light / dark tokens with body[data-ds-dark-theme]; a user
  // who set DSH Web to a fixed mode still gets the App's here.
  function enforceScheme() {
    if (!st.theme || !document.body) return;
    var want = !!st.theme.dark;
    if (document.body.hasAttribute('data-ds-dark-theme') !== want) {
      if (st.darkGuard++ > 20) return; // never fight the page in a loop
      document.body.toggleAttribute('data-ds-dark-theme', want);
    }
  }

  function applyInsets(insets) {
    st.insets = insets || st.insets;
    var root = document.documentElement.style;
    root.setProperty('--dsh-go-island-top', Math.max(0, +st.insets.top || 0) + 'px');
    root.setProperty('--dsh-go-island-bottom', Math.max(0, +st.insets.bottom || 0) + 'px');
  }

  function installCss(css) {
    if (!css) return;
    var s = document.getElementById('dsh-go-island-css');
    if (!s) {
      s = document.createElement('style');
      s.id = 'dsh-go-island-css';
      document.head.appendChild(s);
    }
    s.textContent = css;
  }

  // ---- navigation -------------------------------------------------------------

  var labels = {};

  function sidebar() {
    return document.querySelector('[data-slot="sidebar"]');
  }

  function main() {
    return document.querySelector('[data-slot="main"]');
  }

  // A plugin's settings section (rc.4): the settings dialog's one `nav` lists the
  // sections as buttons by their label, with no id; the active one is
  // aria-current and `settings.section` draws it (the first section until
  // one is picked). The client keeps the active section in memory only, so
  // there is no id to read back: the one button by exactly its name, no
  // other section the bridge reports under that name, then that button
  // current and the section drawn changed. Anything less is a miss.
  async function openSettingsSection(names) {
    // Occupancy may have been reported in another locale or before a rename.
    // This WebView's live label belongs to the exact requested package/cell.
    var bridge = window.__dshGoBridge;
    var cfg = st.cfg || {};
    if (bridge && bridge.occupants) {
      try {
        var own = bridge.occupants('settings.section').filter(function (o) {
          return o.cell === cfg.cell && (!cfg.package || o.package === cfg.package) &&
            o.active !== false && !o.masked && typeof o.label === 'string' && o.label.trim();
        });
        if (own.length === 1) names = [own[0].label.replace(/\s+/g, ' ').trim()];
      } catch (e) {}
    }
    if (namedElsewhere('settings.section', names)) return miss('section', 'another section by its name');
    var dialog = await waitFor(function () { return document.querySelector('[data-shortcut-modal="settings"]'); }, 2000);
    if (!dialog) return miss('section', 'no settings');
    var nav = await onlyByName(dialog, 'nav button', names, 1500);
    if (nav === 'two') return miss('section', 'two by its name');
    if (!nav) return miss('section', 'none by its name');
    return pressUntilCurrent('section', nav, function () { return allByExactName(dialog, 'nav button', names); }, 'settings.section');
  }

  // Presses [control] (unless it is current already) and waits for the page
  // to say so: the one control by the name ([again] finds them anew) is
  // current, and [slot] draws something else than before (or drew it
  // already).
  async function pressUntilCurrent(what, control, again, slot) {
    var before = drawnIn(slot);
    if (isCurrent(control) && before) return hit(what, 'already current');
    control.click();
    var ok = await waitFor(function () {
      var now = again();
      var drawn = drawnIn(slot);
      return now.length === 1 && isCurrent(now[0]) && drawn && drawn !== before ? true : null;
    }, 2500);
    return ok ? hit(what, 'current') : miss(what, 'not current after the click');
  }

  // rc.1 settings uses React-generated ids, but keeps the entry id verbatim
  // in aria-controls and confirms selection with aria-selected + a visible panel.
  async function openSettingsPlugin(cell) {
    var dialog = await waitFor(function () { return document.querySelector('[data-shortcut-modal="settings"]'); }, 2000);
    if (!dialog) return miss('settings-plugin', 'no settings');
    var tabs = function () {
      return Array.prototype.filter.call(dialog.querySelectorAll('button[role="tab"]'), function (el) {
        return (el.getAttribute('aria-controls') || '').endsWith('-panel-' + cell);
      });
    };
    var tab = await waitFor(function () { return tabs()[0]; }, 1500);
    if (!tab) {
      // The client omits tab controls when there is exactly one registered tab.
      var occupants = window.__dshGoBridge.occupants('settings.plugins.tab');
      return occupants.length === 1 && occupants[0].cell === cell && !!findSlot('settings.plugins.tab');
    }
    if (tabs().length !== 1) return miss('settings-plugin', 'ambiguous tab');
    if (tab.getAttribute('aria-selected') !== 'true') tab.click();
    var ok = await waitFor(function () {
      var current = tabs();
      if (current.length !== 1 || current[0].getAttribute('aria-selected') !== 'true') return null;
      var id = current[0].getAttribute('aria-controls');
      var panel = document.getElementById(id);
      if (!panel || panel.getAttribute('role') !== 'tabpanel' || panel.hasAttribute('hidden')) return null;
      st.settingsPanel = id;
      return findSlot('settings.plugins.tab');
    }, 2500);
    return ok ? hit('settings-plugin', 'selected') : miss('settings-plugin', 'not selected');
  }

  async function openPlugin(pkg, row) {
    var sel = 'li[data-plugin-package="' + cssEscape(pkg) + '"]';
    var detail = '[data-plugin-detail="' + cssEscape(pkg) + '"]';
    var card = await waitFor(function () {
      var root = main();
      if (!root) return null;
      if (root.querySelector(detail)) return root.querySelector(detail);
      var c = root.querySelector(sel);
      if (c) return c;
      var back = byName(root, 'button', labels.pluginsBack);
      if (back) back.click();
      // Bundles past the first few sit behind a group's 更多.
      var more = byName(root, 'button', labels.more);
      if (more) more.click();
      return null;
    }, 3500);
    if (!card) return false;
    if (!card.matches(detail)) {
      var open = card.querySelector('button[aria-label]') || card.querySelector('button');
      if (!open) return false;
      open.click();
      if (!(await waitFor(function () { return document.querySelector(detail); }, 3000))) return false;
    }
    if (!row) return true;
    var rowEl = await waitFor(function () {
      return document.querySelector(detail + ' [data-plugin-row="' + cssEscape(row) + '"]');
    }, 3000);
    if (!rowEl) return false;
    var hit = rowEl.matches('button,a') ? rowEl : (rowEl.querySelector('button,a') || rowEl);
    hit.click();
    return true;
  }

  // A sidebar panel (`main`, rc.4): its row in the sidebar's panel list (the
  // sidebar's `nav`), a button by its label (aria-label), with no id; the
  // active one is aria-current="page" and `main` draws it (the conversation
  // until a panel is picked). The layout keeps the active panel in memory
  // only, so there is no id to read back: the one row by exactly its name
  // (a conversation titled the same is not a row), no other panel the
  // bridge reports under that name, then that row current and `main`
  // drawing something else. Anything less is a miss.
  async function openPanel(names) {
    if (namedElsewhere('sidebar.panellist', names)) return miss('panel', 'another panel by its name');
    var row = await onlyByName(sidebar, 'nav button', names, 8000);
    if (row === 'two') return miss('panel', 'two by its name');
    if (!row) return miss('panel', 'none by its name');
    return pressUntilCurrent('panel', row, function () { return allByExactName(sidebar(), 'nav button', names); }, 'main');
  }

  // A right pane tab (rc.4). dsh-go-bridge opens it by its type id (our
  // cell) through the client's own sidebarRight service and answers once
  // that kind is the active tab: that is the identity, and a bridge that
  // can't is not second-guessed by name. Without the bridge's openTab (an
  // older bridge): the one guide entry by exactly its name, whose kind
  // (`data-sidebar-right-guide-entry`) the pane must then record as its
  // active tab. Either way the island shows that tab's own outlet
  // ([ownTab]), not another pane's.
  async function openRightbarTab(names) {
    var bridge = window.__dshGoBridge;
    var cell = st.cfg && st.cfg.cell;
    if (bridge && bridge.openTab) {
      if (!cell) return miss('tab', 'no id');
      var result = null;
      try {
        result = await bridge.openTab(cell, { timeoutMs: 6000 });
      } catch (e) {}
      step('bridge openTab ' + (result && (result.ok ? 'ok' : result.reason)));
      if (!(result && result.ok)) return miss('tab', 'the bridge could not open it by its id');
      var shown = activeTab();
      st.tabShown = typeof result.tabId === 'string' ? result.tabId : shown ? shown.id : null;
      return hit('tab', 'opened by id');
    }
    if (namedElsewhere('sidebar.right.pane.tab', names)) return miss('tab', 'another tab by its name');
    var rightbar = function () { return document.querySelector('[data-slot="rightbar"]'); };
    var way = await waitFor(function () {
      if (allByExactName(rightbar(), 'button', names).length) return { entry: true };
      var control = byName(document, 'button', labels.openRightbar) || byName(rightbar(), 'button', labels.newTab);
      return control ? { control: control } : null;
    }, 8000);
    if (!way) return miss('tab', 'no way in');
    if (way.control) way.control.click();
    var entry = await onlyByName(rightbar, 'button', names, 4000);
    if (entry === 'two') return miss('tab', 'two by its name');
    if (!entry) return miss('tab', 'none by its name');
    var kind = entry.getAttribute('data-sidebar-right-guide-entry');
    if (!kind) return miss('tab', 'an entry without its kind');
    entry.click();
    var opened = await waitFor(function () {
      var tab = activeTab();
      return tab && tab.kind === kind ? tab : null;
    }, 3000);
    if (!opened) return miss('tab', 'not recorded as the active tab');
    st.tabShown = opened.id;
    return hit('tab', kind + ' is the active tab');
  }

  // The active tab of this conversation's right pane, as the client records
  // it (rc.4: localStorage `dsh.sidebar-right.v1.<session>`, written on
  // every change; the active pane's active tab): {id, kind}, or null.
  var PANE_STORE = 'dsh.sidebar-right.v1.';

  function activeTab() {
    var session = st.cfg && st.cfg.target && st.cfg.target.session;
    if (!session) return null;
    try {
      var saved = JSON.parse(localStorage.getItem(PANE_STORE + session) || 'null');
      var surface = saved && saved.bySession && saved.bySession[session];
      var layout = surface && surface.layout;
      var pane = layout && layout.nodes && layout.nodes[layout.activePaneId];
      var tab = pane && pane.activeTabId && layout.tabs && layout.tabs[pane.activeTabId];
      return tab && typeof tab.kind === 'string' ? { id: String(pane.activeTabId), kind: tab.kind } : null;
    } catch (e) {
      return null;
    }
  }

  // A conversation view (conversation.view, rc.4): its tab in the View row,
  // or its row under 「更多会话视图」. Tabs carry no ids, so a name only picks
  // the control to press: the one control that goes by exactly one of the
  // view's names; none when two do (which is which can't be told). What says
  // which view is on screen is the client's own record: picking a view
  // stores its id in the conversation's state (`setView`, at once in
  // localStorage `dsh.conversation.<id>` `view`) and the slot draws the view
  // stored there. So the view counts as open only when that id is the cell
  // asked for, the slot draws something new (or did already, under that
  // id), and the row's selected tab, if any, is the one by its name.
  // Anything less is a miss, and the island falls back to DSH Web: never
  // another view shown under this one's name.
  async function openView(view) {
    var id = view && typeof view.id === 'string' ? view.id : '';
    var names = (view && view.names) || [];
    if (!id || !names.length) return false;
    var row = await waitFor(function () { return document.querySelector('[data-conversation-tabs]'); }, 4000);
    if (!row) return false;
    keepViewPreference();
    var current = function () {
      var slotEl = findSlot('conversation.view');
      return slotEl ? firstBoxChild(slotEl) : null;
    };
    var named = function () { return allByExactName(row, 'button[role="tab"]', names); };
    var selected = function () {
      var all = row.querySelectorAll('button[role="tab"]');
      for (var i = 0; i < all.length; i++) {
        if (all[i].getAttribute('aria-selected') === 'true') return all[i];
      }
      return null;
    };
    var before = current();
    var storedBefore = storedView();
    var tabs = named();
    if (tabs.length > 1) return viewMiss('two tabs by its name');
    var tab = tabs[0] || null;
    var on = selected();
    // On screen already (the person left it there, or an earlier try).
    if (storedBefore === id && before && (tab ? on === tab : !on)) return viewOpen(id, 'already');
    // Selected under its name, but the client has another view (or none) stored.
    if (tab && on === tab) return viewMiss('selected tab stored as ' + storedBefore);
    if (tab) {
      tab.click();
    } else {
      var more = byName(document, 'button', labels.moreViews);
      if (!more) return viewMiss('no tab');
      more.click();
      var items = await waitFor(function () {
        var menus = document.querySelectorAll('[role="menu"]');
        var hits = [];
        for (var i = 0; i < menus.length; i++) {
          hits = hits.concat(allByExactName(menus[i], '[role^="menuitem"], button, li', names));
        }
        return hits.length ? hits : null;
      }, 2000);
      if (!items) return viewMiss('no row');
      if (items.length > 1) return viewMiss('two rows by its name');
      items[0].click();
    }
    step('view clicked');
    var verdict = await waitFor(function () {
      var stored = storedView();
      // Another id stored by this click: another view went by this name.
      if (stored !== undefined && stored !== storedBefore && stored !== id) return 'stored as ' + stored;
      if (stored !== id) return null;
      var now = current();
      if (!now || now === before) return null;
      var shown = selected();
      if (!shown) return 'ok'; // picked from the menu: no tab of its own
      var mine = named();
      return mine.length === 1 && mine[0] === shown ? 'ok' : null;
    }, 2500);
    if (verdict !== 'ok') return viewMiss(verdict || 'unconfirmed');
    return viewOpen(id, 'confirmed');
  }

  function viewOpen(id, how) {
    st.viewShown = id;
    step('view ' + how + ' ' + id);
    return true;
  }

  function viewMiss(why) {
    step('view miss: ' + why);
    return false;
  }

  // Picking a view makes DSH Web remember it for the conversation
  // (localStorage `dsh.conversation.<id>`): the person's own choice goes
  // back once ours is on screen, and again on the way out.
  var VIEW_STORE = 'dsh.conversation.';

  // The view the client has stored for this island's conversation: its id,
  // null for none, undefined when it can't be read.
  function storedView() {
    var session = st.cfg && st.cfg.target && st.cfg.target.session;
    if (!session) return undefined;
    try {
      var stored = JSON.parse(localStorage.getItem(VIEW_STORE + session) || 'null');
      return stored && typeof stored === 'object' && typeof stored.view === 'string' ? stored.view : null;
    } catch (e) {
      return undefined;
    }
  }

  function keepViewPreference() {
    var session = st.cfg && st.cfg.target && st.cfg.target.session;
    if (!session || st.viewPref) return;
    try {
      var key = VIEW_STORE + session;
      var stored = JSON.parse(localStorage.getItem(key) || 'null');
      var view = stored && typeof stored === 'object' && typeof stored.view === 'string' ? stored.view : null;
      st.viewPref = { key: key, view: view };
    } catch (e) {}
  }

  // Once the view is on screen, only the id it went by goes back (the
  // client writes it again with the rest of its state); a different choice
  // stored since (another DSH Web on the same storage) stays.
  function restoreViewPreference() {
    var kept = st.viewPref;
    if (!kept) return;
    try {
      var stored = JSON.parse(localStorage.getItem(kept.key) || 'null');
      if (!stored || typeof stored !== 'object' || stored.view === kept.view) return;
      if (st.viewShown && stored.view !== st.viewShown) return;
      stored.view = kept.view;
      localStorage.setItem(kept.key, JSON.stringify(stored));
      step('view preference kept');
    } catch (e) {}
  }

  // target: {session?, web?: <__dshAppOpen target>, then?: {settings|plugin|panel|rightbar|view}}
  var HOP = 'dsh-go-island-hop';

  function storedSession() {
    try {
      return (JSON.parse(localStorage.getItem('dsh.sessions.current') || '{}') || {}).sessionId || null;
    } catch (e) {
      return null;
    }
  }

  // target: {session?, web?: <__dshAppOpen target>, then?: {settings|plugin|panel|rightbar}}.
  // Resolves 'hop' when the page is about to reload into the conversation
  // (the open bridge picks the target up after the reload, and so do we).
  // Selects [sessionId] the way the open bridge does (the stored selection
  // the client restores at boot) and loads the page again. Not with
  // location.reload(): with a fragment in the URL the WebView takes that as
  // a same-document navigation and nothing reloads, so a query makes it a
  // new load.
  function hopTo(sessionId, hopId) {
    try {
      localStorage.setItem('dsh.sessions.current', JSON.stringify({ sessionId: sessionId }));
      sessionStorage.setItem(HOP, hopId);
    } catch (e) {
      return false;
    }
    step('hop');
    st.leaving = true;
    var url = new URL(location.href);
    url.searchParams.set('dsh-go-hop', String(Date.now()));
    location.replace(url.toString());
    return true;
  }

  // target: {session?, web?: <__dshAppOpen target>, then?: {settings|plugin|panel|rightbar}}.
  // Resolves 'hop' when the page is about to load again with the
  // conversation selected (init starts over on the next load).
  async function navigate(target, attempt) {
    target = target || {};
    step('navigate#' + attempt + ' ' + JSON.stringify(target).slice(0, 120));
    var web = target.web ? Object.assign({}, target.web) : null;
    var hopId = (st.cfg && st.cfg.slot) + '|' + (target.session || '');
    var hopped = false;
    try {
      hopped = sessionStorage.getItem(HOP) === hopId;
      if (hopped) sessionStorage.removeItem(HOP);
    } catch (e) {}
    if (hopped) st.hopsSeen = true;
    // Whatever the open bridge is still doing (a target another page left
    // in this tab's sessionStorage).
    if (window.__dshAppOpening) {
      try { await window.__dshAppOpening; } catch (e) {}
    }
    if (target.session) {
      if (storedSession() !== target.session && !st.hopsSeen) {
        if (hopTo(target.session, hopId)) return 'hop';
      }
      // The client restores the stored conversation at boot, sometimes
      // slowly on a first start: wait for it.
      var shown = await waitFor(function () {
        return document.querySelector('[data-slot="conversation.session"]');
      }, attempt === 0 ? 6000 : 2000);
      step('conversation ' + (shown ? 'on screen' : 'missing'));
      // Stored but not restored: one more load, as the open bridge does.
      if (!shown && !st.hopsSeen && hopTo(target.session, hopId)) return 'hop';
    }
    if (web && Object.keys(web).length && window.__dshAppOpen) {
      window.__dshAppOpen(web);
      try {
        if ((await window.__dshAppOpening) !== true) return false;
      } catch (e) { return false; }
    }
    step('web done');
    var then = target.then;
    if (!then) return true;
    if (then.sidebar) return !!(await waitFor(function () { return findSlot('sidebar.footer.action'); }, 2500));
    if (then.settingsPlugin) return openSettingsPlugin(then.settingsPlugin);
    if (then.settings) return openSettingsSection(then.settings);
    if (then.plugin) return openPlugin(then.plugin, then.row || null);
    if (then.panel) return openPanel(then.panel);
    if (then.rightbar) return openRightbarTab(then.rightbar);
    if (then.view) return openView(then.view);
    return true;
  }

  // ---- probe -------------------------------------------------------------------

  // A probe island (no slot shown): load the page so dsh-go-bridge's browser
  // half reports this boot graph's occupancy, then let the app destroy it.
  // The bridge reports on its own shortly after boot; report() only makes
  // it sooner, so neither its absence nor a slow answer holds the probe up.
  function capped(promise, ms) {
    return Promise.race([Promise.resolve(promise), sleep(ms)]);
  }

  async function probe(cfg) {
    // No dependence on the client's layout (the probe is laid out off
    // screen): the bridge's API, or the boot graph, is all it needs.
    var bridge = await waitFor(function () { return window.__dshGoBridge; }, 8000);
    if (bridge && bridge.report) {
      step('report');
      try { await capped(bridge.report(), 4000); } catch (e) {}
    } else {
      step(window.__DSH_BOOT__ ? 'no bridge api' : 'no boot graph');
    }
    // Either way the page loaded: the bridge (if any) reports on its own.
    st.phase = 'ready';
    post({ t: 'ready', slot: cfg.slot, release: release(), found: 0, probe: true, detail: bridge ? 'reported' : 'no bridge' });
  }

  // Third-party entries left in a list slot once the bridge masked the
  // official ones (-1: no bridge to ask).
  function thirdPartyAll(cfg) {
    var keys = slotsOf(cfg);
    var n = 0;
    for (var i = 0; i < keys.length; i++) {
      var c = thirdParty(keys[i]);
      if (c < 0) return c;
      n += c;
    }
    return n;
  }

  function thirdParty(slot) {
    var bridge = window.__dshGoBridge;
    if (!bridge || !bridge.occupants) return -1;
    try {
      return bridge.occupants(slot).filter(function (o) { return !o.masked && !o.official; }).length;
    } catch (e) {
      return -1;
    }
  }


  // ---- lifecycle -----------------------------------------------------------------

  var observing = false;

  function observe() {
    if (observing) return;
    observing = true;
    new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var r = records[i];
        if (r.type === 'attributes' && r.target === document.body && r.attributeName === 'data-ds-dark-theme') {
          enforceScheme();
        }
        if (r.type === 'attributes' && r.attributeName === 'inert' && st.phase === 'ready') uninert();
      }
      scheduleReapply();
      measure();
      reportHits();
    }).observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['data-ds-dark-theme', 'class', 'style', 'aria-expanded', 'data-state', 'inert'] });
    if (window.ResizeObserver) {
      var ro = new ResizeObserver(function () { measure(); reportHits(); });
      ro.observe(document.documentElement);
      st.resizeObserver = ro;
    }
    window.addEventListener('resize', function () { measure(); reportHits(); });
    document.addEventListener('scroll', function () { reportHits(); }, true);
    ['pointerup', 'pointercancel'].forEach(function (type) {
      document.addEventListener(type, function () { reportHits(); }, true);
    });
    document.addEventListener('pointermove', function () {
      if (Date.now() - st.touchedAt <= LAYER_WINDOW) reportHits();
    }, true);
    setInterval(function () { if (st.cfg && st.cfg.mode === 'overlay') reportHits(); }, 250);
    // A plugin that selects another conversation (the official sessions
    // service writes the stored selection): the app opens it natively.
    st.selection = storedSession();
    setInterval(function () {
      var now = storedSession();
      if (now && now !== st.selection) post({ t: 'session', id: now });
      st.selection = now;
    }, 500);
  }



  function watchContent() {
    if (!st.resizeObserver) return;
    try {
      if (st.frame) st.resizeObserver.observe(st.frame);
      var shown = st.slotEls || (st.slotEl ? [st.slotEl] : []);
      for (var s = 0; s < shown.length; s++) {
        var kids = shown[s].querySelectorAll(':scope > *');
        for (var i = 0; i < kids.length; i++) st.resizeObserver.observe(kids[i]);
      }
    } catch (e) {}
  }

  // Outgoing links and "open this conversation" from the island's content go
  // to the app, which decides (https only, with a confirmation).
  document.addEventListener('click', function (e) {
    if (st.phase !== 'ready') return;
    var a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    if (!a) return;
    var url;
    try { url = new URL(a.getAttribute('href'), location.href); } catch (err) { return; }
    if (url.origin === location.origin) return;
    e.preventDefault();
    e.stopPropagation();
    if (url.protocol === 'https:') post({ t: 'link', url: url.href });
  }, true);

  async function init(cfg) {
    if (!cfg || typeof cfg.slot !== 'string') return;
    if (st.cfg && st.phase !== 'failed') {
      // Injected again into the same document (the page reported finished
      // twice): take the newer load id, and say ready again under it.
      st.cfg.load = cfg.load;
      if (terminal) {
        var again = Object.assign({}, terminal);
        delete again.load;
        post(again);
      }
      if (st.phase === 'ready') {
        st.lastSize = -1;
        measure();
        st.lastHit = '';
        reportHits();
      }
      return;
    }
    st.cfg = cfg;
    st.phase = 'opening';
    // Injected while the document is still being built: wait for it.
    if (!document.head || !document.body) {
      await waitFor(function () { return document.head && document.body; }, 5000);
      if (!document.head || !document.body) return;
    }
    labels = cfg.labels || {};
    var html = document.documentElement;
    html.setAttribute(MARK, '');
    html.setAttribute(FORM, cfg.mode || 'page');
    installCss(cfg.css);
    applyTheme(cfg.theme);
    applyInsets(cfg.insets);
    if (cfg.mode === 'probe') return probe(cfg);

    step('init ' + cfg.slot);
    var boot = await waitFor(sidebar, cfg.bootMs || 15000);
    step(boot ? 'booted' : 'no boot');
    if (!boot) {
      st.phase = 'failed';
      return post({ t: 'error', slot: cfg.slot, code: 'boot', detail: 'no client' });
    }
    var filtered = cfg.mode === 'overlay' || ['sidebar.footer.action', 'settings.plugins.tab', 'plugins.detail.section'].indexOf(cfg.slot) >= 0;
    if (filtered) {
      var bridge = await waitFor(function () { return window.__dshGoBridge; }, 2500);
      var allowed = false;
      try {
        allowed = !!(cfg.package && typeof cfg.cell === 'string' && bridge && bridge.filter && bridge.occupants &&
          bridge.filter(cfg.slot, [{ package: cfg.package, cell: cfg.cell }]) === true);
      } catch (e) {}
      if (!allowed) {
        st.phase = 'failed';
        return post({ t: 'error', slot: cfg.slot, code: 'filter-unavailable', detail: 'package isolation unavailable' });
      }
    }
    // List slots in a panel island: the official entries are the native
    // UI's already. The URL fragment asked the bridge at boot; ask again in
    // case the fragment got lost on the way.
    if (!filtered && cfg.mask && window.__dshGoBridge && window.__dshGoBridge.mask) {
      try { window.__dshGoBridge.mask(slotsOf(cfg)); } catch (e) {}
    }
    // Navigate, then look for the slot; a transient popup (the client's own
    // onboarding card, a toast) can swallow a click, so try again twice.
    var opened = true;
    var outlet = null;
    for (var attempt = 0; attempt < 3 && !outlet; attempt++) {
      try { opened = await navigate(cfg.target, attempt); } catch (e) { opened = false; }
      if (opened === 'hop') return; // the page reloads into the conversation
      // A keyed slot swaps its occupant a render after the click: let it, so
      // the previous one (the conversation in `main`) isn't taken for ours.
      if (cfg.target && (cfg.target.web || cfg.target.then)) await sleep(cfg.settleMs || 150);
      st.phase = 'waiting';
      step('opened ' + opened);
      outlet = await waitFor(function () { return findAny(cfg); }, attempt < 2 ? 1500 : (cfg.slotMs || 3000));
      // A failed navigation must not expose the slot left on screen.
      if (opened !== true) outlet = null;
    }
    if (!outlet) {
      st.phase = 'failed';
      // A view that didn't open may have left another one picked.
      restoreViewPreference();
      var exists = slotsOf(cfg).some(function (k) { return outlets(k).length > 0; });
      return post({
        t: 'empty',
        slot: cfg.slot,
        code: exists ? 'empty' : 'slot-missing',
        detail: opened ? '' : 'navigation',
      });
    }
    if (filtered) {
      var selected = window.__dshGoBridge.occupants(cfg.slot).some(function (o) {
        return o.package === cfg.package && o.cell === cfg.cell && o.active && !o.masked;
      });
      if (!selected) {
        st.phase = 'failed';
        return post({ t: 'empty', slot: cfg.slot, code: 'empty', detail: 'selected entry not active' });
      }
    }
    if (cfg.mask && thirdPartyAll(cfg) === 0) {
      st.phase = 'failed';
      return post({ t: 'empty', slot: cfg.slot, code: 'empty', detail: 'only official entries' });
    }
    // Navigation can leave the narrow layout's sidebar drawer open, which
    // makes the page under it inert: close it the way a user would. Other
    // modals (a first-run notice) stay; apply() lifts inert off our chain.
    if (inertAbove(outlet)) {
      var collapse = byName(sidebar(), 'button', labels.closeSidebar);
      if (collapse) {
        step('collapse sidebar');
        collapse.click();
        await sleep(300);
        outlet = findAny(cfg) || outlet;
      }
    }
    // Menus open as new <body> or shell.overlay children; what is there now never shows.
    st.baseline = snapshotLayers();
    apply();
    st.phase = 'ready';
    observe();
    watchContent();
    var found = 0;
    for (var f = 0; f < (st.slotEls || [outlet]).length; f++) found += entries((st.slotEls || [outlet])[f]);
    // A view's cell is the id the client has on screen, not just the one asked for.
    post({ t: 'ready', slot: cfg.slot, cell: st.viewShown || cfg.cell || null, release: release(), found: found });
    measure();
    reportHits();
    if (st.viewPref) {
      restoreViewPreference();
      // The client writes its state a moment later too.
      setTimeout(restoreViewPreference, 1500);
    }
  }

  window.addEventListener('pagehide', function () {
    st.leaving = true;
    restoreViewPreference();
  });

  window.__dshGoIsland = {
    init: function (cfg) {
      init(cfg).catch(function (e) {
        st.phase = 'failed';
        post({ t: 'error', slot: (cfg && cfg.slot) || '', code: 'crash', detail: String(e && e.message || e).slice(0, 200) });
      });
    },
    setTheme: applyTheme,
    setInsets: applyInsets,
    // Debugging and the PoC's measurements: no side effects. `leaks` are
    // boxes on screen outside the island (should always be none).
    inspect: function () {
      var keep = '[' + MARK + '~="frame"],[' + MARK + '~="shown"],[' + MARK + '~="layer"]';
      var leaks = [];
      var all = document.body ? document.body.querySelectorAll('*') : [];
      for (var i = 0; i < all.length; i++) {
        var e = all[i];
        if (e.closest(keep) || getComputedStyle(e).visibility !== 'visible') continue;
        var r = e.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) leaks.push(e.tagName + '.' + String(e.className).slice(0, 40));
      }
      return {
        phase: st.phase,
        slot: st.cfg && st.cfg.slot,
        frame: st.frame ? st.frame.tagName + '.' + String(st.frame.className) : null,
        marks: st.marked.length,
        size: st.lastSize,
        hit: st.lastHit,
        nodes: all.length,
        leaks: leaks.length,
        leaked: leaks.slice(0, 5),
        trace: trace,
      };
    },
  };
})();
