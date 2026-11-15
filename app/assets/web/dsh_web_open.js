// "Open this page" bridge for DSH Web. Injected by dsh-app's WebView page
// after every load (phone layout on or off); idempotent. The app calls
// window.__dshAppOpen(target) once to land on a page the official web client
// has no URL for:
//
//   {session: id}             open a session (stored selection + one load)
//   {panel: 'plugins'|'schedules'}
//   {panel: 'cordis'}         the Cordis plugin panel (sidebar footer badge)
//   {settings: 'general'|'models'|'plugins'|'agent-presets'|'account'}
//   {pluginItem: [labels]}    a card on the Plugins page (built-in config or
//                             experimental bundle), matched by the package
//                             name or item id the page marks it with, else
//                             by its title
//   {rightbar: 'files'|'terminal'}  needs a session on screen
//   {sidebar: true}           the sessions / workspaces sidebar
//   {newSession: true}        a new conversation (the sidebar's 新会话)
//
// and window.__dshAppCompose({text, files}) puts a share in the composer on
// screen the way a paste does (files: {name, type, data: base64}); what
// landed goes to the `DshAppCompose` channel as {text: bool, files: n}.
//
// Only clicks the official controls and writes the official stored selection
// (`dsh.sessions.current`); never restyles, adds or removes official nodes.
// Controls are found by their accessible names (zh and en) or the official
// data attributes, never by hashed class names alone. The outcome goes to
// the app's `DshAppOpen` channel.
//
// An open never outstays its welcome: only the latest one acts (a newer open
// stops the one before), it gives up STEPS_MS after the page booted whatever
// step it is on, and it stops where it is once the person touches or types
// in the page. A stopped open presses nothing more and reports nothing; one
// that ran out of time or found nothing says which step, and the page stays
// where it got to (the Plugins page for a card it couldn't find).
(function () {
  if (window.__dshAppOpen) return;

  var PENDING = 'dsh-app-open-pending';
  var STORE = 'dsh.sessions.current';
  // A hop's one-off query (see hop); gone from the address once it landed.
  var HOP_PARAM = 'dsh-go-hop';
  // How long a blank conversation has to stay as it is after New before it counts as the new one.
  var BLANK_SETTLE_MS = 1500;
  // How long an open may keep looking once the page has booted.
  var STEPS_MS = 15000;
  // Where the Plugins page marks a card: a bundle's package name, an
  // official item's id.
  var CARD_MARKS = ['data-plugin-package', 'data-plugin-item'];
  // A card's way into its page ("查看 …").
  var CARD_OPEN = 'button[aria-label^="查看 "], button[aria-label^="View "]';
  // The crumb back at the top of a page inside the Plugins panel (a
  // plugin's, one of its parts', the experimental list).
  var PLUGINS_CRUMB = '[data-plugin-panel] button[class*="_crumb"]';
  // Accessible names of the official controls, in both languages the page
  // can be in (they are matched, never shown).
  var LABELS = {
    panel: {
      plugins: ['插件', 'Plugins'],
      schedules: ['自动化任务', 'Automation tasks'],
    },
    settings: {
      general: ['通用设置', 'General'],
      models: ['模型', 'Models'],
      plugins: ['内置插件', 'Built-in plugins'],
      'agent-presets': ['Agent 预设', 'Agent presets'],
      account: ['账号与余额', 'Account'],
    },
    settingsButton: ['设置', 'Settings'],
    accountMenu: ['账号菜单', 'Account menu'],
    more: ['更多', 'More'],
    openRightbar: ['打开右侧边栏', 'Open right sidebar'],
    newTab: ['新标签页', 'New tab'],
    pluginsBack: ['返回插件', 'Back to plugins'],
    files: ['工作区文件', 'Workspace files'],
    terminal: ['新建终端', 'New terminal'],
    openSidebar: ['打开侧边栏', 'Open sidebar'],
    cordis: ['Cordis 插件', 'Cordis plugins'],
    newSession: ['新会话', '新对话', 'New session', 'New chat'],
  };

  function report(ok, step) {
    try {
      if (window.DshAppOpen) window.DshAppOpen.postMessage(JSON.stringify({ ok: ok, step: step || null }));
    } catch (e) {}
  }

  function sleep(ms) {
    return new Promise(function (r) { setTimeout(r, ms); });
  }

  // The open in progress: {booted, stopped, until}. Each step takes it
  // along; once it is stopped or past [until] its waits end empty and
  // [press] refuses, so it can't act under a newer open or the person.
  var current = null;

  // [r] may still act (no open at all: a compose's own waits).
  function live(r) {
    return !r || (!r.stopped && Date.now() <= r.until);
  }

  // Polls [find] until it returns an element; gives up after [ms], or once
  // the open [r] it is for has stopped or run out of time.
  function waitFor(find, ms, r) {
    var until = Date.now() + (ms || 8000);
    if (r && r.until < until) until = r.until;
    return new Promise(function (resolve) {
      (function tick() {
        if (r && r.stopped) return resolve(null);
        var el = null;
        try { el = find(); } catch (e) {}
        if (el) return resolve(el);
        if (Date.now() > until) return resolve(null);
        setTimeout(tick, 120);
      })();
    });
  }

  // Clicks [el] for the open [r], while it may still act.
  function press(r, el) {
    if (!el || !live(r)) return false;
    el.click();
    return true;
  }

  // The person is using the page: the open on its way stops where it is,
  // so nothing gets pressed under their hands. Real input only (the
  // bridges' own clicks and events are untrusted), and only once the page
  // has booted (a tap on a page still loading changes nothing yet).
  function takeOver(e) {
    if (current && current.booted && e && e.isTrusted) current.stopped = true;
  }
  document.addEventListener('pointerdown', takeOver, true);
  document.addEventListener('keydown', takeOver, true);

  function text(el) {
    return (el.textContent || '').replace(/\s+/g, ' ').trim();
  }

  // A control whose aria-label, text, or the text of one of its leaf
  // elements (cards: title + description) is one of [labels]; a label may
  // also be followed by a space ("新建终端 在会话工作区运行命令").
  function byName(root, selector, labels) {
    if (!root) return null;
    var nodes = root.querySelectorAll(selector);
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i];
      var names = [n.getAttribute('aria-label') || '', text(n)];
      var leaves = n.querySelectorAll('*');
      for (var l = 0; l < leaves.length; l++) {
        if (!leaves[l].children.length) names.push(text(leaves[l]));
      }
      for (var j = 0; j < labels.length; j++) {
        for (var k = 0; k < names.length; k++) {
          var name = names[k];
          if (name === labels[j] || name.indexOf(labels[j] + ' ') === 0) return n;
        }
      }
    }
    return null;
  }

  function sidebar() {
    return document.querySelector('[data-slot="sidebar"]');
  }

  function storedSession() {
    try {
      return (JSON.parse(localStorage.getItem(STORE) || '{}') || {}).sessionId || null;
    } catch (e) {
      return null;
    }
  }

  async function openPanel(r, key) {
    var labels = LABELS.panel[key];
    return press(r, await waitFor(function () { return byName(sidebar(), 'button', labels); }, 8000, r));
  }

  // The Cordis badge sits in the sidebar's footer and only renders while the
  // Host has a dynamic plugin. On a phone the sidebar is a closed drawer: open
  // it (after the phone layout's collapse-on-arrival) and let it finish
  // sliding, since the panel takes its place from the badge when it opens.
  async function openCordis(r) {
    var find = function () {
      return document.querySelector('[data-cordis-badge]') || byName(document, 'button', LABELS.cordis);
    };
    if (!(await waitFor(find, 8000, r))) return false;
    await sleep(400);
    if (!live(r)) return false;
    if (window.__dshApp && window.__dshApp.sidebarOpen && !window.__dshApp.sidebarOpen()) {
      window.__dshApp.toggleSidebar();
      await sleep(400);
    }
    var badge = find();
    if (!badge || !live(r)) return false;
    if (badge.getAttribute('aria-expanded') !== 'true') press(r, badge);
    return !!(await waitFor(function () { return document.querySelector('[data-cordis-panel]'); }, 3000, r));
  }

  async function openSettings(r, key) {
    var direct = byName(sidebar(), 'button', LABELS.settingsButton);
    if (direct) {
      if (!press(r, direct)) return false;
    } else {
      var menu = await waitFor(function () { return byName(document, 'button', LABELS.accountMenu); }, 8000, r);
      if (!press(r, menu)) return false;
      var item = await waitFor(function () {
        return byName(document, '[role="menuitem"]', LABELS.settingsButton);
      }, 3000, r);
      if (!press(r, item)) return false;
    }
    var dialog = await waitFor(function () {
      return document.querySelector('[data-shortcut-modal="settings"]');
    }, 4000, r);
    if (!dialog) return false;
    if (!key || key === 'general') return true;
    return press(r, await waitFor(function () { return byName(dialog, 'button', LABELS.settings[key] || []); }, 3000, r));
  }

  // The card [labels] name on the Plugins page: the one marked with one of
  // them (a package name or an item id: exact, whatever the page's
  // language), else one titled with one of them ([names]).
  function pluginCard(root, labels, names) {
    if (!root) return null;
    var marked = root.querySelectorAll('[data-plugin-package], [data-plugin-item]');
    for (var i = 0; i < labels.length; i++) {
      for (var m = 0; m < marked.length; m++) {
        for (var a = 0; a < CARD_MARKS.length; a++) {
          if (marked[m].getAttribute(CARD_MARKS[a]) !== labels[i]) continue;
          var open = marked[m].querySelector(CARD_OPEN);
          if (open) return open;
        }
      }
    }
    return byName(root, 'button', names);
  }

  async function openPluginItem(r, labels) {
    if (!(await openPanel(r, 'plugins'))) return false;
    var main = function () { return document.querySelector('[data-slot="main"]'); };
    var names = [];
    labels.forEach(function (l) { names.push(l, '查看 ' + l, 'View ' + l); });
    // Wait for the page's cards, then look for ours. The panel remembers a
    // page opened earlier (a plugin's, one of its parts', the experimental
    // list): back to the list first, by its crumb, a press at a time and a
    // few at most.
    var backs = 0;
    var pressedAt = 0;
    var rendered = await waitFor(function () {
      var root = main();
      if (!root) return null;
      var cards = root.querySelector(CARD_OPEN);
      if (cards) return cards;
      if (backs < 3 && Date.now() - pressedAt > 600) {
        var back = byName(root, 'button', LABELS.pluginsBack) || root.querySelector(PLUGINS_CRUMB);
        if (press(r, back)) {
          backs++;
          pressedAt = Date.now();
        }
      }
      return null;
    }, 6000, r);
    if (!rendered) return false;
    var card = pluginCard(main(), labels, names);
    // Experimental bundles past the first few sit behind the group's "更多".
    if (!card && press(r, byName(main(), 'button', LABELS.more))) {
      card = await waitFor(function () { return pluginCard(main(), labels, names); }, 2000, r);
    }
    return press(r, card);
  }

  async function openRightbar(r, kind) {
    var rightbar = function () { return document.querySelector('[data-slot="rightbar"]'); };
    var entryOf = function () { return byName(rightbar(), 'button', LABELS[kind] || []); };
    // Collapsed: the session header's expand button. Open (remembered per
    // session): the start page's entry, or a new tab to get a start page.
    var first = await waitFor(function () {
      return entryOf() || byName(document, 'button', LABELS.openRightbar) ||
        byName(rightbar(), 'button', LABELS.newTab);
    }, 8000, r);
    if (!first) return false;
    if (first !== entryOf() && !press(r, first)) return false;
    return press(r, await waitFor(entryOf, 4000, r));
  }

  async function startNewSession(r, confirm) {
    var button = await waitFor(function () {
      var side = sidebar();
      if (!side) return null;
      return side.querySelector('button[class*="_newSession"]') || byName(side, 'button', LABELS.newSession);
    }, 8000, r);
    var previous = confirm ? composerSession(composerEditor()) : null;
    var stored = confirm ? storedSession() : null;
    var blank = confirm && !!previous && blankConversation(composerEditor());
    if (!press(r, button)) return false;
    if (confirm) {
      var blankSince = null;
      var editor = await waitFor(function () {
        var candidate = composerEditor();
        var id = composerSession(candidate);
        if (id && id !== previous && id !== stored) {
          r.confirmedSession = id;
          return candidate;
        }
        // New stays on a conversation that's already blank, so no other id is coming. If this is
        // wrong, a draft sits in the box in front of the person, unsent.
        if (!blank || id !== previous || !blankConversation(candidate)) {
          blankSince = null;
          return null;
        }
        if (blankSince === null) blankSince = Date.now();
        if (Date.now() - blankSince < BLANK_SETTLE_MS) return null;
        r.confirmedSession = id;
        return candidate;
      }, 10000, r);
      return !!editor;
    }
    // Let the new conversation's composer replace the old one.
    await sleep(500);
    return true;
  }

  // The public conversation wrapper binds this editor to a session.
  function composerSession(editor) {
    var conversation = editor && editor.closest('[data-conversation-content][data-conversation-session]');
    return conversation && conversation.getAttribute('data-conversation-session');
  }

  // The client's own word for a conversation with nothing in it, with nothing typed or attached.
  function blankConversation(editor) {
    var conversation = editor && editor.closest('[data-conversation-content][data-conversation-session]');
    return !!conversation && conversation.getAttribute('data-content-phase') === 'hero' &&
      !(editor.textContent || '').trim() && attachmentCount(editor) === 0;
  }

  // The composer's editor (Lexical: one contenteditable root) that is on
  // screen, the last one if several are mounted.
  function composerEditor() {
    var editors = document.querySelectorAll('[data-lexical-editor="true"][contenteditable="true"]');
    for (var i = editors.length - 1; i >= 0; i--) {
      if (editors[i].getClientRects().length) return editors[i];
    }
    return null;
  }

  function post(channel, value) {
    try {
      if (window[channel]) window[channel].postMessage(JSON.stringify(value));
    } catch (e) {}
  }

  function attachmentCount(editor) {
    if (editor) {
      var card = editor.closest('[data-composer-card]');
      if (!card) return 0;
      // rc.4 renders one direct rail child per image or file. Keep the
      // count inside this editor's composer, away from conversation history.
      var rails = card.querySelectorAll('[role="group"][aria-label="Pending attachments"], [role="group"][aria-label="待发送附件"]');
      var count = 0;
      for (var i = 0; i < rails.length; i++) count += rails[i].children.length;
      return count;
    }
    return document.querySelectorAll('[data-attachment-id], [data-file-reference], [data-lexical-decorator="true"]').length;
  }

  // Read only: background recovery asks about this editor, never chat history.
  window.__dshAppPendingAttachmentCount = function () {
    var editor = composerEditor();
    return editor ? attachmentCount(editor) : 0;
  };

  window.__dshAppCompose = async function (draft) {
    var result = { text: false, files: 0 };
    // iOS correlates overlapping replies; legacy callers keep the same shape.
    if (draft && typeof draft.requestId === 'string') result.requestId = draft.requestId;
    // After whatever the app opened just before (a new conversation).
    var opening = window.__dshAppOpening;
    var opened;
    try { opened = await opening; } catch (e) { opened = false; }
    if (draft && draft.requireOpenedTarget === true) {
      // That opening is answered for now: one that failed mustn't refuse every later compose.
      if (window.__dshAppOpening === opening) window.__dshAppOpening = undefined;
      if (opening !== undefined && opened !== true) return post('DshAppCompose', result);
    }
    var editor = await waitFor(composerEditor, 10000);
    if (!editor) return post('DshAppCompose', result);
    if (draft && draft.requireOpenedTarget === true && opening && opening.newSessionBinding &&
        composerSession(editor) !== opening.newSessionBinding.confirmedSession) return post('DshAppCompose', result);
    var text = (draft && draft.text) || '';
    var files = (draft && draft.files) || [];
    editor.focus();
    var before = editor.textContent || '';
    var attachmentEditor = draft && draft.composerAttachmentCount === true ? editor : null;
    var beforeFiles = attachmentCount(attachmentEditor);
    try {
      var data = new DataTransfer();
      if (text) data.setData('text/plain', text);
      files.forEach(function (f) {
        var raw = atob(f.data || '');
        var bytes = new Uint8Array(raw.length);
        for (var i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
        data.items.add(new File([bytes], f.name, { type: f.type || 'application/octet-stream' }));
      });
      editor.dispatchEvent(new ClipboardEvent('paste', { clipboardData: data, bubbles: true, cancelable: true }));
    } catch (e) {}
    await sleep(400);
    var probe = text.trim().slice(0, 24);
    var landed = function () { return !probe || (editor.textContent || '').indexOf(probe) >= 0; };
    var canFallback = !draft || draft.guardTextFallback !== true ||
      (editor.isConnected && document.activeElement === editor);
    if (text && !landed() && (editor.textContent || '') === before && canFallback) {
      // No paste handling for text: type it in instead.
      try { document.execCommand('insertText', false, text); } catch (e) {}
      await sleep(200);
    }
    result.text = !!text && landed();
    result.files = Math.max(0, attachmentCount(attachmentEditor) - beforeFiles);
    post('DshAppCompose', result);
  };

  // Stores [target.session] as the selection the client restores at boot
  // and loads the page again; the rest of [target] runs on that load. At
  // most one hop per open. Not location.reload(): with a fragment in the
  // URL the WebView takes that as a same-document navigation and nothing
  // loads (a fresh WebView profile then hangs on its first open). A fresh
  // query makes it a new load; replace() keeps it out of the history.
  function hop(target) {
    if (target.hopped) return report(false, 'session');
    try {
      localStorage.setItem(STORE, JSON.stringify({ sessionId: target.session }));
      sessionStorage.setItem(PENDING, JSON.stringify(Object.assign({}, target, { hopped: true })));
      var url = new URL(location.href);
      url.searchParams.set(HOP_PARAM, String(Date.now()));
      location.replace(url.toString());
    } catch (e) {
      return report(false, 'session');
    }
  }

  // The names of a card, as the page could show them: trimmed, none empty
  // (an empty one would match any icon in the page).
  function labelsOf(list) {
    var labels = [];
    (Array.isArray(list) ? list : []).forEach(function (l) {
      var label = typeof l === 'string' ? l.replace(/\s+/g, ' ').trim() : '';
      if (label && labels.indexOf(label) < 0) labels.push(label);
    });
    return labels;
  }

  // How the open [r] went, unless it was stopped (a newer open, the person
  // taking over): then it says nothing.
  function finish(r, ok, step) {
    if (current === r) current = null;
    if (!r.stopped) report(ok, ok ? null : step);
    return !r.stopped && ok;
  }

  // [target] as the one open that acts from now on.
  function start(target) {
    if (current) current.stopped = true;
    var r = (current = { booted: false, stopped: false, until: Infinity });
    var opening = run(r, target);
    if (target.newSession && target.confirmNewSession === true) opening.newSessionBinding = r;
    return opening;
  }

  async function run(r, target) {
    if (!(await waitFor(sidebar, 15000, r))) return finish(r, false, 'boot');
    r.booted = true;
    r.until = Date.now() + STEPS_MS;
    if (target.session) {
      if (storedSession() !== target.session) return finish(r, false, 'session');
      // Selected but not on screen (a global panel is): boot shows it.
      var shown = await waitFor(function () {
        return document.querySelector('[data-slot="conversation.session"]');
      }, 3000, r);
      if (!shown) {
        if (target.hopped || !live(r)) return finish(r, false, 'session');
        if (current === r) current = null;
        return hop(target);
      }
    }
    var ok = true;
    var step = null;
    var labels = labelsOf(target.pluginItem);
    if (target.panel === 'cordis') {
      step = 'cordis';
      ok = await openCordis(r);
    } else if (target.panel) {
      step = 'panel';
      ok = await openPanel(r, target.panel);
    } else if (target.settings) {
      step = 'settings';
      ok = await openSettings(r, target.settings);
    } else if (target.pluginItem && target.pluginItem.length) {
      step = 'pluginItem';
      ok = labels.length > 0 && (await openPluginItem(r, labels));
    } else if (target.rightbar) {
      step = 'rightbar';
      ok = await openRightbar(r, target.rightbar);
    } else if (target.newSession) {
      step = 'newSession';
      ok = await startNewSession(r, target.confirmNewSession === true);
    } else if (target.sidebar) {
      step = 'sidebar';
      await sleep(400); // after the phone layout's collapse-on-arrival
      if (!live(r)) {
        ok = false;
      } else if (window.__dshApp && window.__dshApp.sidebarOpen) {
        if (!window.__dshApp.sidebarOpen()) window.__dshApp.toggleSidebar();
      } else {
        press(r, byName(sidebar(), 'button', LABELS.openSidebar));
      }
    }
    return finish(r, ok, step);
  }

  window.__dshAppOpen = function (target) {
    if (!target) return;
    // A session is picked by the stored selection the client restores at
    // boot (there are no session URLs): store it, load once more, go on there.
    if (target.session && storedSession() !== target.session) {
      if (current) current.stopped = true;
      current = null;
      return hop(target);
    }
    window.__dshAppOpening = start(target);
  };

  // Second half of a session hop: this load came from the hop above. Its
  // query leaves the address first (the history keeps the plain URL).
  try {
    var here = new URL(location.href);
    if (here.searchParams.has(HOP_PARAM)) {
      here.searchParams.delete(HOP_PARAM);
      history.replaceState(history.state, '', here.toString());
    }
  } catch (e) {}
  var pending = null;
  try {
    pending = JSON.parse(sessionStorage.getItem(PENDING) || 'null');
    sessionStorage.removeItem(PENDING);
  } catch (e) {}
  if (pending) window.__dshAppOpening = start(pending);
})();
