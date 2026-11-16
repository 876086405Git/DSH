import { createHash, randomUUID } from 'node:crypto';
import { constants } from 'node:fs';
import { open, realpath } from 'node:fs/promises';
import { join, isAbsolute, relative, sep } from 'node:path';
import { createBudgetLedger, BudgetError } from './budget-ledger.js';
import { checkAbort, fail } from './errors.js';

// No bundled tariff is sufficiently bounded for all prompt/input token charges.
// Unknown prices use an explicitly approved conservative hold, never a fake estimate.
export async function admitGeneration(request, context) {
  const { signal, authorizeWorkspace, hostStateDir, sessionId, keyRef, budget, approve } = context;
  checkAbort(signal);
  const workspace = await authorizeWorkspace();
  const rid = 'm_' + randomUUID();
  const ledger = createBudgetLedger(join(hostStateDir, 'budget'));
  try {
    let state = await ledger.snapshot({ signal });
    if (state.dailyLimitMicros !== budget.dailyMicros) {
      state = await ledger.setDailyLimit(budget.dailyMicros, state.revision, { signal });
    }
    const hold = budget.unknownHoldMicros;
    const reason = [
      request.model.kind === 'video' ? '生成视频会产生服务费用。' : '生成或编辑图片会产生服务费用。',
      `服务 ${request.service.id}；目标 ${request.service.baseUrl}；模型 ${request.model.label}（${request.model.id}）。`,
      `尚无覆盖本次输入的可靠价格；本地预留 ¥${hold / 1_000_000}，每日预算 ¥${state.dailyLimitMicros / 1_000_000}。`,
      '预留不是报价或供应商扣费上限，实际费用以服务账单为准；提交后失败或停止等待也保留预留。',
      request.model.kind === 'video' ? '仅排队阶段可能取消；开始生成后服务端可能继续并收费。' : '',
      request.refs?.length ? '将发送以下工作区文件（本次已读取的内容，文件更改后拒绝提交）：\n' + request.refs.join('\n') : '',
    ].filter(Boolean).join('\n');
    if (!approve || await approve(reason) !== 'allowed-once') fail('approval_required');
    checkAbort(signal);
    const after = await authorizeWorkspace();
    if (after.cwd !== workspace.cwd || after.workspaceRoot !== workspace.workspaceRoot || after.mode !== workspace.mode) fail('permission');
    const paramsHash = createHash('sha256').update(JSON.stringify(request)).digest('hex');
    const { record } = await ledger.reserve({ rid, estimateMicros: hold, payload: request, request: {
      sessionId, serviceId: request.service.id, modelId: request.model.id, profile: request.service.profile,
      region: 'configured-endpoint', baseUrl: request.service.baseUrl, keyRef,
      cwd: workspace.cwd, workspaceRoot: workspace.workspaceRoot, paramsHash,
    } }, { signal });
    return {
      rid, outputDate: record.outputDate,
      async begin() {
        checkAbort(signal);
        try {
          if (!(await ledger.beginSubmission(rid, record.identity, { signal })).started) fail('submission_unknown');
        } catch (error) { throw budgetFailure(error); }
      },
      async submitted(id) {
        // Persist accepted identity even if cancellation arrived just after the HTTP response.
        try { await ledger.markSubmitted(rid, record.identity, id); } catch (error) { throw budgetFailure(error); }
      },
      async settle() {
        try { await ledger.settle(rid, record.identity, { chargeMicros: hold, basis: 'estimate' }); } catch (error) { throw budgetFailure(error); }
      },
      async releaseUnsent() {
        // Never release unknown/submitted/settled requests or imply a provider refund.
        try { await ledger.releaseUnsent(rid, record.identity); }
        catch (error) { if (!(error instanceof BudgetError) || error.code !== 'submission_may_have_happened') throw budgetFailure(error); }
      },
    };
  } catch (error) { throw budgetFailure(error); }
}
function budgetFailure(error) {
  if (!(error instanceof BudgetError)) return error;
  if (error.code === 'budget_exceeded') { try { fail('budget_exceeded'); } catch (safe) { return safe; } }
  try { fail('budget'); } catch (safe) { return safe; }
}

// Recovery is lookup-only. A known paid task keeps its original request identity;
// no new submission, reservation or provider credential target may be substituted.
export async function recoverAdmission(rid, context) {
  if (!/^m_[a-f0-9-]{36}$/.test(rid)) fail('invalid_request');
  const ledger = createBudgetLedger(join(context.hostStateDir, 'budget'));
  const state = await ledger.snapshot({ signal: context.signal });
  const record = state.requests.find(row => row.rid === rid);
  if (!record || record.request.sessionId !== context.sessionId || !record.payload) fail('permission');
  if (!['submitted', 'settled'].includes(record.state) || !record.providerTaskId) fail('recovery_unavailable');
  const policy = await context.authorizeWorkspace();
  if (record.request.cwd !== policy.cwd || record.request.workspaceRoot !== policy.workspaceRoot) fail('permission');
  let completed;
  if (record.outputDate) {
    let handle;
    try {
      const path = join(context.hostStateDir, 'works', record.outputDate, rid + '.json');
      if (await realpath(path) !== path) fail('permission');
      handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
      const info = await handle.stat();
      if (!info.isFile() || info.size > 17408) fail('storage');
      const index = JSON.parse(await handle.readFile('utf8'));
      if (index.rid !== rid || index.sessionId !== context.sessionId || index.cwd !== policy.cwd
        || index.media?.rid !== rid || index.media?.status !== 'done' || index.media?.request?.model !== record.payload.model.id) fail('storage');
      for (const item of index.media.items) {
        const rel = relative(policy.cwd, item.path);
        if (!isAbsolute(item.path) || isAbsolute(rel) || rel === '..' || rel.startsWith('..' + sep) || await realpath(item.path) !== item.path) fail('permission');
      }
      completed = { meta: index.media, text: '已恢复此前保存的媒体：\n' + index.media.items.map(item => item.path).join('\n') };
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
      if (handle) fail('storage');
    }
    finally { await handle?.close(); }
  }
  return { completed, request: record.payload, keyRef: record.request.keyRef, providerTaskId: record.providerTaskId,
    admission: { rid, outputDate: record.outputDate, async settle() { await ledger.settle(rid, record.identity, { chargeMicros: record.estimateMicros, basis: 'estimate' }); }, async releaseUnsent() {} },
  };
}
