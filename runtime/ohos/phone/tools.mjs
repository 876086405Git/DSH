import { HarnessError } from '@deepseek-ai/dsh-llm';
import { ToolArgsError, validateJsonSchemaValue } from '@deepseek-ai/dsh-tools';
import { phoneCatalog, phoneResultSchema } from './catalog.mjs';

const rejected = (code, message) => ({ status: 'failed', effect: 'none', evidence: 'unknown', dispatched: false, code, message });
const render = value => [{ type: 'text', text: JSON.stringify(value) }];
// handoff is itself a question to the person, so it isn't asked about first.
const asked = {
  mcp__phone__open: ['打开', 'Open'], mcp__phone__intent: ['系统动作', 'System action'],
  mcp__phone__notify: ['发通知', 'Send a notification'], mcp__phone__clipboard: ['写入剪贴板', 'Write to the clipboard'],
};
const target = args => [args?.url, args?.app, args?.kind, args?.number, args?.title, args?.destination, args?.page, args?.text, args?.set]
  .filter(value => typeof value === 'string' && value.trim()).join(' · ').slice(0, 300);

// Nothing else in the engine asks about these tools outside Auto review, so they ask the
// way it does: the session's policy and the chat's approval card decide, and a preset
// that never prompts (full access) runs them unasked as it runs everything else.
function askBeforeRunning(ctx, queue) {
  return ctx.on('tools/pre-execute', async (exec, next) => {
    const decision = await next();
    const [zh, en] = asked[exec.name] ?? [];
    const session = exec.agent?.session, approval = ctx.get('approval');
    if (decision.kind !== 'allow' || !zh || !session || !approval || !queue.canRun()) return decision;
    if (approval.effectivePolicy(session) === 'never' || ctx.get('permissionPresets')?.current(session) === 'auto') return decision;
    const what = target(exec.arguments);
    return { kind: 'ask', reason: `Phone action ${exec.name}: ${what}`,
      displayReason: { zh: what ? `${zh}：${what}` : zh, en: what ? `${en}: ${what}` : en } };
  });
}

export function registerPhoneTools(ctx, queue) {
  const disposers = [];
  try {
  disposers.push(askBeforeRunning(ctx, queue));
  for (const definition of phoneCatalog) {
    const outcomes = new WeakMap();
    disposers.push(ctx.tools.register({ ...definition,
      // Cooperative backstop; the queue/native permit enforce 30s/600s BOOTTIME deadlines.
      timeoutMs: 640_000,
      output: { schema: phoneResultSchema, render: (_args, value) => render(value) },
      async execute(args, exec) {
        const invalid = validateJsonSchemaValue(definition.parameters, args);
        if (invalid.length) throw new ToolArgsError(invalid);
        let result;
        if (typeof exec.agent?.id !== 'string' || !exec.agent.id || typeof exec.callId !== 'string' || !exec.callId) {
          result = rejected('missing_call_identity', '手机操作需要真实会话和工具调用身份。');
        } else if (definition.name === 'mcp__phone__open') {
          if (Boolean(args.app?.trim()) === Boolean(args.url?.trim())) result = rejected('invalid_args', 'open需要app或url，二选一。');
          else if (args.background === true) result = rejected('unsupported', '鸿蒙不支持后台屏；请让DSH保持前台，使用background:false。');
        } else if (definition.name === 'mcp__phone__clipboard') {
          if (args.set !== undefined && args.get === true) result = rejected('invalid_args', 'clipboard的set和get一次只能用一个。');
          else if (args.get === true) result = rejected('unsupported', '鸿蒙手机回调只支持写剪贴板；请让用户直接粘贴需要的内容。');
          else if (args.set === undefined) result = rejected('invalid_args', 'clipboard需要set写入文字。');
        } else if (definition.name === 'mcp__phone__notify' && (!args.title.trim() || !args.text.trim())) {
          result = rejected('invalid_args', 'notify需要非空title和text。');
        } else if (definition.name === 'mcp__phone__handoff' && !args.reason.trim()) {
          result = rejected('invalid_args', 'handoff需要reason说明用户要做什么。');
        }
        if (!result) {
          try { result = await queue.enqueue({ sessionId: exec.agent.id, callId: exec.callId,
            tool: definition.name, args, signal: exec.signal }); }
          catch (error) { result = rejected(error.code ?? 'unavailable', error.message); }
        }
        outcomes.set(exec, result);
        if (result.status !== 'succeeded') throw new HarnessError(JSON.stringify(result), `OHOS_PHONE_${result.code.toUpperCase()}`);
        return result;
      },
      finalizeContent(exec, result) {
        const phone = outcomes.get(exec); outcomes.delete(exec);
        if (!phone || !result.isError || result.error.info?.code?.startsWith('OHOS_PHONE_')) return;
        // Preserve timeout/cancellation/post-policy errors. Add only bounded effect evidence, never arguments.
        const { status, effect, evidence, dispatched, code } = phone;
        return [...result.content, { type: 'text', text: `手机端结果证据：${JSON.stringify({ status, effect, evidence, dispatched, code })}` }];
      },
    }));
  }
  } catch (error) {
    for (const dispose of disposers.reverse()) dispose();
    throw error;
  }
  return () => { for (const dispose of disposers.reverse()) dispose(); };
}
