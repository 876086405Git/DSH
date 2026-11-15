/* Self-authored DOM adapter. Install in a Host-owned isolated WKContentWorld.
 * No navigation, network, approval, account/session access, or persistence here.
 * Host authorization and navigation-generation checks are required separately.
 */
(() => {
  'use strict';
  const VERSION = 2;
  const LIMIT_VISITS = 12000;
  const encoder = new TextEncoder();
  const nonce = () => Array.from(crypto.getRandomValues(new Uint32Array(4)), n => n.toString(16).padStart(8, '0')).join('');
  const pageId = nonce();
  const publicEpoch = () => {
    const n = crypto.getRandomValues(new Uint32Array(2));
    return (n[0] & 0x1fffff) * 0x100000000 + n[1] || 1;
  };
  let revision = 0;
  let current = null;
  let records = new Map();
  let removeListeners = [];
  const invalidate = () => { revision++; };
  const bytes = value => encoder.encode(JSON.stringify(value)).byteLength;
  const error = code => ({ error: code, ok: false, version: VERSION, code, requiresSnapshot: true });
  const bounded = (s, max = 200) => Array.from(String(s ?? '').replace(/\s+/gu, ' ').trim()).slice(0, max).join('');
  const attr = (el, key) => el.getAttribute(key) ?? '';
  const parent = el => el.parentElement || el.getRootNode()?.host || null;
  const tag = el => el.localName?.toLowerCase() ?? '';
  function clearListeners() {
    for (const remove of removeListeners) remove();
    removeListeners = [];
  }
  function listen(target, type) {
    target.addEventListener(type, invalidate, true);
    removeListeners.push(() => target.removeEventListener(type, invalidate, true));
  }
  function hidden(el, child = null) {
    for (let at = el; at; child = at, at = at.assignedSlot || parent(at) || at.ownerDocument.defaultView?.frameElement) {
      // Closed details content can retain layout boxes while its anonymous content is hidden.
      if (child && tag(at) === 'details' && !at.open && child !== at.querySelector(':scope > summary') &&
          at.ownerDocument.defaultView.getComputedStyle(at, '::details-content').contentVisibility === 'hidden') return true;
      if (at.hidden || at.inert || attr(at, 'aria-hidden') === 'true') return true;
      const style = at.ownerDocument.defaultView.getComputedStyle(at);
      if (style.display === 'none' || (style.display !== 'contents' && style.contentVisibility === 'hidden') || ((at === el || tag(at) === 'iframe') && (style.visibility === 'hidden' || style.visibility === 'collapse'))) return true;
      // A native control laid invisibly over something the page draws is still what a person taps.
      if (style.display !== 'contents' && Number(style.opacity) === 0 && !(at === el && ['input', 'select'].includes(tag(el)))) return true;
    }
    return false;
  }
  function rendered(el) {
    if (!el.isConnected || hidden(el)) return false;
    return Array.from(el.getClientRects()).some(r => r.width > 0 && r.height > 0);
  }
  // DOM click() bypasses pointer hit testing. Check one visible point immediately before
  // dispatch; do not scroll the page or invalidate unrelated dynamic page content.
  function hitAt(root, x, y) {
    let hit = root.elementFromPoint(x, y);
    while (hit?.shadowRoot?.elementFromPoint) {
      const inner = hit.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === hit) break;
      hit = inner;
    }
    return hit;
  }
  function hitsControl(hit, el) {
    for (let at = hit; at; at = at.assignedSlot || parent(at)) if (at === el) return true;
    // A transparent native checkbox may be activated through its associated label.
    const label = hit?.closest?.('label');
    if (!label || label.control !== el) return false;
    for (let at = hit; at && at !== label; at = parent(at)) {
      if (role(at) || at.tabIndex >= 0) return false;
    }
    return true;
  }
  function axisAlignedFrame(frame) {
    // A bounding rectangle cannot map a rotated, mirrored or perspective frame's point.
    // Refuse those layouts instead of guessing; ordinary translation/positive scale works.
    for (let at = frame; at; at = parent(at)) {
      const style = at.ownerDocument.defaultView.getComputedStyle(at);
      if (style.perspective !== 'none' || (style.rotate && style.rotate !== 'none')) return false;
      if (style.scale && style.scale !== 'none') {
        const scale = style.scale.split(/\s+/u).map(Number);
        if (scale.length > 2 || scale.some(n => !Number.isFinite(n) || n <= 0)) return false;
      }
      if (style.transform !== 'none') {
        const match = /^matrix\(([^)]+)\)$/u.exec(style.transform);
        if (!match) return false;
        const m = match[1].split(',').map(Number);
        if (m.length !== 6 || m.some(n => !Number.isFinite(n)) || m[1] !== 0 || m[2] !== 0 || m[0] <= 0 || m[3] <= 0) return false;
      }
    }
    return true;
  }
  function clickReachable(el) {
    let doc = el.ownerDocument;
    const win = doc.defaultView;
    const rect = Array.from(el.getClientRects()).find(r => r.width > 0 && r.height > 0);
    if (!win || !rect) return false;
    const left = Math.max(0, rect.left), right = Math.min(win.innerWidth, rect.right);
    const top = Math.max(0, rect.top), bottom = Math.min(win.innerHeight, rect.bottom);
    if (right <= left || bottom <= top) return false;
    let x = (left + right) / 2, y = (top + bottom) / 2;
    if (!hitsControl(hitAt(doc, x, y), el)) return false;
    while (doc !== document) {
      const frame = doc.defaultView?.frameElement;
      if (!frame || !frame.isConnected || frame.contentDocument !== doc || !axisAlignedFrame(frame)) return false;
      const box = frame.getBoundingClientRect();
      const style = frame.ownerDocument.defaultView.getComputedStyle(frame);
      const px = key => Number.parseFloat(style[key]) || 0;
      const insetX = px('borderLeftWidth') + px('paddingLeft');
      const insetY = px('borderTopWidth') + px('paddingTop');
      const width = px('width') + (style.boxSizing === 'border-box' ? 0 : insetX + px('borderRightWidth') + px('paddingRight'));
      const height = px('height') + (style.boxSizing === 'border-box' ? 0 : insetY + px('borderBottomWidth') + px('paddingBottom'));
      if (width <= 0 || height <= 0 || box.width <= 0 || box.height <= 0) return false;
      x = box.left + (insetX + x) * box.width / width;
      y = box.top + (insetY + y) * box.height / height;
      doc = frame.ownerDocument;
      if (hitAt(doc, x, y) !== frame) return false;
    }
    return true;
  }
  function textSnippet(el, max = 200) {
    const parts = []; let count = 0; let visits = 0;
    const stack = [el];
    while (stack.length && count < max && visits++ < 512) {
      const node = stack.pop();
      if (node.nodeType === Node.TEXT_NODE) {
        const piece = bounded(node.nodeValue, max - count);
        parts.push(piece); count += piece.length;
      } else if (node.nodeType === Node.ELEMENT_NODE && !['script', 'style', 'input', 'textarea'].includes(tag(node))) {
        for (let i = Math.min(node.childNodes.length, 512) - 1; i >= 0; i--) stack.push(node.childNodes[i]);
      }
    }
    return bounded(parts.join(' '), max);
  }
  function name(el) {
    const ids = attr(el, 'aria-labelledby').split(/\s+/u).filter(Boolean).slice(0, 8);
    const root = el.getRootNode();
    const labels = ids.map(id => root.getElementById?.(id));
    const labelled = labels.some(Boolean) ? labels.map(label => textSnippet(label || document.createTextNode(''))).join(' ') : '';
    return bounded(labelled || attr(el, 'aria-label') ||
      (el.labels ? Array.from(el.labels).map(label => textSnippet(label)).join(' ') : '') ||
      (tag(el) === 'input' && ['button', 'submit', 'reset'].includes(el.type) ? el.value : '') ||
      (['input', 'textarea'].includes(tag(el)) ? attr(el, 'placeholder') : textSnippet(el)) ||
      attr(el, 'alt') || attr(el, 'title'));
  }
  function role(el) {
    const explicit = attr(el, 'role').split(/\s/u)[0];
    if (explicit) return bounded(explicit, 40);
    switch (tag(el)) {
      case 'button': return 'button';
      case 'a': return el.hasAttribute('href') ? 'link' : '';
      case 'input':
        if (['button', 'submit', 'reset', 'image'].includes(el.type)) return 'button';
        if (['checkbox', 'radio', 'range'].includes(el.type)) return ({ range: 'slider' })[el.type] || el.type;
        return el.type === 'hidden' ? '' : 'textbox';
      case 'textarea': return 'textbox';
      case 'select': return el.multiple ? 'listbox' : 'combobox';
      case 'summary': return 'button';
      default: return el.isContentEditable ? 'textbox' : '';
    }
  }
  const paymentWords = /(?:credit.?card|card.?number|card.?holder|card.?security|\bcvv\b|\bcvc\b|checkout|payment|\bpay\b|purchase|付款|支付|银行卡|信用卡|结账)/iu;
  function ownSensitive(el) {
    if (tag(el) === 'input' && el.type === 'password') return 'password';
    const autocomplete = attr(el, 'autocomplete').toLowerCase().split(/\s+/u);
    if (autocomplete.some(v => v.startsWith('cc-') || v.startsWith('transaction-'))) return 'payment';
    if (paymentWords.test([attr(el, 'name'), attr(el, 'id'), attr(el, 'aria-label'), attr(el, 'placeholder')].join(' '))) return 'payment';
    return null;
  }
  function sensitive(el) {
    const own = ownSensitive(el);
    if (own) return own;
    const form = el.form || el.closest('form');
    if (form) {
      // Form-wide refusal prevents submitting a previously filled sensitive field.
      if (form.elements.length > 512) return 'uninspected-form';
      const controls = Array.from(form.elements || []);
      for (const control of controls) {
        const reason = ownSensitive(control);
        if (reason) return reason;
      }
      if (paymentWords.test(textSnippet(form, 2000))) return 'payment';
    }
    return paymentWords.test(name(el)) ? 'payment' : null;
  }
  function state(el) {
    const rect = el.getBoundingClientRect();
    const win = el.ownerDocument.defaultView;
    const value = {
      disabled: el.matches(':disabled') || attr(el, 'aria-disabled') === 'true',
      readOnly: el.readOnly === true || attr(el, 'aria-readonly') === 'true',
      inViewport: rect.bottom > 0 && rect.right > 0 && rect.top < win.innerHeight && rect.left < win.innerWidth,
    };
    if (['checkbox', 'radio'].includes(el.type)) value.checked = el.checked;
    if (el.type === 'checkbox') value.indeterminate = el.indeterminate;
    for (const key of ['expanded', 'pressed', 'selected']) if (el.hasAttribute('aria-' + key)) value[key] = bounded(attr(el, 'aria-' + key), 16);
    if (tag(el) === 'select') value.multiple = el.multiple;
    return value;
  }
  // What the model was told about an element, and so what has to still be true to act on it. The
  // rest of a live page changes all the time, and that's no reason to refuse. Scrolling a region
  // doesn't depend on what's in it, and neither scrolling nor a shifting layout changes a target.
  function submissionAction(el) {
    const submitter = (tag(el) === 'button' && el.type === 'submit') ||
      (tag(el) === 'input' && ['submit', 'image'].includes(el.type));
    if (!submitter || !el.form) return null;
    // Compare the effective destination, including a submitter override. Kept internal.
    return el.hasAttribute('formaction') ? el.formAction : el.form.action;
  }
  function fingerprint(el, region = false) {
    if (region) return JSON.stringify({ tag: tag(el), document: el.ownerDocument.location.href });
    const { inViewport, ...steady } = state(el);
    // A list can reuse a row's nodes for another item: the same Remove button, a different thing to remove.
    const row = el.closest?.('li, tr, dialog, [role=row], [role=listitem], [role=dialog], [role=alertdialog]');
    const article = el.closest?.('article, [role=article]');
    return JSON.stringify({ submissionAction: submissionAction(el), tag: tag(el), role: role(el), name: name(el), type: el.type || '',
      state: steady, sensitive: sensitive(el), row: row ? textSnippet(row, 400) : null,
      article: article ? textSnippet(article, 400) : null,
      // Values remain internal and are never returned/logged. Sensitive values aren't read.
      value: sensitive(el) ? null : (['input', 'textarea', 'select'].includes(tag(el)) ? el.value.slice(0, 16385) : null),
      href: tag(el) === 'a' ? el.href : null,
      options: tag(el) === 'select' && !sensitive(el) ? Array.from(el.options).slice(0, 256).map(o => ({
        name: bounded(attr(o, 'label') || o.textContent), value: o.value,
        disabled: o.disabled || o.parentElement?.disabled === true, selected: o.selected,
      })) : null,
      document: el.ownerDocument.location.href,
    });
  }
  const isRegion = role => role === 'document' || role === 'scroll-region';
  function scrollable(el) {
    const style = el.ownerDocument.defaultView.getComputedStyle(el);
    return ((el.scrollHeight > el.clientHeight && /auto|scroll/u.test(style.overflowY)) ||
      (el.scrollWidth > el.clientWidth && /auto|scroll/u.test(style.overflowX))) && rendered(el);
  }
  function capture(options = {}) {
    if (!options || typeof options !== 'object' || Array.isArray(options)) return error('INVALID_ARGUMENT');
    const maxBytes = options.maxBytes ?? 49152;
    const maxElements = options.maxElements ?? 128;
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 2048 || maxBytes > 262144 ||
        !Number.isSafeInteger(maxElements) || maxElements < 1 || maxElements > 256) return error('INVALID_ARGUMENT');
    clearListeners();
    revision++;
    records = new Map();
    let nextEpoch; do { nextEpoch = publicEpoch(); } while (nextEpoch === current?.epoch);
    current = { snapshotId: nonce(), revision, href: location.href, epoch: nextEpoch };
    const result = { ok: true, version: VERSION, pageId, snapshotId: current.snapshotId, revision,
      untrusted: true, text: '', elements: [], truncated: false,
      limitations: ['mounted-dom-only', 'cross-origin-frames-unavailable', 'closed-shadow-and-canvas-unavailable', 'synthetic-events-only'] };
    let visits = 0;
    const seen = new Set();
    function add(el, context, specialRole = '') {
      if (records.size >= maxElements) { result.truncated = true; return; }
      const id = 'e' + (records.size + 1).toString(36);
      const item = { id, role: specialRole || role(el), name: specialRole === 'document' ? 'Page' : name(el), state: state(el), sensitive: sensitive(el), context };
      const options = new Map();
      if (tag(el) === 'select' && !item.sensitive) {
        item.options = [];
        for (let index = 0; index < Math.min(el.options.length, 64); index++) {
          const option = el.options[index];
          const optionId = 'o' + index.toString(36);
          options.set(optionId, option);
          item.options.push({ id: optionId, name: bounded(attr(option, 'label') || option.textContent), disabled: option.disabled || option.parentElement?.disabled === true, selected: option.selected });
        }
        if (el.options.length > 64) result.truncated = true;
      }
      result.elements.push(item);
      if (bytes(result) > maxBytes) { result.elements.pop(); result.truncated = true; return; }
      records.set(id, { el, fingerprint: fingerprint(el, isRegion(specialRole)), document: el.ownerDocument, specialRole, options });
    }
    function text(value) {
      const chars = Array.from(String(value ?? '').replace(/\s+/gu, ' ').trim());
      const piece = chars.slice(0, 2000).join('');
      if (chars.length > 2000) result.truncated = true;
      if (!piece) return;
      const before = result.text;
      result.text += (before ? '\n' : '') + piece;
      if (result.text.length > maxBytes / 2 || bytes(result) > maxBytes || encoder.encode(result.text).byteLength > maxBytes / 2) { result.text = before; result.truncated = true; }
    }
    function walk(node, context) {
      if (++visits > LIMIT_VISITS) { result.truncated = true; return; }
      if (node.nodeType === Node.TEXT_NODE) {
        if (node.parentElement && !hidden(node.assignedSlot || node.parentElement, node)) {
          const range = node.ownerDocument.createRange();
          range.selectNodeContents(node);
          if (Array.from(range.getClientRects()).some(r => r.width > 0 && r.height > 0)) text(node.nodeValue);
          range.detach();
        }
        return;
      }
      if (node.nodeType !== Node.ELEMENT_NODE) return;
      const el = node;
      if (['script', 'style', 'noscript', 'template'].includes(tag(el))) return;
      if (hidden(el)) return;
      const interactive = role(el) || el.tabIndex >= 0;
      if (interactive && rendered(el)) add(el, context, role(el) || 'focusable');
      else if (scrollable(el)) add(el, context, 'scroll-region');
      if (tag(el) === 'iframe') {
        try {
          // contentDocument is exposed only when SOP permits access; unlike
          // location.origin strings this also handles inherited srcdoc origins.
          const child = el.contentDocument;
          if (child && child.documentElement) {
            walkRoot(child, context + '/frame');
          }
        } catch { /* Cross-origin frames intentionally unavailable. */ }
        return;
      }
      if (['input', 'textarea', 'select'].includes(tag(el))) return;
      if (el.shadowRoot) walkRoot(el.shadowRoot, context + '/shadow');
      for (const child of el.childNodes) {
        if (visits >= LIMIT_VISITS) { result.truncated = true; break; }
        walk(child, context);
      }
    }
    function walkRoot(root, context) {
      if (seen.has(root)) return;
      seen.add(root);
      if (root.nodeType === Node.DOCUMENT_NODE) {
        // A frame reloading only matters to what's in it, and those targets check for themselves.
        if (root === document) { listen(window, 'pagehide'); listen(window, 'popstate'); }
        if (root.scrollingElement) add(root.scrollingElement, context, 'document');
      }
      for (const child of root.childNodes) walk(child, context);
    }
    walkRoot(document, 'main');
    // Reserve room was checked after each addition; true is shorter than false.
    return result;
  }
  function perform(request) {
    if (!request || request.version !== VERSION || !['click', 'fill', 'select', 'scroll', 'key'].includes(request.kind)) return error('INVALID_ARGUMENT');
    const allowed = ['version', 'pageId', 'snapshotId', 'revision', 'target', 'kind', ...({ click: [], fill: ['value'], select: ['values'], scroll: ['dx', 'dy'], key: ['key'] })[request.kind]];
    if (Object.keys(request).some(key => !allowed.includes(key))) return error('INVALID_ARGUMENT');
    if (!current || request.pageId !== pageId || request.snapshotId !== current.snapshotId ||
        request.revision !== current.revision || revision !== current.revision || location.href !== current.href) return error('STALE_SNAPSHOT');
    const record = records.get(request.target);
    if (!record) return error('TARGET_UNAVAILABLE');
    const el = record.el;
    if (!el.isConnected || el.ownerDocument !== record.document) return error('TARGET_UNAVAILABLE');
    // The top-level viewport can scroll even when an all-absolute page's root box is empty.
    const visible = record.specialRole === 'document' && record.document === document
      ? el === document.scrollingElement && !hidden(el) : rendered(el);
    if (!visible) return error('TARGET_UNAVAILABLE');
    if (fingerprint(el, isRegion(record.specialRole)) !== record.fingerprint) return error('TARGET_CHANGED');
    if (sensitive(el)) return error('SENSITIVE_TARGET');
    if (state(el).disabled) return error('TARGET_DISABLED');
    const finish = result => { current = null; records.clear(); invalidate(); return result; };
    try {
      switch (request.kind) {
        case 'click':
          if (record.specialRole === 'document' || !['button', 'link', 'checkbox', 'radio', 'tab', 'menuitem', 'option', 'switch', 'focusable'].includes(role(el) || record.specialRole)) return error('UNSUPPORTED_TARGET');
          if (typeof el.click !== 'function') return error('UNSUPPORTED_TARGET');
          if (!clickReachable(el)) return error('TARGET_OBSCURED_OR_NOT_IN_VIEW');
          HTMLElement.prototype.click.call(el);
          break;
        case 'fill': {
          if (typeof request.value !== 'string' || encoder.encode(request.value).byteLength > 16384) return error('INVALID_ARGUMENT');
          if (state(el).readOnly) return error('TARGET_READONLY');
          if (typeof el.value === 'string' && el.value.length > 16384) return error('TARGET_TOO_LARGE');
          if (!(tag(el) === 'textarea' || (tag(el) === 'input' && ['text', 'search', 'email', 'tel', 'url'].includes(el.type)))) return error('UNSUPPORTED_TARGET');
          const prototype = tag(el) === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          Object.getOwnPropertyDescriptor(prototype, 'value').set.call(el, request.value);
          el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
          if (!el.isConnected || sensitive(el)) return finish(error('TARGET_CHANGED_AFTER_INPUT'));
          el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
          break;
        }
        case 'select': {
          if (tag(el) !== 'select' || el.options.length > 256 || state(el).readOnly) return error('UNSUPPORTED_TARGET');
          if (!Array.isArray(request.values) || request.values.length > 64 || request.values.some(x => typeof x !== 'string' || x.length > 2000) || (!el.multiple && request.values.length !== 1)) return error('INVALID_ARGUMENT');
          const selected = request.values.map(id => record.options.get(id));
          if (selected.some(o => !o || !o.isConnected || o.closest('select') !== el || o.disabled || o.parentElement?.disabled)) return error('INVALID_OPTION');
          for (const option of el.options) option.selected = selected.includes(option);
          el.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
          if (!el.isConnected || sensitive(el)) return finish(error('TARGET_CHANGED_AFTER_INPUT'));
          el.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
          break;
        }
        case 'scroll':
          if (![request.dx, request.dy].every(x => Number.isFinite(x) && Math.abs(x) <= 10000)) return error('INVALID_ARGUMENT');
          if (record.specialRole !== 'document' && !scrollable(el)) return error('UNSUPPORTED_TARGET');
          el.scrollBy({ left: request.dx, top: request.dy, behavior: 'instant' });
          break;
        case 'key':
          if (!['Enter', 'Escape', 'Tab', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'Backspace', 'Delete'].includes(request.key)) return error('INVALID_ARGUMENT');
          el.dispatchEvent(new KeyboardEvent('keydown', { key: request.key, bubbles: true, composed: true }));
          if (!el.isConnected || sensitive(el)) return finish(error('TARGET_CHANGED_AFTER_INPUT'));
          el.dispatchEvent(new KeyboardEvent('keyup', { key: request.key, bubbles: true, composed: true }));
          break;
      }
      return finish({ ok: true, version: VERSION, kind: request.kind, requiresSnapshot: true,
        effect: request.kind === 'key' ? 'synthetic-key-events-no-default-action' : 'dom-api-dispatched-not-business-confirmation' });
    } catch {
      return finish(error('ACTION_ERROR_RESULT_UNKNOWN'));
    }
  }
  function snapshot(options) {
    try { return capture(options); }
    catch { current = null; records.clear(); clearListeners(); return error('SNAPSHOT_UNAVAILABLE'); }
  }
  function action(request) {
    try { return perform(request); }
    catch { current = null; records.clear(); invalidate(); return error('PAGE_CHANGED_OR_UNAVAILABLE'); }
  }
  // Codable's Int wire accepts positive JS-safe integers. Random per read/page; not an authorization secret.
  const epochFor = () => current?.epoch ?? null;
  function read(options = {}) {
    if (!options || typeof options !== 'object' || Array.isArray(options) || Object.keys(options).some(k => k !== 'maxBytes')) return error('INVALID_ARGUMENT');
    const observed = snapshot(options);
    if (!observed.ok) return observed;
    const maxBytes = options.maxBytes ?? 49152;
    // Host has the authoritative navigation URL. Avoid echoing query/fragment
    // tokens in this untrusted page observation; no URL is used for authorization.
    const visibleUrl = ['http:', 'https:'].includes(location.protocol) ? location.origin + location.pathname : location.protocol;
    const result = { url: bounded(visibleUrl, 256), title: bounded(document.title, 200),
      text: observed.text,
      elements: observed.elements.map(item => ({ ref: item.id, role: item.role, name: item.name,
        state: { ...item.state, context: item.context,
          ...(item.options ? { options: item.options.map(option => ({ ref: option.id, name: option.name, disabled: option.disabled, selected: option.selected })) } : {}),
          ...(item.sensitive ? { sensitiveReason: item.sensitive } : {}) },
        sensitive: Boolean(item.sensitive) })),
      truncated: observed.truncated, epoch: epochFor(), untrusted: true, limitations: observed.limitations };
    while (bytes(result) > maxBytes && result.elements.length) {
      const removed = result.elements.pop(); records.delete(removed.ref); result.truncated = true;
    }
    if (bytes(result) > maxBytes) {
      const chars = Array.from(result.text); let low = 0; let high = chars.length;
      result.truncated = true;
      while (low < high) {
        const middle = Math.ceil((low + high) / 2); result.text = chars.slice(0, middle).join('');
        if (bytes(result) <= maxBytes) low = middle; else high = middle - 1;
      }
      result.text = chars.slice(0, low).join('');
    }
    if (bytes(result) > maxBytes) { result.url = ''; result.title = ''; result.truncated = true; }
    return result;
  }
  function act(request) {
    if (!request || typeof request !== 'object' || Array.isArray(request) ||
        !['click', 'fill', 'select', 'scroll', 'press'].includes(request.kind)) return error('INVALID_ARGUMENT');
    const field = { fill: 'value', select: 'value', scroll: 'direction', press: 'key' }[request.kind];
    const allowed = ['ref', 'epoch', 'kind', ...(field ? [field] : [])];
    if (Object.keys(request).some(k => !allowed.includes(k)) ||
        (field && !Object.hasOwn(request, field))) return error('INVALID_ARGUMENT');
    if (!Number.isSafeInteger(request.epoch) || request.epoch < 1) return error('INVALID_ARGUMENT');
    if (!current || request.epoch !== epochFor()) return error('STALE_SNAPSHOT');
    const internal = { version: VERSION, pageId, snapshotId: current.snapshotId,
      revision: current.revision, target: request.ref, kind: request.kind === 'press' ? 'key' : request.kind };
    if (request.kind === 'fill') internal.value = request.value;
    if (request.kind === 'select') {
      if (typeof request.value !== 'string') return error('INVALID_ARGUMENT');
      internal.values = [request.value];
    }
    if (request.kind === 'press') internal.key = request.key;
    if (request.kind === 'scroll') {
      if (!['up', 'down', 'left', 'right'].includes(request.direction)) return error('INVALID_ARGUMENT');
      const el = records.get(request.ref)?.el;
      if (!el) return error('TARGET_UNAVAILABLE');
      // One bounded page step within the selected document/scroll region.
      const width = Math.max(1, Math.min(10000, el.clientWidth * 0.8));
      const height = Math.max(1, Math.min(10000, el.clientHeight * 0.8));
      internal.dx = request.direction === 'left' ? -width : request.direction === 'right' ? width : 0;
      internal.dy = request.direction === 'up' ? -height : request.direction === 'down' ? height : 0;
    }
    const result = action(internal);
    if (result.ok && request.kind === 'press') result.kind = 'press';
    return result;
  }
  Object.defineProperty(globalThis, '__dshBrowser', { value: Object.freeze({ read, act }), configurable: false, writable: false });
})();
