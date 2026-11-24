// A single same-origin document. The Worker hashes this exact script string
// for CSP; no template interpolates submission data or the administrator key.
export const WORKSHOP_ADMIN_SCRIPT = String.raw`
'use strict';
/* WORKSHOP_ADMIN_LOGIC_START */
const adminLogic = (() => {
  const base = '/api/workshop/v1/admin';
  const statuses = ['draft', 'pending', 'approved', 'rejected', 'withdrawn'];
  const kinds = ['pet', 'companion', 'theme'];
  const media = ['image/png', 'image/jpeg', 'image/webp'];
  const fail = (code) => { throw { code: code || 'console_bad_response', unknown: false }; };
  const sid = (value) => typeof value === 'string' && /^[a-f0-9]{32}$/.test(value);
  const object = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
  const reasonValid = (value) => typeof value === 'string' && !/^[\s\u0085]*$/u.test(value) &&
    Array.from(value).length <= 2000 && !/[\u0000-\u001f\ud800-\udfff]/u.test(value);
  const plain = (value) => value === null || value === undefined ? '—' : String(value);
  const text = (node, value) => { node.textContent = plain(value); return node; };
  const jsonText = (value) => JSON.stringify(value, null, 2);
  function checkedId(value) { if (!sid(value)) fail('console_invalid_target'); return value; }
  function index(value) {
    const number = typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value) ? Number(value) : value;
    if (!Number.isSafeInteger(number) || number < 0) fail('console_invalid_target');
    return String(number);
  }
  function query(values) {
    const pairs = Object.entries(values).filter(([, value]) => value !== null && value !== undefined && value !== '');
    return pairs.length ? '?' + pairs.map(([key, value]) => encodeURIComponent(key) + '=' + encodeURIComponent(String(value))).join('&') : '';
  }
  function request(operation, params, key) {
    if (typeof key !== 'string' || key.length < 32 || key.length > 4096) fail('console_invalid_key');
    const p = params || {};
    let path, body;
    if (operation === 'submissions' || operation === 'reports') {
      if (p.kind && !kinds.includes(p.kind)) fail('console_invalid_filter');
      const allowed = operation === 'submissions' ? statuses : ['open', 'resolved'];
      if (p.status && !allowed.includes(p.status)) fail('console_invalid_filter');
      if (p.cursor !== null && p.cursor !== undefined && !sid(p.cursor)) fail('console_invalid_cursor');
      path = '/' + operation + query({ status: p.status, kind: p.kind, limit: 20, cursor: p.cursor });
    } else if (operation === 'submission') {
      path = '/submissions/' + checkedId(p.id) + query({ filesLimit: 50,
        filesCursor: p.filesCursor === null || p.filesCursor === undefined ? null : index(p.filesCursor) });
    } else if (operation === 'preview') {
      path = '/submissions/' + checkedId(p.id) + '/preview' + query({ file: index(p.file) });
    } else if (operation === 'publicPreview') {
      path = '/submissions/' + checkedId(p.id) + '/public-preview';
    } else if (operation === 'report') {
      path = '/reports/' + checkedId(p.id);
    } else if (operation === 'audit') {
      if (p.cursor !== null && p.cursor !== undefined && !sid(p.cursor)) fail('console_invalid_cursor');
      path = '/audit' + query({ limit: 20, cursor: p.cursor });
    } else {
      if (!reasonValid(p.reason)) fail('console_bad_reason');
      if (operation === 'review') {
        if (!['approve', 'reject'].includes(p.decision)) fail('console_invalid_action');
        path = '/submissions/' + checkedId(p.id) + '/review';
        body = { decision: p.decision, reason: p.reason };
      } else if (operation === 'withdraw') {
        path = '/submissions/' + checkedId(p.id) + '/withdraw'; body = { reason: p.reason };
      } else if (operation === 'resolve') {
        if (!['handled', 'dismissed'].includes(p.decision)) fail('console_invalid_action');
        path = '/reports/' + checkedId(p.id) + '/resolve'; body = { decision: p.decision, reason: p.reason };
      } else if (operation === 'releaseWithdraw') {
        if (!kinds.includes(p.kind) || typeof p.releaseId !== 'string' || typeof p.version !== 'string') fail('console_invalid_target');
        path = '/releases/withdraw'; body = { kind: p.kind, id: p.releaseId, version: p.version, reason: p.reason };
      } else if (operation === 'rework') {
        if (p.version && !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$/.test(p.version)) fail('console_invalid_target');
        if (p.preview !== undefined && p.preview !== null && typeof p.preview !== 'string') fail('console_invalid_target');
        path = '/submissions/' + checkedId(p.id) + '/rework';
        body = { reason: p.reason, ...(p.version ? { version: p.version } : {}), ...(p.preview ? { preview: p.preview } : {}) };
      } else fail('console_invalid_action');
    }
    const headers = { 'X-Admin-Key': key, Accept: operation === 'preview' ? 'image/png, image/jpeg, image/webp'
      : operation === 'publicPreview' ? 'image/png' : 'application/json' };
    if (body) headers['Content-Type'] = 'application/json';
    return { path: base + path, options: { method: body ? 'POST' : 'GET', headers,
      credentials: 'omit', cache: 'no-store', redirect: 'error', ...(body ? { body: JSON.stringify(body) } : {}) } };
  }
  function submission(value) {
    if (!object(value) || !sid(value.submissionId) || !statuses.includes(value.status) ||
        !object(value.owner) || typeof value.owner.username !== 'string' ||
        !object(value.metadata) || !kinds.includes(value.metadata.kind) ||
        !object(value.metadata.title) || typeof value.metadata.title.zh !== 'string' || typeof value.metadata.title.en !== 'string') fail();
    if (value.preview !== undefined) {
      const p = value.preview, m = value.metadata;
      if (!object(p) || typeof p.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(p.sha256) ||
          !Number.isSafeInteger(p.size) || p.size < 1 || p.size > 2097152 ||
          !Number.isSafeInteger(p.width) || !Number.isSafeInteger(p.height) || p.width < 1 || p.height < 1 ||
          p.width > 512 || p.height > 512 || p.width * p.height > 262144 ||
          typeof m.id !== 'string' || !/^[a-z0-9][a-z0-9-]{0,39}$/.test(m.id) ||
          typeof m.version !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$/.test(m.version) ||
          typeof m.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(m.sha256) ||
          p.path !== '/market/workshop/' + m.kind + '/' + m.id + '/' + m.version + '/' + m.sha256 + '/preview/' + p.sha256 + '.png') fail();
    }
    return value;
  }
  function report(value) {
    if (!object(value) || !sid(value.reportId) || !['open', 'resolved'].includes(value.status) ||
        !kinds.includes(value.kind) || typeof value.id !== 'string' || typeof value.version !== 'string' ||
        typeof value.reason !== 'string' || !object(value.reporter) || typeof value.reporter.username !== 'string') fail();
    return value;
  }
  function pageData(value, view) {
    const field = view === 'submissions' ? 'submissions' : view === 'reports' ? 'reports' : 'events';
    if (!object(value) || !Array.isArray(value[field]) || value[field].length > 20 ||
        value.nextCursor !== null && !sid(value.nextCursor)) fail();
    const rows = value[field].map((row) => view === 'submissions' ? submission(row) : view === 'reports' ? report(row) :
      object(row) && sid(row.eventId) ? row : fail());
    return { rows, next: value.nextCursor };
  }
  function detail(value, id) {
    const item = submission(value && value.submission), inspection = value.inspection;
    if (item.submissionId !== id || typeof value.current !== 'boolean' || !object(inspection) ||
        !['valid', 'invalid', 'not_uploaded'].includes(inspection.status) ||
        !Array.isArray(inspection.checks) || !Array.isArray(inspection.files) || inspection.files.length > 100 ||
        inspection.nextFileCursor !== null && (typeof inspection.nextFileCursor !== 'string' || !/^(0|[1-9][0-9]*)$/.test(inspection.nextFileCursor))) fail();
    for (const file of inspection.files) {
      if (!object(file) || !Number.isSafeInteger(file.index) || file.index < 0 || typeof file.path !== 'string' ||
          !Number.isSafeInteger(file.size) || file.size < 0 || !Number.isSafeInteger(file.compressedSize) || file.compressedSize < 0) fail();
      if (file.preview !== null && (!object(file.preview) || !media.includes(file.preview.mediaType) ||
          !['full-png', 'structure-only'].includes(file.preview.validation) ||
          !Number.isSafeInteger(file.preview.width) || !Number.isSafeInteger(file.preview.height) || file.preview.width < 1 || file.preview.height < 1)) fail();
      if (file.previewIssue !== null && (!object(file.previewIssue) || typeof file.previewIssue.code !== 'string' || typeof file.previewIssue.message !== 'string')) fail();
    }
    if (inspection.checks.some((check) => !object(check) || !['pass', 'error', 'info'].includes(check.level) ||
        typeof check.code !== 'string' || typeof check.message !== 'string')) fail();
    return value;
  }
  function reportDetail(value, id) {
    const item = report(value && value.report), target = value.target;
    if (item.reportId !== id || !object(target) || !object(target.release) ||
        target.release.kind !== item.kind || target.release.id !== item.id || target.release.version !== item.version ||
        typeof target.current !== 'boolean' || target.withdrawal !== null && !object(target.withdrawal)) fail();
    return value;
  }
  function writeResult(value, command) {
    if (command.operation === 'review' || command.operation === 'withdraw') {
      const item = submission(value && value.submission);
      const expected = command.operation === 'withdraw' ? 'withdrawn' : command.params.decision === 'approve' ? 'approved' : 'rejected';
      if (item.submissionId !== command.params.id || item.status !== expected) fail();
    } else if (command.operation === 'rework') {
      const item = submission(value && value.submission);
      if (item.status !== 'approved') fail();
    } else if (command.operation === 'resolve') {
      const item = reportDetail(value, command.params.id).report;
      if (item.status !== 'resolved' || !object(item.resolution) || item.resolution.decision !== command.params.decision) fail();
    } else {
      const item = value && value.withdrawn;
      if (!object(item) || item.kind !== command.params.kind || item.id !== command.params.releaseId || item.version !== command.params.version) fail();
    }
    return value;
  }
  function failure(status, value, mutation) {
    const candidate = object(value) ? value.error : null;
    const code = typeof candidate === 'string' && /^workshop_[a-z0-9_]{1,100}$/.test(candidate)
      ? candidate : status ? 'console_http_' + status : 'console_network';
    return { code, status, unknown: !!mutation && (status === 0 || status >= 500 || status >= 300 && status < 400) };
  }
  function book(session) { return { session: session || 0, lanes: {} }; }
  function nextTicket(previous, lane, target) {
    const sequence = (previous.lanes[lane] || 0) + 1;
    return { book: { session: previous.session, lanes: { ...previous.lanes, [lane]: sequence } },
      ticket: Object.freeze({ session: previous.session, lane, sequence, target }) };
  }
  function current(previous, ticket, target) {
    return !!ticket && previous.session === ticket.session && previous.lanes[ticket.lane] === ticket.sequence && ticket.target === target;
  }
  function emptyPage(filters) {
    return { filters, rows: [], cursor: null, back: [], next: null, loaded: false, loading: false, error: null, pending: null };
  }
  function beginPage(previous, ticket, filters, cursor, back) {
    const changed = JSON.stringify(previous.filters) !== JSON.stringify(filters);
    const basePage = changed ? emptyPage(filters) : previous;
    return { ...basePage, loading: true, error: null, pending: { ticket, filters, cursor, back: back.slice() } };
  }
  function finishPage(previous, ticket, result, error) {
    if (!previous.pending || previous.pending.ticket !== ticket) return previous;
    if (error) return { ...previous, loading: false, pending: null, error };
    return { ...previous, ...result, cursor: previous.pending.cursor, back: previous.pending.back,
      filters: previous.pending.filters, loaded: true, loading: false, pending: null, error: null };
  }
  function writeState(target, error) {
    return { target, phase: !error ? 'acknowledged' : error.unknown ? 'unknown' : 'rejected', error: error || null,
      requiresRead: !!(error && error.unknown), observed: false };
  }
  function observed(previous, target) {
    return previous && previous.target === target ? { ...previous, requiresRead: false, observed: true } : previous;
  }
  function confirmation(operation, params, title, session, target, readTicket) {
    if (!reasonValid(params.reason)) fail('console_bad_reason');
    return Object.freeze({ operation, params: Object.freeze({ ...params }), title: plain(title), session, target, readTicket });
  }
  function canConfirm(value, previous, target, busy) {
    return !!value && !!value.readTicket && !busy && value.session === previous.session && value.target === target &&
      current(previous, value.readTicket, value.readTicket.target);
  }
  function previewBytes(bytes, type) {
    if (!media.includes(type) || !(bytes instanceof Uint8Array) || bytes.length > 8 * 1024 * 1024) return false;
    if (type === 'image/png') return bytes.length >= 8 && [137,80,78,71,13,10,26,10].every((value, i) => bytes[i] === value);
    if (type === 'image/jpeg') return bytes.length >= 3 && bytes[0] === 255 && bytes[1] === 216 && bytes[2] === 255;
    return bytes.length >= 12 && [82,73,70,70].every((value, i) => bytes[i] === value) && [87,69,66,80].every((value, i) => bytes[i + 8] === value);
  }
  const statusName = (value) => ({ draft: '尚未上传', pending: '待审核', approved: '已通过', rejected: '已拒绝', withdrawn: '已撤回', open: '未处理', resolved: '已处理' }[value] || plain(value));
  const kindName = (value) => ({ pet: '像素宠物', companion: 'Live2D 伙伴', theme: '主题包' }[value] || plain(value));
  const actor = (value) => value === 'admin' ? '管理密钥持有人（admin）' : object(value)
    ? plain(value.username) + ' · GitHub · 用户 ' + plain(value.accountId) : plain(value);
  const size = (value) => Number.isSafeInteger(value) && value >= 0 ? value.toLocaleString('zh-CN') + ' 字节' : plain(value);
  function validation(value) {
    if (!value) return '尚无已通过的包校验记录';
    return plain(value.validator) + '；' + plain(value.files) + ' 个文件；展开后 ' + size(value.expandedBytes);
  }
  return Object.freeze({ request, submission, report, pageData, detail, reportDetail, writeResult, failure,
    book, nextTicket, current, emptyPage, beginPage, finishPage, writeState, observed, confirmation, canConfirm,
    reasonValid, previewBytes, text, plain, jsonText, statusName, kindName, actor, size, validation });
})();
/* WORKSHOP_ADMIN_LOGIC_END */

/* WORKSHOP_ADMIN_UI_START */
(() => {
  const L = adminLogic;
  const byId = (id) => document.getElementById(id);
  const views = ['submissions', 'reports', 'audit'];
  let secret = '', connected = false, activeView = 'submissions', tickets = L.book(0), mutation = null, offered = null;
  let pages = initialPages(), selectedSubmission = null, submissionDetail = null, submissionTicket = null;
  let submissionLoading = false, submissionError = null, selectedReport = null, reportDetail = null, reportTicket = null;
  let reportLoading = false, reportError = null, imageUrl = null, imageTarget = null, focusBeforeConfirmation = null;
  let publicImageUrl = null, publicImageTarget = null, publicImageLoading = false, publicImageReady = false;
  const controllers = new Map(), writes = new Map();
  function initialPages() {
    return { submissions: L.emptyPage({ status: 'pending', kind: '' }),
      reports: L.emptyPage({ status: 'open', kind: '' }), audit: L.emptyPage({}) };
  }
  /* WORKSHOP_ADMIN_TEXT_DOM_START */
  function node(tag, value, className) {
    const element = document.createElement(tag);
    if (value !== undefined) L.text(element, value);
    if (className) element.className = className;
    return element;
  }
  function pair(parent, label, value) {
    const line = node('p', undefined, 'pair');
    line.append(node('strong', label + '：'), document.createTextNode(L.plain(value)));
    parent.append(line);
  }
  /* WORKSHOP_ADMIN_TEXT_DOM_END */
  function actionButton(label, listener) {
    const button = node('button', label); button.type = 'button'; button.disabled = !!mutation;
    button.addEventListener('click', listener); return button;
  }
  function notice(id, message, error) {
    const element = byId(id);
    element.hidden = !message;
    element.className = error ? 'notice error' : 'notice';
    L.text(element, message || '');
  }
  function errorText(error) {
    const messages = {
      console_invalid_key: '请输入 32 至 4096 个字符的管理密钥。密钥不会被自动修剪或保存。',
      console_bad_reason: '请填写不超过 2000 个 Unicode 字符的非空理由；不要包含换行或控制字符。',
      console_invalid_target: '当前对象无效，请重新读取后再操作。',
      console_invalid_filter: '筛选条件无效，请重新选择。',
      console_bad_response: '服务器响应不符合当前接口，请重新读取并检查部署版本。',
      console_network: '网络请求未能完成，请检查连接后手动重试读取。',
      console_timeout: '请求已超时，请手动刷新具体对象核对状态。',
      console_preview_type: '这份响应不是允许的 PNG、JPEG 或 WebP 图片，未显示。',
      console_preview_size: '图片超过 8 MiB 预览上限，未显示。',
      console_public_preview_type: '公开预览必须为 PNG，未显示这份响应。',
      console_public_preview_integrity: '公开预览的字节数或摘要与本次投稿登记不符，未显示。请重新读取投稿核对。',
      console_public_preview_dimensions: '公开预览 PNG 头的像素尺寸与本次投稿登记不符，未显示。',
      console_confirmation_stale: '确认时展示的对象已变化，请重新读取并再次确认。',
      workshop_admin_auth_required: '管理密钥未通过校验，请重新输入。',
      workshop_admin_unavailable: '服务器尚未正确配置管理密钥，请检查部署设置。',
      workshop_state_conflict: '服务器状态已变化，请刷新该条后重新判断。',
      workshop_submission_state: '投稿状态已变化，请刷新该条。',
      workshop_report_state: '举报已有不同的处理结果，请刷新该条。',
      workshop_rate_limited: '请求过于频繁，请稍后手动重试。',
      workshop_preview_unsupported: '此文件不支持安全图片预览，仍可查看文件清单。'
    };
    const code = error && typeof error.code === 'string' ? error.code : 'console_bad_response';
    return (messages[code] || '请求未成功，请根据错误码检查后重试读取。') + '\n错误码：' + code;
  }
  function next(lane, target) {
    const old = controllers.get(lane); if (old) old.abort();
    const value = L.nextTicket(tickets, lane, target); tickets = value.book; return value.ticket;
  }
  const current = (ticket, target) => connected && L.current(tickets, ticket, target);
  async function request(operation, params, lane) {
    const plan = L.request(operation, params, secret), controller = new AbortController();
    controllers.set(lane, controller);
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, 30000);
    const isWrite = plan.options.method === 'POST';
    try {
      const response = await fetch(plan.path, { ...plan.options, signal: controller.signal });
      if (!response.ok) {
        let body = null; try { body = await response.json(); } catch (_) { /* Stable status only. */ }
        throw L.failure(response.status, body, isWrite);
      }
      if (operation === 'preview') {
        const type = (response.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
        if (type !== params.mediaType || !['image/png', 'image/jpeg', 'image/webp'].includes(type)) {
          controller.abort(); throw { code: 'console_preview_type', unknown: false };
        }
        const length = Number(response.headers.get('content-length'));
        if (Number.isFinite(length) && length > 8 * 1024 * 1024) {
          controller.abort(); throw { code: 'console_preview_size', unknown: false };
        }
        const bytes = new Uint8Array(await response.arrayBuffer());
        if (bytes.length > 8 * 1024 * 1024) throw { code: 'console_preview_size', unknown: false };
        if (!L.previewBytes(bytes, type)) throw { code: 'console_preview_type', unknown: false };
        return new Blob([bytes], { type });
      }
      if (operation === 'publicPreview') {
        const descriptor = params.preview;
        const type = (response.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
        if (type !== 'image/png') { controller.abort(); throw { code: 'console_public_preview_type', unknown: false }; }
        const length = response.headers.get('content-length');
        if (length !== null && (!/^(0|[1-9][0-9]*)$/.test(length) || Number(length) !== descriptor.size)) {
          controller.abort(); throw { code: 'console_public_preview_integrity', unknown: false };
        }
        if (!response.body || typeof response.body.getReader !== 'function') throw { code: 'console_bad_response', unknown: false };
        const reader = response.body.getReader(), chunks = []; let size = 0;
        try {
          for (;;) {
            const chunk = await reader.read(); if (chunk.done) break;
            size += chunk.value.length;
            if (size > descriptor.size || size > 2097152) {
              await reader.cancel(); throw { code: 'console_public_preview_integrity', unknown: false };
            }
            chunks.push(chunk.value);
          }
        } finally { reader.releaseLock(); }
        if (size !== descriptor.size) throw { code: 'console_public_preview_integrity', unknown: false };
        const bytes = new Uint8Array(size); let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
        if (!L.previewBytes(bytes, type)) throw { code: 'console_public_preview_type', unknown: false };
        const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
        const hash = Array.from(digest, value => value.toString(16).padStart(2, '0')).join('');
        if (hash !== descriptor.sha256) throw { code: 'console_public_preview_integrity', unknown: false };
        // Descriptor dimensions are PNG IHDR pixels. Browser natural dimensions
        // may be orientation/density corrected; they are not this byte contract.
        if (bytes.length < 33) throw { code: 'console_public_preview_type', unknown: false };
        const header = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
        if (header.getUint32(8) !== 13 || String.fromCharCode(...bytes.subarray(12, 16)) !== 'IHDR') {
          throw { code: 'console_public_preview_type', unknown: false };
        }
        if (header.getUint32(16) !== descriptor.width || header.getUint32(20) !== descriptor.height) {
          throw { code: 'console_public_preview_dimensions', unknown: false };
        }
        return new Blob([bytes], { type });
      }
      try { return await response.json(); }
      catch (_) { throw { code: 'console_bad_response', unknown: isWrite }; }
    } catch (error) {
      if (error && typeof error.code === 'string') throw error;
      throw { code: timedOut ? 'console_timeout' : 'console_network', unknown: isWrite };
    } finally {
      clearTimeout(timer);
      if (controllers.get(lane) === controller) controllers.delete(lane);
    }
  }
  function authFailure(error) {
    if (error && error.status === 401) { logout(errorText(error)); return true; }
    return false;
  }
  function clearPreview() {
    next('preview', null); imageTarget = null;
    const image = byId('preview-image'); image.onload = null; image.onerror = null;
    image.removeAttribute('src'); image.hidden = true;
    if (imageUrl) { URL.revokeObjectURL(imageUrl); imageUrl = null; }
    byId('preview').hidden = true; notice('preview-status', '');
  }
  function clearPublicPreview() {
    next('publicPreview', null); publicImageTarget = null; publicImageLoading = false; publicImageReady = false;
    const image = byId('public-preview-image'); image.onload = null; image.onerror = null;
    image.removeAttribute('src'); image.hidden = true;
    if (publicImageUrl) { URL.revokeObjectURL(publicImageUrl); publicImageUrl = null; }
    byId('public-preview').hidden = true; byId('public-preview-retry').hidden = true;
    L.text(byId('public-preview-caption'), ''); notice('public-preview-status', '');
  }
  function closeConfirmation() {
    offered = null; byId('confirm').hidden = true;
    if (focusBeforeConfirmation && focusBeforeConfirmation.isConnected) focusBeforeConfirmation.focus();
    focusBeforeConfirmation = null;
  }
  function clearSubmission() {
    next('submission', null); clearPreview(); clearPublicPreview(); selectedSubmission = null; submissionDetail = null;
    submissionTicket = null; submissionError = null; submissionLoading = false;
    byId('review-reason').value = ''; byId('submission-detail').hidden = true;
  }
  function clearReport() {
    next('report', null); selectedReport = null; reportDetail = null;
    reportTicket = null; reportError = null; reportLoading = false;
    byId('report-reason').value = ''; byId('report-detail').hidden = true;
  }
  function logout(message) {
    secret = ''; connected = false; tickets = L.book(tickets.session + 1);
    for (const controller of controllers.values()) controller.abort(); controllers.clear();
    mutation = null; writes.clear(); closeConfirmation(); clearSubmission(); clearReport(); pages = initialPages();
    byId('admin-key').value = ''; byId('console').hidden = true; byId('auth').hidden = false;
    for (const view of views) byId(view + '-rows').replaceChildren();
    byId('submission-metadata').textContent = ''; byId('submission-summary').replaceChildren();
    byId('submission-files').replaceChildren(); byId('submission-checks').replaceChildren();
    byId('report-content').replaceChildren(); notice('global-notice', ''); notice('auth-error', message || '', !!message);
  }
  async function connect() {
    const entered = byId('admin-key').value; byId('admin-key').value = '';
    if (entered.length < 32 || entered.length > 4096) {
      notice('auth-error', errorText({ code: 'console_invalid_key' }), true); return;
    }
    logout(); secret = entered; connected = true; activeView = 'submissions';
    byId('auth').hidden = true; byId('console').hidden = false;
    byId('submission-status').value = 'pending'; byId('submission-kind').value = '';
    byId('report-status').value = 'open'; byId('report-kind').value = '';
    showView('submissions'); await loadPage('submissions', null, [], { status: 'pending', kind: '' });
  }
  function showView(view) {
    if (!connected || mutation) return;
    closeConfirmation(); clearPreview(); activeView = view;
    for (const item of views) {
      byId('view-' + item).hidden = item !== view;
      byId('tab-' + item).setAttribute('aria-pressed', item === view ? 'true' : 'false');
    }
    updateControls();
  }
  function filters(view) {
    if (view === 'audit') return {};
    const prefix = view === 'submissions' ? 'submission' : 'report';
    return { status: byId(prefix + '-status').value, kind: byId(prefix + '-kind').value };
  }
  function updateControls() {
    for (const view of views) {
      const page = pages[view], busy = !!mutation || page.loading;
      byId('tab-' + view).disabled = !!mutation;
      byId(view + '-refresh').disabled = busy;
      byId(view + '-prev').disabled = busy || !page.back.length;
      byId(view + '-next').disabled = busy || !page.next;
    }
    for (const id of ['submission-status', 'submission-kind', 'report-status', 'report-kind']) byId(id).disabled = !!mutation;
    byId('submission-refresh').disabled = !!mutation || submissionLoading;
    byId('rework').disabled = !!mutation || submissionLoading || !!submissionError || !submissionDetail ||
      !submissionDetail.submission.submittedAt || !!(writes.get('submission:' + selectedSubmission) || {}).requiresRead;
    byId('report-refresh').disabled = !!mutation || reportLoading;
    byId('files-more').disabled = !!mutation || submissionLoading;
    const subBlocked = !!mutation || submissionLoading || !!submissionError || !submissionDetail ||
      !!(writes.get('submission:' + selectedSubmission) || {}).requiresRead;
    const status = submissionDetail && submissionDetail.submission.status;
    byId('approve').disabled = subBlocked || status !== 'pending' || submissionDetail.inspection.status !== 'valid' ||
      !!submissionDetail.submission.preview && !publicImageReady;
    byId('public-preview-retry').disabled = !!mutation || submissionLoading || !!submissionError || publicImageLoading;
    byId('reject').disabled = subBlocked || status !== 'pending';
    byId('withdraw').disabled = subBlocked || status !== 'approved';
    byId('approve').hidden = status !== 'pending'; byId('reject').hidden = status !== 'pending';
    byId('withdraw').hidden = status !== 'approved'; byId('review-reason').disabled = !!mutation || submissionLoading;
    const reportBlocked = !!mutation || reportLoading || !!reportError || !reportDetail ||
      !!(writes.get('report:' + selectedReport) || {}).requiresRead;
    byId('resolve-handled').disabled = reportBlocked || reportDetail.report.status !== 'open';
    byId('resolve-dismissed').disabled = reportBlocked || reportDetail.report.status !== 'open';
    byId('report-withdraw').disabled = reportBlocked || !!reportDetail.target.withdrawal;
    byId('report-reason').disabled = !!mutation || reportLoading;
    for (const button of document.querySelectorAll('#submission-files button')) button.disabled = !!mutation || submissionLoading;
    for (const view of views) {
      for (const button of byId(view + '-rows').querySelectorAll('button')) button.disabled = !!mutation;
    }
  }
  async function loadPage(view, cursor, back, selectedFilters) {
    if (!connected || mutation) return;
    closeConfirmation();
    if (view === 'submissions') clearSubmission();
    if (view === 'reports') clearReport();
    const page = pages[view], desired = selectedFilters || filters(view);
    const ticket = next('list:' + view, view);
    pages[view] = L.beginPage(page, ticket, desired, cursor === undefined ? page.cursor : cursor,
      back === undefined ? page.back : back);
    renderPage(view);
    try {
      const value = await request(view, { ...desired, cursor: pages[view].pending.cursor }, 'list:' + view);
      if (!current(ticket, view)) return;
      const parsed = L.pageData(value, view);
      pages[view] = L.finishPage(pages[view], ticket, parsed, null);
    } catch (error) {
      if (!current(ticket, view) || authFailure(error)) return;
      pages[view] = L.finishPage(pages[view], ticket, null, error);
    }
    if (current(ticket, view)) renderPage(view);
  }
  function renderPage(view) {
    const page = pages[view], root = byId(view + '-rows'); root.replaceChildren();
    const message = page.loading ? '正在读取…' : page.error ? errorText(page.error) + (page.rows.length ? '\n下面保留上一次读取的内容。' : '') :
      page.loaded && !page.rows.length ? '这一页没有记录。' : '';
    notice(view + '-status', message, !!page.error);
    for (const item of page.rows) {
      const row = node('article', undefined, 'row');
      if (view === 'submissions') {
        row.append(node('span', L.statusName(item.status), 'badge'), node('h3', item.metadata.title.zh));
        pair(row, '英文名称', item.metadata.title.en); pair(row, '作者', L.actor(item.owner));
        pair(row, '种类', L.kindName(item.metadata.kind)); pair(row, '压缩包大小', L.size(item.metadata.size));
        pair(row, '提交时间（UTC）', item.submittedAt || item.createdAt); pair(row, '校验摘要', L.validation(item.validation));
        pair(row, '投稿标识', item.submissionId);
        row.append(actionButton('查看这条投稿', () => { if (!mutation) return openSubmission(item.submissionId); }));
      } else if (view === 'reports') {
        row.append(node('span', L.statusName(item.status), 'badge'), node('h3', L.kindName(item.kind) + ' · ' + item.id + ' · ' + item.version));
        pair(row, '举报者', L.actor(item.reporter)); pair(row, '举报时间（UTC）', item.createdAt); pair(row, '举报理由', item.reason);
        row.append(actionButton('查看并处理举报', () => { if (!mutation) return openReport(item.reportId); }));
      } else {
        const names = { create: '创建投稿', submit: '上传并提交', approve: '通过审核', reject: '拒绝投稿', withdraw: '撤回', report: '创建举报', resolve_report: '处理举报' };
        row.append(node('h3', names[item.action] || item.action)); pair(row, '主体', L.actor(item.actor)); pair(row, '时间（UTC）', item.at);
        if (item.submissionId) pair(row, '投稿标识', item.submissionId);
        if (item.releaseId) pair(row, '版本标识', item.releaseId);
        if (item.reportId) pair(row, '举报标识', item.reportId);
        if (item.reason !== undefined) pair(row, '理由', item.reason);
        pair(row, '审计标识', item.eventId);
      }
      root.append(row);
    }
    updateControls();
  }
  function writeNotice(target) {
    const entry = writes.get(target);
    if (!entry) return '';
    if (entry.phase === 'unknown') return entry.observed
      ? '先前写请求的结果仍属未知；现已重新读取当前状态。这里展示的是当前观察，不据此认定先前请求成功。'
      : '写请求未取得可确认的响应，可能已生效。请先点击本条的刷新按钮核对当前状态；不会自动重复提交。';
    if (entry.phase === 'acknowledged') return entry.observed
      ? '服务器已确认本次操作，下面是随后重新读取的状态。'
      : '服务器已确认本次操作；当前详情尚未成功重新读取，请刷新核对。';
    return '服务器拒绝了本次操作。' + errorText(entry.error);
  }
  function reconcileRow(view, item) {
    const field = view === 'submissions' ? 'submissionId' : 'reportId';
    const page = pages[view];
    const keep = (!page.filters.status || page.filters.status === item.status) &&
      (!page.filters.kind || page.filters.kind === (view === 'submissions' ? item.metadata.kind : item.kind));
    pages[view] = { ...page, rows: page.rows.flatMap((row) => row[field] === item[field] ? keep ? [item] : [] : [row]) };
    renderPage(view);
  }
  async function openSubmission(id, appendFiles, afterWrite) {
    if (!connected || mutation && !afterWrite) return;
    closeConfirmation(); clearPreview();
    const same = selectedSubmission === id;
    if (!same) {
      submissionDetail = null; submissionTicket = null; byId('review-reason').value = '';
      byId('rework-version').value = ''; byId('rework-preview').value = '';
    }
    const previous = same ? submissionDetail : null;
    const cursor = appendFiles && previous ? previous.inspection.nextFileCursor : null;
    if (appendFiles && !cursor) return;
    clearPublicPreview();
    selectedSubmission = id; submissionLoading = true; submissionError = null;
    const ticket = next('submission', id); renderSubmission();
    try {
      const value = L.detail(await request('submission', { id, filesCursor: cursor }, 'submission'), id);
      if (!current(ticket, selectedSubmission)) return;
      if (appendFiles && previous) {
        if (value.submission.metadata.sha256 !== previous.submission.metadata.sha256 ||
            value.submission.metadata.size !== previous.submission.metadata.size) throw { code: 'console_bad_response', unknown: false };
        const files = new Map(previous.inspection.files.map((file) => [file.index, file]));
        for (const file of value.inspection.files) files.set(file.index, file);
        value.inspection.files = Array.from(files.values());
      }
      submissionDetail = value; submissionTicket = ticket; submissionLoading = false;
      const target = 'submission:' + id; if (writes.has(target)) writes.set(target, L.observed(writes.get(target), target));
      reconcileRow('submissions', value.submission);
    } catch (error) {
      if (!current(ticket, selectedSubmission) || authFailure(error)) return;
      submissionLoading = false; submissionError = error;
    }
    if (current(ticket, selectedSubmission)) {
      renderSubmission();
      if (!submissionError) await openPublicPreview(id, afterWrite);
    }
  }
  function renderSubmission() {
    byId('submission-detail').hidden = !selectedSubmission;
    const root = byId('submission-summary'), checks = byId('submission-checks'), files = byId('submission-files');
    root.replaceChildren(); checks.replaceChildren(); files.replaceChildren();
    const messages = [writeNotice('submission:' + selectedSubmission)];
    if (submissionLoading) messages.push('正在读取投稿详情…');
    if (submissionError) messages.push(errorText(submissionError) + (submissionDetail ? '\n保留上一次的详情；重新读取成功前不能执行审核操作。' : ''));
    notice('submission-status-text', messages.filter(Boolean).join('\n'), !!submissionError ||
      !!(writes.get('submission:' + selectedSubmission) || {}).requiresRead);
    if (!submissionDetail) {
      byId('submission-metadata').textContent = ''; L.text(byId('files-status'), '尚未读取文件清单。');
      byId('files-more').hidden = true; updateControls(); return;
    }
    const item = submissionDetail.submission, inspection = submissionDetail.inspection;
    root.append(node('h3', item.metadata.title.zh)); pair(root, '英文名称', item.metadata.title.en);
    pair(root, '状态', L.statusName(item.status)); pair(root, '当前发布指向', submissionDetail.current ? '是（公开可用性仍受功能开关影响）' : '否（已通过不等于当前发布指向）');
    pair(root, '投稿标识', item.submissionId); pair(root, '作者', L.actor(item.owner)); pair(root, '种类', L.kindName(item.metadata.kind));
    pair(root, '作品标识 / 版本', item.metadata.id + ' / ' + item.metadata.version); pair(root, '元数据作者', item.metadata.author);
    pair(root, '许可', item.metadata.license); pair(root, '来源（仅文本）', item.metadata.source);
    pair(root, '压缩包大小', L.size(item.metadata.size)); pair(root, 'SHA-256', item.metadata.sha256);
    pair(root, '创建时间（UTC）', item.createdAt); pair(root, '提交时间（UTC）', item.submittedAt); pair(root, '更新时间（UTC）', item.updatedAt);
    if (item.review) { pair(root, '审核时间（UTC）', item.review.at); pair(root, '审核理由', item.review.reason); }
    if (item.withdrawal) { pair(root, '撤回时间（UTC）', item.withdrawal.at); pair(root, '撤回理由', item.withdrawal.reason); }
    L.text(byId('submission-metadata'), L.jsonText(item.metadata));
    pair(checks, '包检查结果', ({ valid: '通过结构检查', invalid: '结构检查未通过', not_uploaded: '尚未上传' })[inspection.status]);
    pair(checks, '校验器', inspection.validator); if (inspection.summary) pair(checks, '摘要', L.validation(inspection.summary));
    for (const check of inspection.checks) {
      const row = node('div', undefined, 'row');
      pair(row, ({ pass: '通过', error: '错误', info: '说明' })[check.level] || '检查', check.code); pair(row, '内容', check.message); checks.append(row);
    }
    for (const file of inspection.files) {
      const row = node('li'); row.append(node('code', file.path, 'path'));
      pair(row, '展开大小', L.size(file.size)); pair(row, '压缩大小', L.size(file.compressedSize));
      if (file.preview) {
        pair(row, '图片尺寸', file.preview.width + ' × ' + file.preview.height);
        pair(row, '预览校验', file.preview.validation === 'full-png' ? 'PNG 已通过完整校验' : '仅通过格式结构和尺寸检查，浏览器解码仍可能失败');
        row.append(actionButton('预览这一张图片', () => { if (!mutation && !submissionLoading) return openPreview(item.submissionId, file); }));
      } else if (file.previewIssue) {
        pair(row, '不提供预览', file.previewIssue.message); pair(row, '提示码', file.previewIssue.code);
      } else pair(row, '预览', '仅列出文件，不执行脚本或模型，也不渲染其他文件。');
      files.append(row);
    }
    L.text(byId('files-status'), '已显示 ' + inspection.files.length + ' 个文件。' +
      (inspection.nextFileCursor !== null ? '还有文件可继续加载。' : '当前清单已读取完。'));
    byId('files-more').hidden = inspection.nextFileCursor === null;
    updateControls();
  }
  async function openPreview(id, file) {
    if (!connected || mutation || submissionLoading || selectedSubmission !== id || !file.preview) return;
    clearPreview(); imageTarget = id + ':' + file.index;
    const target = imageTarget, ticket = next('preview', target); byId('preview').hidden = false;
    L.text(byId('preview-caption'), file.path + '\n' + (file.preview.validation === 'full-png'
      ? 'PNG 已通过服务器完整校验。' : 'JPEG / WebP 只通过服务器结构和尺寸检查，不等于完整像素解码验证。'));
    notice('preview-status', '正在读取这一张图片…');
    try {
      const blob = await request('preview', { id, file: file.index, mediaType: file.preview.mediaType }, 'preview');
      if (!current(ticket, imageTarget) || selectedSubmission !== id) return;
      const url = URL.createObjectURL(blob);
      if (!current(ticket, imageTarget) || selectedSubmission !== id) { URL.revokeObjectURL(url); return; }
      imageUrl = url; const image = byId('preview-image');
      image.onload = () => {
        if (!current(ticket, imageTarget) || imageUrl !== url) return;
        image.hidden = false; notice('preview-status', '');
      };
      image.onerror = () => {
        if (!current(ticket, imageTarget) || imageUrl !== url) return;
        image.hidden = true; image.removeAttribute('src'); URL.revokeObjectURL(url); imageUrl = null;
        notice('preview-status', '浏览器未能解码这张图片。文件清单仍可使用；可关闭预览后手动重新读取，不会自动重试。', true);
      };
      image.src = url;
    } catch (error) {
      if (!current(ticket, imageTarget) || selectedSubmission !== id || authFailure(error)) return;
      notice('preview-status', errorText(error), true);
    }
  }
  async function openPublicPreview(id, afterWrite) {
    if (!connected || mutation && !afterWrite || submissionLoading || submissionError || selectedSubmission !== id || !submissionDetail) return;
    closeConfirmation(); clearPublicPreview();
    const descriptor = submissionDetail.submission.preview, readTicket = submissionTicket;
    byId('public-preview').hidden = false;
    if (!descriptor) {
      L.text(byId('public-preview-caption'), '本次没有已登记的公开预览图；通过后不会借用其他投稿或旧版本的图片。');
      updateControls(); return;
    }
    publicImageTarget = id + ':' + descriptor.sha256;
    const target = publicImageTarget, ticket = next('publicPreview', target);
    const matches = () => current(ticket, publicImageTarget) && selectedSubmission === id && submissionTicket === readTicket;
    publicImageLoading = true; byId('public-preview-retry').hidden = false;
    L.text(byId('public-preview-caption'), '这是本次投稿通过后展示的图片。' + '\n' + descriptor.width + ' × ' + descriptor.height +
      '；' + L.size(descriptor.size) + '\nSHA-256：' + descriptor.sha256);
    notice('public-preview-status', '正在读取本次公开预览；图片显示成功前不能通过审核。'); updateControls();
    try {
      const blob = await request('publicPreview', { id, preview: descriptor }, 'publicPreview');
      if (!matches()) return;
      const url = URL.createObjectURL(blob);
      if (!matches()) { URL.revokeObjectURL(url); return; }
      publicImageUrl = url; const image = byId('public-preview-image');
      const decodeFailure = (message) => {
        if (!matches() || publicImageUrl !== url) return;
        image.onload = null; image.onerror = null; image.hidden = true; image.removeAttribute('src');
        URL.revokeObjectURL(url); publicImageUrl = null; publicImageReady = false;
        notice('public-preview-status', message + '\n可手动重新读取图片；元数据、文件清单和拒绝操作仍可使用。', true); updateControls();
      };
      image.onload = () => {
        if (!matches() || publicImageUrl !== url) return;
        publicImageReady = true; image.hidden = false; notice('public-preview-status', '已核对本次登记的图片摘要与 PNG 像素尺寸，图片已载入，请查看内容后再决定。'); updateControls();
      };
      image.onerror = () => decodeFailure('浏览器未能解码这张公开预览图。');
      image.src = url;
    } catch (error) {
      if (!matches() || authFailure(error)) return;
      notice('public-preview-status', errorText(error) + '\n可以手动重新读取图片。', true);
    } finally {
      if (matches()) { publicImageLoading = false; updateControls(); }
    }
  }
  async function openReport(id, afterWrite) {
    if (!connected || mutation && !afterWrite) return;
    closeConfirmation();
    if (selectedReport !== id) { reportDetail = null; reportTicket = null; byId('report-reason').value = ''; }
    selectedReport = id; reportLoading = true; reportError = null;
    const ticket = next('report', id); renderReport();
    try {
      const value = L.reportDetail(await request('report', { id }, 'report'), id);
      if (!current(ticket, selectedReport)) return;
      reportDetail = value; reportTicket = ticket; reportLoading = false;
      const target = 'report:' + id; if (writes.has(target)) writes.set(target, L.observed(writes.get(target), target));
      reconcileRow('reports', value.report);
    } catch (error) {
      if (!current(ticket, selectedReport) || authFailure(error)) return;
      reportLoading = false; reportError = error;
    }
    if (current(ticket, selectedReport)) renderReport();
  }
  function renderReport() {
    byId('report-detail').hidden = !selectedReport; const root = byId('report-content'); root.replaceChildren();
    const messages = [writeNotice('report:' + selectedReport)];
    if (reportLoading) messages.push('正在读取举报及目标版本…');
    if (reportError) messages.push(errorText(reportError) + (reportDetail ? '\n保留上一次的详情；重新读取成功前不能处理。' : ''));
    notice('report-status-text', messages.filter(Boolean).join('\n'), !!reportError ||
      !!(writes.get('report:' + selectedReport) || {}).requiresRead);
    if (!reportDetail) { updateControls(); return; }
    const item = reportDetail.report, target = reportDetail.target;
    pair(root, '举报标识', item.reportId); pair(root, '处理状态', L.statusName(item.status)); pair(root, '举报者', L.actor(item.reporter));
    pair(root, '举报时间（UTC）', item.createdAt); pair(root, '举报理由', item.reason); pair(root, '种类', L.kindName(item.kind));
    pair(root, '作品标识 / 版本', item.id + ' / ' + item.version); pair(root, '当前发布指向', target.current ? '是（公开可用性仍受功能开关影响）' : '否');
    pair(root, '版本作者', L.actor(target.release.owner)); pair(root, '版本 SHA-256', target.release.sha256);
    pair(root, '版本压缩包大小', L.size(target.release.size)); pair(root, '批准时间（UTC）', target.release.approvedAt);
    if (target.withdrawal) { pair(root, '版本撤回时间（UTC）', target.withdrawal.at); pair(root, '版本撤回理由', target.withdrawal.reason); }
    else pair(root, '版本撤回状态', '尚未撤回');
    if (item.resolution) {
      pair(root, '处理结果', item.resolution.decision === 'handled' ? '已处理' : '不予处理'); pair(root, '处理主体', L.actor(item.resolution.actor));
      pair(root, '处理时间（UTC）', item.resolution.at); pair(root, '处理理由', item.resolution.reason);
    }
    updateControls();
  }
  function displayedTarget() {
    return activeView === 'submissions' ? 'submission:' + selectedSubmission : activeView === 'reports' ? 'report:' + selectedReport : '';
  }
  function previewFile() {
    const input = byId('rework-preview'), file = input.files && input.files[0];
    if (!file) return Promise.resolve(null);
    if (file.type !== 'image/png' || file.size > 2097152) return Promise.reject({ code: 'console_bad_preview', unknown: false });
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const value = String(reader.result || ''), comma = value.indexOf(',');
        if (comma < 0) reject({ code: 'console_bad_preview', unknown: false }); else resolve(value.slice(comma + 1));
      };
      reader.onerror = () => reject({ code: 'console_bad_preview', unknown: false });
      reader.readAsDataURL(file);
    });
  }
  async function offerAction(operation, decision) {
    if (!connected || mutation) return;
    let params, title, impact, target, readTicket, view, id;
    if (operation === 'rework') {
      if (activeView !== 'submissions' || !submissionDetail || submissionLoading || submissionError) return;
      const item = submissionDetail.submission;
      if (!item.submittedAt) return;
      const nextVersion = byId('rework-version').value.trim();
      let preview;
      try { preview = await previewFile(); } catch (error) { notice('global-notice', errorText(error), true); return; }
      id = item.submissionId; target = 'submission:' + id; view = 'submissions'; readTicket = submissionTicket;
      params = { id, reason: byId('review-reason').value, ...(nextVersion ? { version: nextVersion } : {}), ...(preview ? { preview } : {}) };
      title = item.metadata.title.zh + ' · ' + item.metadata.kind + ' / ' + item.metadata.id + ' / ' + item.metadata.version + '\n投稿 ' + id
        + (nextVersion ? '\n新版本：' + nextVersion : '');
      impact = '用这条投稿现有的压缩包生成一条新记录并直接发布，作者归属保持不变。' +
        (preview ? '\n使用本次选择的预览图作为公开预览。' : '\n预览图按包内声明由服务器重新生成；没有声明则不发布预览。') +
        (item.status === 'pending' ? '\n原待审核记录会被本条取代。' : '\n原记录保留为历史。');
    } else if (operation === 'review' || operation === 'withdraw') {
      if (activeView !== 'submissions' || !submissionDetail || submissionLoading || submissionError) return;
      const item = submissionDetail.submission;
      if (operation === 'review' && (item.status !== 'pending' || decision === 'approve' &&
          (submissionDetail.inspection.status !== 'valid' || !!item.preview && !publicImageReady)) ||
          operation === 'withdraw' && item.status !== 'approved') return;
      id = item.submissionId; target = 'submission:' + id; view = 'submissions'; readTicket = submissionTicket;
      params = { id, ...(decision ? { decision } : {}), reason: byId('review-reason').value };
      title = item.metadata.title.zh + ' · ' + item.metadata.kind + ' / ' + item.metadata.id + ' / ' + item.metadata.version + '\n投稿 ' + id;
      impact = operation === 'withdraw' ? '撤回此版本的全部已批准记录，停止公开分发；不会自动回退到旧版本。'
        : decision === 'approve' ? '通过审核并将这个版本设为当前发布指向；公开可用性仍受功能开关影响。请确认元数据、许可、文件检查结果与本次公开预览。' +
          (item.preview ? '\n本次图片 SHA-256：' + item.preview.sha256 : '\n本次不发布公开预览图。') : '拒绝这条待审核投稿，并记录下面的理由。';
    } else {
      if (activeView !== 'reports' || !reportDetail || reportLoading || reportError) return;
      const item = reportDetail.report;
      if (operation === 'resolve' && item.status !== 'open' || operation === 'releaseWithdraw' && reportDetail.target.withdrawal) return;
      id = item.reportId; target = 'report:' + id; view = 'reports'; readTicket = reportTicket;
      params = operation === 'resolve' ? { id, decision, reason: byId('report-reason').value }
        : { kind: item.kind, releaseId: item.id, version: item.version, reason: byId('report-reason').value };
      title = item.kind + ' / ' + item.id + ' / ' + item.version + '\n举报 ' + id;
      impact = operation === 'releaseWithdraw' ? '撤回被举报版本，停止公开分发；此操作不会自动处理举报，也不会自动回退旧版本。'
        : (decision === 'handled' ? '将举报标记为已处理。' : '将举报标记为不予处理。') + '这不会撤回目标版本；处理结果和第一次理由将被保留。';
    }
    if ((writes.get(target) || {}).requiresRead) return;
    try {
      offered = Object.freeze({ ...L.confirmation(operation, params, title, tickets.session, target, readTicket), view, id, impact });
      L.text(byId('confirm-title'), '再次确认' + (operation === 'rework' ? '修正并重新发布' : operation === 'withdraw' || operation === 'releaseWithdraw' ? '撤回' : operation === 'resolve' ? '举报处理' : decision === 'approve' ? '通过审核' : '拒绝投稿'));
      L.text(byId('confirm-target'), offered.title); L.text(byId('confirm-impact'), offered.impact); L.text(byId('confirm-reason'), offered.params.reason);
      focusBeforeConfirmation = document.activeElement; byId('confirm').hidden = false; byId('confirm-cancel').focus();
    } catch (error) { notice('global-notice', errorText(error), true); }
  }
  async function confirmAction() {
    const command = offered;
    if (!L.canConfirm(command, tickets, displayedTarget(), !!mutation) || command && command.operation === 'review' &&
        command.params.decision === 'approve' && submissionDetail && submissionDetail.submission.preview && !publicImageReady) {
      closeConfirmation(); notice('global-notice', errorText({ code: 'console_confirmation_stale' }), true); return;
    }
    closeConfirmation(); mutation = command; const ticket = next('mutation', command.target);
    notice('global-notice', '正在提交已确认的操作…'); updateControls();
    let error = null, created = null;
    try {
      const value = await request(command.operation, command.params, 'mutation');
      try { L.writeResult(value, command); }
      catch (_) { throw { code: 'console_bad_response', unknown: true }; }
      if (command.operation === 'rework' && value && value.submission) created = value.submission.submissionId;
    } catch (caught) { error = caught; }
    if (!current(ticket, command.target) || mutation !== command) return;
    if (authFailure(error)) return;
    writes.set(command.target, L.writeState(command.target, error));
    if (error && error.unknown) {
      notice('global-notice', '本次写请求结果未知。请先刷新同一条对象核对状态，不要直接重复操作。\n' + errorText(error), true);
    } else {
      notice('global-notice', error ? errorText(error) : '服务器已确认操作，正在刷新该条…', !!error);
      if (command.operation === 'rework' && created) {
        byId('rework-version').value = ''; byId('rework-preview').value = '';
        await openSubmission(created, false, true);
      } else if (command.view === 'submissions') await openSubmission(command.id, false, true);
      else await openReport(command.id, true);
    }
    if (!current(ticket, command.target) || mutation !== command) return;
    mutation = null;
    if (!error || !error.unknown) notice('global-notice', writeNotice(command.target), !!error);
    if (command.view === 'submissions') renderSubmission(); else renderReport();
    updateControls();
  }
  L.text(byId('origin'), '当前 Worker：' + location.origin);
  byId('connect').addEventListener('click', connect);
  byId('admin-key').addEventListener('keydown', (event) => { if (event.key === 'Enter') { event.preventDefault(); connect(); } });
  byId('logout').addEventListener('click', () => logout());
  for (const view of views) {
    byId('tab-' + view).addEventListener('click', () => {
      if (mutation) return; showView(view);
      if (!pages[view].loaded && !pages[view].loading) return loadPage(view, null, [], filters(view));
    });
    byId(view + '-refresh').addEventListener('click', () => loadPage(view));
    byId(view + '-next').addEventListener('click', () => {
      const page = pages[view]; if (page.next && !page.loading) return loadPage(view, page.next, [...page.back, page.cursor]);
    });
    byId(view + '-prev').addEventListener('click', () => {
      const page = pages[view]; if (page.back.length && !page.loading) return loadPage(view, page.back[page.back.length - 1], page.back.slice(0, -1));
    });
  }
  for (const prefix of ['submission', 'report']) {
    for (const suffix of ['status', 'kind']) byId(prefix + '-' + suffix).addEventListener('change', () => loadPage(prefix + 's', null, [], filters(prefix + 's')));
  }
  byId('submission-refresh').addEventListener('click', () => { if (selectedSubmission) return openSubmission(selectedSubmission); });
  byId('files-more').addEventListener('click', () => { if (selectedSubmission) return openSubmission(selectedSubmission, true); });
  byId('preview-clear').addEventListener('click', clearPreview);
  byId('public-preview-retry').addEventListener('click', () => { if (selectedSubmission) return openPublicPreview(selectedSubmission); });
  byId('report-refresh').addEventListener('click', () => { if (selectedReport) return openReport(selectedReport); });
  byId('rework').addEventListener('click', () => offerAction('rework'));
  byId('approve').addEventListener('click', () => offerAction('review', 'approve'));
  byId('reject').addEventListener('click', () => offerAction('review', 'reject'));
  byId('withdraw').addEventListener('click', () => offerAction('withdraw'));
  byId('resolve-handled').addEventListener('click', () => offerAction('resolve', 'handled'));
  byId('resolve-dismissed').addEventListener('click', () => offerAction('resolve', 'dismissed'));
  byId('report-withdraw').addEventListener('click', () => offerAction('releaseWithdraw'));
  byId('confirm-cancel').addEventListener('click', closeConfirmation);
  byId('confirm-send').addEventListener('click', confirmAction);
  document.addEventListener('keydown', (event) => {
    if (byId('confirm').hidden) return;
    if (event.key === 'Escape') { event.preventDefault(); closeConfirmation(); }
    if (event.key === 'Tab') {
      event.preventDefault();
      (document.activeElement === byId('confirm-cancel') ? byId('confirm-send') : byId('confirm-cancel')).focus();
    }
  });
  window.addEventListener('pagehide', () => logout());
  updateControls();
})();
/* WORKSHOP_ADMIN_UI_END */
`;

