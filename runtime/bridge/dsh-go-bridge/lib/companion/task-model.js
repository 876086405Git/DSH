// Shared bounded model stream for the two fixed companion tasks. No tools or chat turn.
import {usageReceipt, errorCode} from './auxiliary.js';
import {NotesTaskError} from './notes-content.js';

export async function runTaskModel({store, claim, owner, signal, guard: current,
  system, input, capability, inputEstimate, outputTokens}) {
  const estimateBody = JSON.stringify({system, messages: [{role: 'user', content: [{type: 'text', text: input}]}]});
  const receipt = {provider: owner.selected.provider, model: owner.selected.model,
    rawUsageAvailable: capability.rawUsage === 'deepseek-messages-cumulative',
    dispatched: false, dispatchAtMs: null, handoffAtMs: null, httpStatus: null,
    startUsage: null, finalUsage: null, stopReason: null, complete: false, terminal: 'incomplete',
    normalizedUsage: [], runtimeFinishKind: null};
  let writes = Promise.resolve(), persistenceFailure = null, contextWindow = null, inputBudget = null;
  let streamEntered = false, transportObserved = false;
  const persistenceAbort = new AbortController();
  const callSignal = AbortSignal.any([signal, persistenceAbort.signal]);
  const observed = event => {
    const data = structuredClone(event);
    if (Buffer.byteLength(JSON.stringify(data)) > 65536) throw new NotesTaskError('model_usage_limit', 'failed');
    writes = writes.then(() => store.observeStep(claim, data));
    writes.catch(error => { persistenceFailure ??= error; persistenceAbort.abort(error); });
  };
  const observe = event => {
    transportObserved = true;
    if (event.type === 'dispatch') {receipt.dispatched = true; receipt.dispatchAtMs = event.atMs;}
    else if (event.type === 'handoff') {receipt.dispatched = null; receipt.handoffAtMs = event.atMs;}
    else if (event.type === 'http') receipt.httpStatus = event.status;
    else if (event.type === 'stop') receipt.stopReason = event.stopReason;
    else if (event.type === 'complete') receipt.complete = true;
    else if (event.type === 'usage') {
      if (!event.raw || typeof event.raw !== 'object' || Array.isArray(event.raw)) throw new NotesTaskError('model_usage_invalid', 'failed');
      if (event.event === 'message_start') receipt.startUsage = structuredClone(event.raw);
      else if (event.event === 'message_delta') receipt.finalUsage = structuredClone(event.raw);
      else throw new NotesTaskError('model_usage_invalid', 'failed');
    }
    observed(dataObservation(event));
  };
  const check = () => {callSignal.throwIfAborted(); current(); if (persistenceFailure) throw persistenceFailure;};
  const checkRequest = (body, boundary) => {
    inputBudget = {...inputEstimate(body, contextWindow), boundary};
    return Number.isSafeInteger(contextWindow) && inputBudget.accepted;
  };
  let text = '', outputBytes = 0, finish = null, caught = null;
  try {
    const reasoningEffort = receipt.rawUsageAvailable ? 'off' : owner.selected.reasoningEffort;
    const call = await owner.llm.prepareCompanionAuxiliaryCall({provider: receipt.provider, model: receipt.model,
      ...(reasoningEffort === undefined ? {} : {reasoningEffort}), maxTokens: outputTokens},
      callSignal, {guard: check, observe, checkRequest});
    check();
    contextWindow = call.contextWindow;
    if (!Number.isSafeInteger(contextWindow) || contextWindow <= 0) throw new NotesTaskError('model_context_window_unknown');
    if (!inputEstimate(estimateBody, contextWindow).accepted) throw new NotesTaskError('model_input_limit');
    if (call.config.provider !== receipt.provider || call.config.model !== receipt.model ||
      call.config.maxTokens !== outputTokens || reasoningEffort !== undefined && call.config.reasoningEffort !== reasoningEffort)
      throw new NotesTaskError('model_selection_changed');
    streamEntered = true;
    for await (const chunk of call.stream({system: system, input})) {
      check();
      if (chunk.type === 'tool-call-delta' || chunk.type === 'block-start' && chunk.blockType === 'tool-call')
        throw new NotesTaskError('model_tool_output', 'failed');
      if (chunk.type === 'text-delta' || chunk.type === 'reasoning-delta') {
        if (typeof chunk.text !== 'string') throw new NotesTaskError('model_output_invalid', 'failed');
        outputBytes += Buffer.byteLength(chunk.text);
        if (outputBytes > 65536) throw new NotesTaskError('model_output_limit', 'failed');
        if (chunk.type === 'text-delta') text += chunk.text;
      }
      if (chunk.type === 'finish') finish = chunk.reason;
      if (chunk.type === 'usage' && !receipt.rawUsageAvailable) {
        if (!chunk.usage || typeof chunk.usage !== 'object' || Array.isArray(chunk.usage))
          throw new NotesTaskError('model_usage_invalid', 'failed');
        receipt.normalizedUsage.push(structuredClone(chunk.usage));
        if (Buffer.byteLength(JSON.stringify(receipt.normalizedUsage)) > 65536)
          throw new NotesTaskError('model_usage_limit', 'failed');
        observed({type: 'runtime-usage', semantics: 'runtime-normalized', usage: chunk.usage});
      }
    }
    if (!receipt.rawUsageAvailable) {
      receipt.runtimeFinishKind = finish?.kind ?? null;
      receipt.complete = ['stop', 'max-tokens'].includes(finish?.kind) || ['REFUSAL', 'EMPTY_RESPONSE'].includes(finish?.failure?.code);
    }
    receipt.terminal = receipt.complete && finish?.kind === 'stop' ? 'complete'
      : finish?.kind === 'max-tokens' ? 'max_tokens' : finish?.kind === 'aborted' ? 'cancelled' : 'provider_error';
  } catch (error) {
    caught = error;
    if (receipt.dispatched === false && !transportObserved && !callSignal.aborted) {
      if (!(caught instanceof NotesTaskError)) caught = new NotesTaskError(
        errorCode(error) === 'COMPANION_LOOKUP_INPUT_LIMIT' ? 'model_input_limit' : 'model_preflight_unavailable');
      if (caught.notesState === 'waiting') caught.notesPreflightProof = {preflightDispatched: false, streamEntered};
    }
    receipt.terminal = callSignal.aborted ? 'cancelled' : receipt.dispatched === false ? 'preflight_error' : 'unconfirmed';
  }
  finally {
    // Await every observation and the original iterator's close before releasing the owner.
    await writes;
    const usage = usageReceipt(receipt);
    await store.observeStep(claim, {type: 'model-finish', dispatched: receipt.dispatched,
      httpStatus: receipt.httpStatus, usage, inputBudget,
      reason: caught ? errorCode(caught) : null});
  }
  if (caught) throw caught;
  check();
  if (receipt.terminal !== 'complete') throw new NotesTaskError('model_result_incomplete', receipt.complete ? 'failed' : 'unknown');
  return {text, inputBudget, usage: usageReceipt(receipt)};
}

function dataObservation(event) {
  if (event.type === 'usage') return {type: 'usage', event: event.event, semantics: 'cumulative', raw: event.raw};
  if (event.type === 'dispatch' || event.type === 'handoff') return {type: event.type, atMs: event.atMs, boundary: event.boundary};
  if (event.type === 'http') return {type: 'http', status: event.status};
  if (event.type === 'stop') return {type: 'stop', stopReason: event.stopReason};
  if (event.type === 'complete') return {type: 'complete'};
  throw new NotesTaskError('model_observation_invalid', 'failed');
}
