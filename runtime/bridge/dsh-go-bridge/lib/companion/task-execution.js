import { randomUUID } from 'node:crypto';
import { FULL_PRESET } from './prompt-context.js';
import { fingerprint, taskError, TASK_KIND, RECEIPT_KIND } from './task-schema.js';

const raw = value => value?.[Symbol.for('cordis.original')] ?? value;
const copy = value => value === undefined ? undefined : structuredClone(value);

// Owns only the real factory handles it created/resumed. No normal prompt is sent.
export function createNotesExecutionOwner(ctx, store) {
  const handles = new Map();
  let closing = false;
  async function source(record, {requireModel = true} = {}) {
    requireModel = requireModel || record.kind !== RECEIPT_KIND;
    let origin = null, scope = ctx;
    const controller = ctx.get('sessionController'), defaults = ctx.get('agentDefaultModel');
    if (record.hostSessionId !== null) {
      if (typeof controller?.resolveAgent !== 'function') throw taskError(503, 'unavailable', 'The original host session is unavailable');
      origin = (await controller.resolveAgent(record.hostSessionId))?.agent;
      if (!origin || ctx.get('agentPresets')?.presetForSession(origin.session) !== FULL_PRESET)
        throw taskError(409, 'conflict', 'The original companion session is unavailable');
      scope = origin.loopCtx ?? origin.ctx;
    }
    const selection = () => origin ? origin.model.current() : defaults?.currentSelection();
    const selected = requireModel ? copy(selection()) ?? null : null;
    if (requireModel && (!selected?.provider || !selected?.model)) throw taskError(503, 'unavailable', 'The selected host model is not configured');
    const llm = scope.get('llm'), fs = ctx.get('fs'), policyOwner = scope.get('sandboxPolicy'), approvalOwner = scope.get('approval');
    const standingPolicy = () => fs.sandboxMode === undefined ? undefined : policyOwner?.resolve(origin ? {session:origin.session} : {});
    const policy = copy(standingPolicy());
    if (fs.sandboxMode !== undefined && !policy) throw taskError(503, 'unavailable', 'The mounted filesystem policy is unavailable');
    const approvalPolicy = () => origin ? approvalOwner?.effectivePolicy(origin.session) : approvalOwner?.config.policy ?? 'ask';
    const capturedApprovalPolicy = approvalPolicy();
    const policyFingerprint = fingerprint(policy ?? null);
    const guard = () => {
      const current = store.read(record.taskId);
      if (closing || store.stopping || current.taskRev !== record.taskRev || current.cancelRequested ||
          !store.executionAllowed(current) ||
          current.agreement.deadlineAtMs !== null && Date.now() >= current.agreement.deadlineAtMs ||
          requireModel && raw(scope.get('llm')) !== raw(llm) || raw(ctx.get('fs')) !== raw(fs) ||
          raw(scope.get('sandboxPolicy')) !== raw(policyOwner) || raw(scope.get('approval')) !== raw(approvalOwner) ||
          requireModel && fingerprint(selection() ?? null) !== fingerprint(selected) ||
          fingerprint(standingPolicy() ?? null) !== policyFingerprint || approvalPolicy() !== capturedApprovalPolicy ||
          (origin ? ctx.get('agents')?.get(origin.id) !== origin || raw(ctx.get('sessionController')) !== raw(controller)
            : requireModel && raw(ctx.get('agentDefaultModel')) !== raw(defaults)))
        throw taskError(409, 'conflict', 'The task agreement, original model selection or policy changed');
    };
    guard();
    return {origin, scope, selected, llm, fs, policy, policyFingerprint, capturedApprovalPolicy, guard};
  }
  async function openExecution(record, signal, {requireModel = true} = {}) {
    if (closing) throw taskError(503, 'unavailable', 'Task execution owner is stopping');
    const model = await source(record, {requireModel}), agents = ctx.get('agents'), sessions = ctx.get('sessions'), persistence = ctx.get('sessionPersistence');
    if (typeof agents?.create !== 'function' || typeof agents?.resume !== 'function' ||
        typeof persistence?.stat !== 'function' || typeof sessions?.flush !== 'function')
      throw taskError(503, 'unavailable', 'Durable task agent services are unavailable');
    const originalExecution = store.read(record.taskId).execution;
    const agentId = originalExecution?.agentId ?? `companion-task-${randomUUID()}`;
    if (!originalExecution) await store.bindExecution(record.taskId, record.taskRev,
      {agentId,...(model.selected ? {provider:model.selected.provider,model:model.selected.model} : {}),prepared:true});
    if (!handles.has(agentId)) {
      const opening = (async () => {
        if (agents.get(agentId)) throw taskError(409, 'conflict', 'The original task agent is owned by another live executor');
        const stored = await persistence.stat(agentId, {signal});
        if (!stored && originalExecution?.prepared === false)
          throw taskError(503, 'unavailable', 'The original task session cannot be recovered');
        const [{setSandboxMode},{setApprovalPolicy}] = await Promise.all([
          import('@deepseek-ai/dsh-sandbox-policy'), import('@deepseek-ai/dsh-user-approval')]);
        const options = {signal, agentOptions: model.selected ? {...model.selected,maxTokens:3000} : {},
          setup: (_scope, agent) => {
            if (model.policy) setSandboxMode(agent.session,model.policy.mode);
            setApprovalPolicy(agent.session,model.capturedApprovalPolicy);
            return {commit:model.guard};
          }};
        // A selected output folder never changes the standing workspace boundary.
        const handle = stored ? await agents.resume({...options,resumeSessionId:agentId}) :
          await agents.create({...options,sessionId:agentId,...model.policy ? {meta:{cwd:model.policy.workspaceRoot}} : {}});
        try {
          model.guard();
          if (typeof handle.agent.dshGoRunTaskTurn !== 'function') throw taskError(503,'unavailable','Real fixed task turns are unavailable');
          if (await sessions.flush(handle.agent.session) !== true) throw taskError(503,'unavailable','Task session is not durable');
          await store.bindExecution(record.taskId,record.taskRev,
            {agentId,...(model.selected ? {provider:model.selected.provider,model:model.selected.model} : {}),prepared:false});
          return handle;
        } catch(error) { await handle.dispose(); throw error; }
      })();
      handles.set(agentId,opening);
      opening.catch(()=>{if(handles.get(agentId)===opening) handles.delete(agentId);});
    }
    const handle = await handles.get(agentId), agent = handle.agent, scope = agent.loopCtx ?? agent.ctx;
    model.guard();
    const [{setSandboxMode},{setApprovalPolicy}] = await Promise.all([
      import('@deepseek-ai/dsh-sandbox-policy'),import('@deepseek-ai/dsh-user-approval')]);
    if (model.policy && scope.get('sandboxPolicy')?.resolve({session:agent.session}).mode !== model.policy.mode)
      setSandboxMode(agent.session,model.policy.mode);
    if (scope.get('approval')?.effectivePolicy(agent.session) !== model.capturedApprovalPolicy)
      setApprovalPolicy(agent.session,model.capturedApprovalPolicy);
    if (await sessions.flush(agent.session) !== true) throw taskError(503,'unavailable','Task policy is not durably recorded');
    model.guard();
    const guard = () => {
      model.guard();
      if (agents.get(agentId) !== agent || agent.dshGoDeleting) throw taskError(409,'conflict','The original task agent changed');
    };
    const flush = async () => {
      if (await sessions.flush(agent.session) !== true) throw taskError(503,'unavailable','Task approval is not durably recorded');
    };
    const runTurn = job => agent.dshGoRunTaskTurn(async turnSignal => {
      const fused = signal ? AbortSignal.any([signal,turnSignal]) : turnSignal;
      fused.throwIfAborted();guard();return job(fused);
    });
    async function approve(stepKey,{requestedMode,justification},approvalSignal = signal) {
      guard();
      if (!model.policy || requestedMode === model.policy.mode) return copy(model.policy);
      const {approveEscalation} = await import('@deepseek-ai/dsh-sandbox');
      const approval = scope.get('approval');
      if (typeof approval?.dshGoRequestTask !== 'function') throw taskError(503,'unavailable','The original approval path is unavailable');
      const saved = store.read(record.taskId).notes[String(record.taskRev)]?.approval;
      if (saved && saved.stepKey === stepKey && saved.requestedMode === requestedMode && saved.policyFingerprint === model.policyFingerprint && saved.approvalPolicy === model.capturedApprovalPolicy) {
        const decision = agent.session.snapshotEvents().find(event => event.type === 'approval/decided' && event.data.id === saved.approvalId);
        if (decision) {
          await flush();await store.saveApproval(record.taskId,record.taskRev,{...saved,outcome:decision.data.outcome});
          if (decision.data.outcome === 'allowed-once') {guard();return {...model.policy,mode:requestedMode};}
          const foregroundRetry = decision.data.outcome === 'cancelled' && saved.foregroundInterrupted === true &&
            record.kind === TASK_KIND && record.agreement.afterExit === 'pause';
          if (decision.data.outcome === 'rejected' || decision.data.outcome === 'cancelled' && !foregroundRetry)
            throw taskError(409,'conflict','The original approval did not authorize this task step');
        } else {
          // A remote event not proven decided cannot be replaced by another visible card.
          throw taskError(503,'unavailable','The original task approval is still unresolved');
        }
      }
      return runTurn(async turnSignal => {
        const fused = approvalSignal ? AbortSignal.any([turnSignal,approvalSignal]) : turnSignal;
        let binding;
        const facade = {request: async request => {
          const response = await approval.dshGoRequestTask(request,{
            asked: async ({approvalId}) => {
              guard();await flush();
              binding = {taskRev:record.taskRev,stepKey,agentId,approvalId,eventId:null,callId:null,
                requestedMode,policyFingerprint:model.policyFingerprint,approvalPolicy:model.capturedApprovalPolicy,outcome:null};
              await store.saveApproval(record.taskId,record.taskRev,binding);guard();
            },
            remote: async ({approvalId,eventId,agentId:observedAgent}) => {
              guard();
              if (!binding || binding.approvalId !== approvalId || observedAgent !== agentId)
                throw taskError(409,'conflict','The task approval identity changed');
              binding = {...binding,eventId};await store.saveApproval(record.taskId,record.taskRev,binding);guard();
            },
          });
          const foregroundInterrupted = record.kind === TASK_KIND && record.agreement.afterExit === 'pause' &&
            response.outcome === 'cancelled' &&
            ['foreground_withdrawn','task_owner_stopping'].includes(response.signalCancellation?.reason?.notesReason);
          await flush();
          if (binding) await store.saveApproval(record.taskId,record.taskRev,{...binding,outcome:response.outcome,
            ...(foregroundInterrupted ? {foregroundInterrupted:true} : {})});
          return response.outcome;
        }};
        const mode = await approveEscalation({requestedMode,justification,effectiveMode:model.policy.mode,subject:'operation'},
          {approver:facade,agent,toolName:record.kind === 'host.receipts_to_sheet' ? 'companion.receipts.writeSheet' : 'companion.notes.writePage',signal:fused});
        guard();return {...model.policy,mode};
      });
    }
    return {agent,scope,llm:model.llm,selected:model.selected,fs:model.fs,guard,standingPolicy:copy(model.policy),
      runTurn,approve,flush};
  }
  return {openExecution,openModel:source,async close(){
    closing=true;
    const results=await Promise.allSettled([...handles.values()].map(async opening=>(await opening).dispose()));
    const failure=results.find(result=>result.status==='rejected');
    if(failure) throw failure.reason;
    handles.clear();
  }};
}