export const WORKSHOP_ADMIN_HTML = String.raw`<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>工坊审核台</title>
<style>
:root{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color:#182230;background:#f3f5f8;line-height:1.55;color-scheme:light}
*{box-sizing:border-box}body{margin:0}main{max-width:760px;margin:auto;padding:20px 16px 48px}h1{font-size:1.65rem;margin:0 0 8px}h2{font-size:1.25rem;margin:0 0 14px}h3{font-size:1.05rem;margin:0 0 10px}p{margin:8px 0 14px}button,input,select,textarea{font:inherit}button{width:100%;min-height:48px;padding:11px 16px;border:1px solid #b8c3d1;border-radius:10px;background:#fff;color:#152238;cursor:pointer}button:disabled{cursor:default;opacity:.5}button.primary{background:#135dc0;color:#fff;border-color:#135dc0}button.danger{background:#ae2532;color:#fff;border-color:#ae2532}button:focus-visible,input:focus-visible,select:focus-visible,textarea:focus-visible{outline:3px solid #90b8f2;outline-offset:2px}
input,select,textarea{width:100%;min-height:48px;border:1px solid #aebac9;border-radius:8px;padding:10px;background:#fff;color:#182230}textarea{resize:vertical;min-height:108px}label{display:block;font-weight:600;margin:12px 0 6px}.card{background:#fff;border:1px solid #dce2ea;border-radius:14px;padding:16px;margin:16px 0}.muted{color:#526175;font-size:.93rem}.notice{border-left:4px solid #587ca8;background:#eef4fc;padding:12px;margin:12px 0;white-space:pre-wrap;overflow-wrap:anywhere}.error{border-left-color:#b52c3c;background:#fff1f2}.success{border-left-color:#2b795a;background:#edf8f2}.stack{display:flex;flex-direction:column;gap:10px}.tabs{display:flex;flex-direction:column;gap:8px;margin-top:16px}.tabs button[aria-pressed="true"]{background:#183e70;border-color:#183e70;color:#fff}.row{padding:14px 0;border-top:1px solid #e3e8ef}.row:first-child{border-top:0}.pair{margin:5px 0;white-space:pre-wrap;overflow-wrap:anywhere}.pair strong{font-weight:600}.badge{display:inline-block;border-radius:6px;background:#edf1f6;padding:3px 8px;margin-bottom:8px;font-size:.9rem}.path{white-space:pre-wrap;overflow-wrap:anywhere;display:block;font-family:ui-monospace,monospace}.files{list-style:none;margin:0;padding:0}.files li{border-top:1px solid #e3e8ef;padding:12px 0}.files button{margin-top:8px;width:100%}pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f5f7fa;border-radius:8px;padding:12px;font-size:.88rem;max-height:70vh;overflow:auto}.preview img{display:block;max-width:100%;max-height:65vh;margin:12px auto;object-fit:contain;background:repeating-conic-gradient(#f2f2f2 0 25%,#fff 0 50%) 0/20px 20px}.preview-caption{white-space:pre-wrap;overflow-wrap:anywhere}hr{border:0;border-top:1px solid #dce2ea;margin:20px 0}.confirm{position:fixed;inset:0;z-index:10;background:#18223088;display:flex;align-items:flex-end;justify-content:center;padding:12px}.confirm-panel{background:white;border-radius:16px;padding:20px;width:100%;max-width:720px;max-height:90vh;max-height:90dvh;overflow:auto}[hidden]{display:none!important}.spaced{margin-top:14px}summary{cursor:pointer;min-height:48px;padding:10px 0;font-weight:600}a{color:#135dc0}
</style>
</head>
<body><main>
<header><h1>工坊审核台</h1><p class="muted">先审后发 · 只预览图片，不运行投稿中的脚本或模型</p><p id="origin" class="muted"></p></header>
<section id="auth" class="card" aria-labelledby="auth-title"><h2 id="auth-title">输入管理密钥</h2>
<p class="muted">密钥只留在本标签页内存，不写入浏览器存储、网址或日志。刷新、关闭或退出后需重新输入；切换到其他应用不会自动退出。</p>
<label for="admin-key">管理密钥</label><input id="admin-key" type="password" maxlength="4096" autocomplete="off" autocapitalize="off" spellcheck="false">
<button id="connect" class="primary spaced" type="button">进入审核台</button><p id="auth-error" class="notice error" role="alert" hidden></p></section>
<section id="console" hidden>
<div class="card"><p class="muted">当前使用管理密钥身份；审计不能区分共用这把密钥的具体个人。</p><button id="logout" type="button">清空密钥并退出</button>
<nav class="tabs" aria-label="审核台栏目"><button id="tab-submissions" aria-pressed="true" type="button">投稿审核</button><button id="tab-reports" aria-pressed="false" type="button">举报处理</button><button id="tab-audit" aria-pressed="false" type="button">审计记录</button></nav></div>
<p id="global-notice" class="notice" role="status" aria-live="polite" hidden></p>
<section id="view-submissions"><div class="card"><h2>投稿列表</h2>
<label for="submission-status">投稿状态</label><select id="submission-status"><option value="pending">待审核</option><option value="approved">已通过</option><option value="rejected">已拒绝</option><option value="withdrawn">已撤回</option><option value="draft">尚未上传</option><option value="">全部状态</option></select>
<label for="submission-kind">作品种类</label><select id="submission-kind"><option value="">全部种类</option><option value="pet">像素宠物</option><option value="companion">Live2D 伙伴</option><option value="theme">主题包</option></select>
<button id="submissions-refresh" class="spaced" type="button">刷新当前列表</button><p id="submissions-status" class="notice" role="status" hidden></p><div id="submissions-rows"></div>
<div class="stack spaced"><button id="submissions-prev" type="button">上一页</button><button id="submissions-next" type="button">下一页</button></div><p class="muted">每页 20 条，按服务器标识排序。分页是实时视图，不保证跨页快照。</p></div>
<section id="submission-detail" class="card" hidden><h2>投稿详情</h2><button id="submission-refresh" type="button">刷新此投稿</button><p id="submission-status-text" class="notice" role="status" hidden></p><div id="submission-summary"></div>
<h3>逐项校验</h3><div id="submission-checks"></div><p class="muted">结构校验不证明授权、版权或模型运行效果。审核通过仍需人工判断元数据和许可。</p>
<section id="public-preview" class="preview" hidden><h3>本次公开预览</h3><p id="public-preview-caption" class="preview-caption"></p><p id="public-preview-status" class="notice" role="status" hidden></p><img id="public-preview-image" alt="本次投稿通过后公开展示的预览图" decoding="async" hidden><button id="public-preview-retry" type="button" hidden>重新读取本次公开预览</button></section>
<details><summary>完整元数据</summary><pre id="submission-metadata"></pre></details><h3 class="spaced">包内文件</h3><p id="files-status" class="muted"></p><ul id="submission-files" class="files"></ul><button id="files-more" type="button" hidden>继续加载文件</button>
<section id="preview" class="preview" hidden><h3>图片预览</h3><p id="preview-caption" class="preview-caption"></p><p id="preview-status" class="notice" role="status" hidden></p><img id="preview-image" alt="所选包内图片的静态预览" decoding="async" hidden><button id="preview-clear" type="button">关闭预览</button></section>
<hr><label for="review-reason">操作理由（必填，原文写入审计）</label><textarea id="review-reason" rows="3" maxlength="4000" placeholder="请填写通过、拒绝或撤回的理由"></textarea>
<div class="stack spaced"><button id="approve" class="primary" type="button">通过此投稿</button><button id="reject" class="danger" type="button">拒绝此投稿</button><button id="withdraw" class="danger" type="button">撤回此已批准版本</button></div><p class="muted">撤回曾获批准的投稿会撤回同一版本的全部已批准记录，不会自动回退到旧版本。</p>
<hr><h3>修正并重新发布（管理员）</h3>
<p class="muted">用这条投稿现有的压缩包生成一条新记录并立即发布，作者归属保持原账号。用于修正已被撤回或被他人占用而卡住的版本号 / 作品标识，或给旧包补预览图。操作理由使用上面的输入框。</p>
<label for="rework-version">新版本号（留空保持不变）</label><input id="rework-version" maxlength="80" autocomplete="off" spellcheck="false">
<label for="rework-preview">预览图 PNG（可选，≤512×512、≤2 MiB；不选则按包内声明自动生成）</label><input id="rework-preview" type="file" accept="image/png">
<div class="stack spaced"><button id="rework" type="button">修正并重新发布</button></div></section></section>
<section id="view-reports" hidden><div class="card"><h2>举报列表</h2><label for="report-status">处理状态</label><select id="report-status"><option value="open">未处理</option><option value="resolved">已处理</option><option value="">全部状态</option></select><label for="report-kind">作品种类</label><select id="report-kind"><option value="">全部种类</option><option value="pet">像素宠物</option><option value="companion">Live2D 伙伴</option><option value="theme">主题包</option></select>
<button id="reports-refresh" class="spaced" type="button">刷新举报列表</button><p id="reports-status" class="notice" role="status" hidden></p><div id="reports-rows"></div><div class="stack spaced"><button id="reports-prev" type="button">上一页</button><button id="reports-next" type="button">下一页</button></div></div>
<section id="report-detail" class="card" hidden><h2>举报详情</h2><button id="report-refresh" type="button">刷新此举报及目标版本</button><p id="report-status-text" class="notice" role="status" hidden></p><div id="report-content"></div>
<p class="notice">标记举报已处理不会自动下架。撤回版本是另一个需要确认的操作。</p><label for="report-reason">处理或撤回理由（必填）</label><textarea id="report-reason" rows="3" maxlength="4000"></textarea><div class="stack spaced"><button id="resolve-handled" class="primary" type="button">标记已处理</button><button id="resolve-dismissed" type="button">标记不予处理</button><button id="report-withdraw" class="danger" type="button">撤回被举报版本</button></div></section></section>
<section id="view-audit" hidden><div class="card"><h2>审计记录（只读）</h2><p class="muted">显示记录中的主体、UTC 时间、对象和动作。admin 表示管理密钥持有人，不代表可区分的实名管理员。</p><button id="audit-refresh" type="button">刷新审计</button><p id="audit-status" class="notice" role="status" hidden></p><div id="audit-rows"></div><div class="stack spaced"><button id="audit-prev" type="button">上一页</button><button id="audit-next" type="button">下一页</button></div></div></section>
</section>
<noscript><p class="notice error">审核台需要浏览器启用 JavaScript。页面本身不包含投稿数据。</p></noscript>
</main>
<section id="confirm" class="confirm" role="dialog" aria-modal="true" aria-labelledby="confirm-title" hidden><div class="confirm-panel"><h2 id="confirm-title">再次确认</h2><p id="confirm-target" class="pair"></p><p id="confirm-impact" class="notice"></p><h3>将记录的理由</h3><pre id="confirm-reason"></pre><div class="stack"><button id="confirm-send" class="danger" type="button">确认执行</button><button id="confirm-cancel" type="button">返回，不执行</button></div></div></section>
<script>${WORKSHOP_ADMIN_SCRIPT}</script>
</body></html>`;
