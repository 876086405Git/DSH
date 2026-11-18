// 只执行已安装 bundle 的真实投影、组件和折叠分支；React/slot 是无浏览器边界适配。
// 不代表真实 React 订阅、DOM 布局或真机验证；每次显式渲染读取最新数据源。
// DSH_TEST_PREFIX=<已补丁前缀> node --test runtime/tests/web-empty-reply-notice.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import vm from 'node:vm';

const prefix = process.env.DSH_TEST_PREFIX ?? process.env.DSH_PREFIX;
if (!prefix) throw Error('请设置 DSH_TEST_PREFIX 或 DSH_PREFIX，指向已补丁的运行时');
const bundle = join(resolve(prefix), 'node_modules/@deepseek-ai/dsh-client-ui-chat/lib/client.js');
const source = readFileSync(bundle, 'utf8');
function region(name) {
  const marker = `//#region lib/types/client/${name}.js`;
  const start = source.indexOf(marker);
  const end = source.indexOf('//#endregion', start);
  assert(start >= 0 && end > start, `缺少真实 bundle 区域：${name}`);
  return source.slice(start, end);
}
const program = new vm.Script([
  region('contract/assistant-content'),
  region('contract/turn-process'),
  region('contract/group-tree'),
  region('stores'),
  region('conversation-nodes/common'),
  region('conversation-nodes/event-projection'),
  region('conversation-nodes/turn-process'),
  region('conversation-nodes/turn-tail'),
  region('chat/message-chrome'),
  region('chat/turn-assistant'),
  region('chat/use-turn-data'),
  region('chat/TurnProcessNodeView'),
  region('chat/TurnTailNodeView'),
  region('chat/ChatNodeSeat'),
  region('locale'),
  '({TurnTailNodeView, TurnProcessNodeView, ChatNodeSeat, turnProcessDefinition,',
  'updateProcessState, processSpec, tailData, toAssistantBlocks, hasAssistantReplyContent,',
  'useTurnDataValue, zh, en})',
].join('\n'), { filename: bundle });

function vnode(type, props = {}, key) { return { type, props, key }; }
function render(value) {
  if (Array.isArray(value)) return value.map(render);
  if (value === null || value === undefined || typeof value !== 'object') return value;
  if (typeof value.type === 'function') return render(value.type(value.props));
  return { ...value, props: { ...value.props, children: render(value.props.children) } };
}
function elements(value, predicate) {
  if (Array.isArray(value)) return value.flatMap(child => elements(child, predicate));
  if (value === null || typeof value !== 'object') return [];
  return [...(predicate(value) ? [value] : []), ...elements(value.props.children, predicate)];
}
function text(value) {
  if (Array.isArray(value)) return value.map(text).join('');
  if (value === null || value === undefined || typeof value === 'boolean') return '';
  return typeof value === 'object' ? text(value.props.children) : String(value);
}
const notices = tree => elements(tree, node => node.props['data-turn-no-reply'] !== undefined);
const statuses = tree => elements(tree, node => node.props.role === 'status');
const buttons = tree => elements(tree, node => node.type === 'button');
const reasoning = [{ type: 'reasoning', text: '继续分析中' }];
const prose = [{ type: 'text', text: '这是一条正文答复。' }];
const image = [{ type: 'image', attachment: { id: 'fixture-image' } }];

function fixture(locale = 'zh') {
  const sideEffects = [], effects = [], turnDataReads = [], slotCalls = [], hidden = [];
  const forbidden = name => (...args) => {
    sideEffects.push({ name, args });
    throw Error(`展示无答复提示不应执行副作用：${name}`);
  };
  const react = {
    memo: component => component,
    createElement: vnode,
    useMemo: callback => callback(),
    useCallback: callback => callback,
    useRef: current => ({ current }),
    useState: initial => [typeof initial === 'function' ? initial() : initial, forbidden('setState')],
    useEffect: setup => { effects.push(setup); },
    useSyncExternalStore: (_subscribe, getSnapshot) => getSnapshot(),
  };
  const api = program.runInNewContext({
    react,
    react_jsx_runtime: { jsx: vnode, jsxs: vnode, Fragment: 'fragment' },
    _deepseek_ai_dsh_client_store: {
      createSnapshotStore(initial) {
        let value = initial;
        return { getSnapshot: () => value, set: next => { value = next; } };
      },
    },
    _deepseek_ai_dsh_client_ui_primitives: {
      IconChevronDownOutlineRegular: 'chevron-icon', JsonBlock: 'fixture-json',
    },
    TurnProcessNodeView_module_css_default: {},
    TurnTailNodeView_module_css_default: {},
    ChatView_module_css_default: {},
    accessibility_module_css_default: {},
    MessageIconActions: 'fixture-message-actions',
    TurnUsagePanel: 'fixture-usage',
    fetch: forbidden('fetch'),
    WebSocket: forbidden('WebSocket'),
    setTimeout: forbidden('setTimeout'),
    setInterval: forbidden('setInterval'),
    queueMicrotask: forbidden('queueMicrotask'),
  });
  const dictionary = api[locale];
  const t = (key, parameters = {}) => {
    assert.equal(typeof dictionary[key], 'string', `缺少 ${locale} 文案：${key}`);
    return dictionary[key].replace(/\{(\w+)\}/g, (_, name) => String(parameters[name]));
  };
  function run(component, props) {
    const result = render(component(props));
    for (const setup of effects.splice(0)) {
      const cleanup = setup();
      cleanup?.();
    }
    assert.deepEqual(sideEffects, [], '组件挂载及 effect 不得调用模型、工具或自动重试');
    return result;
  }
  function turn({ messages = [], tools = [], reason = 'completed', status = 'closed' } = {}) {
    const start = { type: 'turn/start', seq: 1, time: 1000, data: { turn: 1 } };
    const end = { type: 'turn/end', seq: 100, time: 126000, data: { turn: 1, reason: { kind: reason } } };
    const value = {
      turn: 1, status, start, ...(status === 'closed' ? { end } : {}),
      steps: [], data: new Map(),
    };
    // 数据源只提供读边界，内容判定与计数均由实际 bundle 生成。
    value.data.source = key => ({ subscribe: () => () => {}, getSnapshot: () => value.data.get(key) });
    let state = api.turnProcessDefinition.start(undefined, { event: start });
    const events = [start];
    for (const [index, name] of tools.entries()) {
      const event = { type: 'tool/call', seq: 2 + index, data: { turn: 1, step: 1, name } };
      events.push(event);
      state = api.updateProcessState(state, event);
    }
    for (const [index, content] of messages.entries()) {
      const step = index + 1, seq = 10 + index * 10;
      const event = {
        type: 'assistant/message', seq, time: 2000 + index * 1000, surfaceOp: 'append',
        data: { turn: 1, step, message: { content } },
      };
      events.push(event);
      state = api.updateProcessState(state, event);
      value.steps.push({ step, status: 'closed', data: new Map([['assistant-step', {
        turn: 1, step, blocks: api.toAssistantBlocks(content), time: event.time,
        finalNode: { seq, messageId: `assistant-${step}` },
      }]]) });
    }
    const spec = api.processSpec(state, value);
    assert.notEqual(spec, null);
    value.data.set('turn-process', spec);
    const location = { kind: 'turn', turn: value };
    const matches = [...events, ...(status === 'closed' ? [end] : [])].map(event => ({ event, location }));
    const data = api.tailData({
      matches, ...(status === 'closed' ? { state: { end: { event: end, location } } } : {}),
    }) ?? { turn: 1, seq: end.seq, time: end.time, closing: null, branchUnavailable: true };
    const tail = { key: 'tail', kind: 'turn-tail', groupTree: 'turn', anchorSeq: 100.1, location, data };
    const control = { key: 'process', kind: 'turn-process', groupTree: 'turn', anchorSeq: 0.9, location, data: spec };
    const assistants = value.steps.map(step => ({
      key: `assistant-${step.step}`, kind: 'assistant-step', anchorSeq: step.data.get('assistant-step').finalNode.seq,
      groupTree: 'process', location: { kind: 'step', turn: value, step }, data: step.data.get('assistant-step'),
    }));
    const nodes = new Map([control, ...assistants, tail].map(node => [node.key, node]));
    const snapshot = {
      nodes, locations: { getTurn: () => [...nodes.keys()] }, timeline: { turnOrder: [1] },
    };
    return { value, spec, tail, control, snapshot };
  }
  function tailProps(f, plugin = null) {
    return {
      node: f.tail, t,
      openFile: forbidden('openFile'), forkAt: forbidden('forkAt'),
      useAccess: () => true, usePerformanceUsage: select => select('detailed'),
      useChat: select => select(f.snapshot),
      useTurnData(key) {
        turnDataReads.push(key);
        return api.useTurnDataValue(f.value.data, key);
      },
      renderSlot(name, props) {
        slotCalls.push({ name, props });
        assert(['conversation.chat.turnTail', 'conversation.chat.assistant-actions'].includes(name));
        return name === 'conversation.chat.turnTail' ? plugin : null;
      },
    };
  }
  const tail = (f, plugin = null) => run(api.TurnTailNodeView, tailProps(f, plugin));
  const summary = f => run(api.TurnProcessNodeView, {
    node: f.control, t,
    turnProcess: { spec: f.spec, foldable: true, hasContent: true, open: false, setOpen: forbidden('setOpen') },
  });
  function seat(f, foldCompletedTurns, plugin) {
    const props = tailProps(f, plugin);
    return run(api.ChatNodeSeat, {
      nodeKey: f.tail.key,
      useChatNodeBottom: () => false, useChatNode: () => f.tail,
      useChatNodeProcess: () => ({
        spec: f.spec, turn: 1, turnStarted: true, turnClosed: true,
        hasExternalProcess: true, hasNonReplyProcess: true, hasInterleavedInput: false,
      }),
      usePresentation: select => select({ foldCompletedTurns, foldedReplies: 'all' }),
      useStore: select => select({ turnProcesses: [{ turn: 1, answerStep: f.spec.answerStep ?? 0, collapsed: true }] }),
      actions: { setTurnProcessOpen: forbidden('setTurnProcessOpen') },
      useGroupAction(isHidden) { hidden.push(isHidden); return { current: null }; },
      renderSlot(name, owner, options) {
        assert.equal(name, 'conversation.chat.node');
        assert.equal(options.entryKey, 'turn-tail');
        assert.equal(options.hookContext.turnData, f.value.data);
        return vnode(api.TurnTailNodeView, { ...props, ...owner });
      },
      t, deferCollapse: false,
    });
  }
  return { api, t, turn, tail, summary, seat, run, tailProps, sideEffects, turnDataReads, slotCalls, hidden };
}

for (const locale of ['zh', 'en']) {
  test(`${locale}：completed 空回合没有 closing 或插件仍显示可访问的无答复提示`, () => {
    const f = fixture(locale), state = f.turn();
    assert.equal(state.tail.data.closing, null);
    assert.equal(state.spec.answerAnchorSeq, null);
    assert.equal(state.spec.messageCount, 0);
    const tree = f.tail(state);
    assert.equal(notices(tree).length, 1);
    assert.equal(notices(tree)[0].props['data-turn-no-reply'], true);
    assert.equal(notices(tree)[0].props.role, 'status');
    assert.equal(text(notices(tree)[0]), f.t('message.turnNoReply'));
    assert.match(text(tree), locale === 'zh' ? /(没有|未收到).*答复/ : /(without|no).*reply/i);
    assert.deepEqual(f.turnDataReads, ['turn-process']);
    assert.equal(f.slotCalls[0].name, 'conversation.chat.turnTail');
  });

  test(`${locale}：无答复摘要和 aria 通告不是成功完成，也不拼接时长`, () => {
    const f = fixture(locale), state = f.turn({ messages: [reasoning] });
    const tree = f.summary(state);
    assert.equal(buttons(tree).length, 1);
    assert.equal(text(buttons(tree)[0]), f.t('message.turnProcess.noReply'));
    assert.equal(statuses(tree).length, 1);
    assert.equal(text(statuses(tree)[0]), f.t('message.turnProcess.noReply'));
    assert.notEqual(text(statuses(tree)[0]), f.t('message.turnProcess.worked'));
    assert.equal(statuses(tree)[0].props['aria-live'], 'polite');
    assert.equal(statuses(tree)[0].props['aria-atomic'], 'true');
    if (locale === 'zh') assert.equal(text(buttons(tree)[0]), '未收到答复');
  });
}

for (const [label, messages, tools] of [
  ['纯思考', [reasoning], []],
  ['空白正文', [[{ type: 'text', text: ' \n\t ' }]], []],
  ['工具协议', [[{ type: 'tool-call', id: 'call-1', name: 'read', arguments: '{}' }]], ['read']],
  ['没有 assistant 的工具回合', [], ['read', 'subagent']],
]) {
  test(`${label}：真实 processSpec 仍判定无正文，显示提示而不执行工具`, () => {
    const f = fixture(), state = f.turn({ messages, tools });
    assert.equal(state.spec.answerAnchorSeq, null);
    assert.equal(state.spec.messageCount, 0);
    assert.equal(notices(f.tail(state)).length, 1);
    assert.equal(text(buttons(f.summary(state))[0]), '未收到答复');
    assert.deepEqual(f.sideEffects, []);
  });
}

for (const [label, messages, count, hasAnchor] of [
  ['最后一步有正文', [prose], 0, true],
  ['最后一步有图片', [image], 0, true],
  ['最后一步有音频', [[{ type: 'audio', attachment: { id: 'fixture-audio' } }]], 0, true],
  ['早先正文而末步纯思考', [prose, reasoning], 1, false],
  ['早先图片而末步纯思考', [image, reasoning], 1, false],
]) {
  test(`${label}：真实内容投影保持正常完成，不误报整轮无答复`, () => {
    const f = fixture(), state = f.turn({ messages });
    assert.equal(state.spec.messageCount, count);
    assert.equal(state.spec.answerAnchorSeq !== null, hasAnchor);
    assert.equal(f.api.hasAssistantReplyContent(f.api.toAssistantBlocks(messages[0])), true);
    const tree = f.tail(state);
    assert.equal(notices(tree).length, 0);
    const processTree = f.summary(state);
    assert.equal(text(statuses(processTree)[0]), f.t('message.turnProcess.worked'));
    assert.match(text(buttons(processTree)[0]), /已完成，用时 /);
    assert.notEqual(text(buttons(processTree)[0]), f.t('message.turnProcess.took'));
  });
}

test('无 process spec 不误报，缺失 turn location 的早退之前仍调用 useTurnData', () => {
  const f = fixture(), state = f.turn();
  state.value.data.delete('turn-process');
  assert.equal(notices(f.tail(state)).length, 0);
  state.tail = { ...state.tail, location: { kind: 'unresolved' } };
  assert.equal(f.tail(state), null);
  assert.deepEqual(f.turnDataReads, ['turn-process', 'turn-process']);
});

for (const [reason, expected] of [
  ['aborted', 'message.stopped'], ['interrupted', 'message.stopped'], ['error', 'message.turnProcess.failed'],
]) {
  test(`${reason}：保留停止或失败摘要，不显示 completed 无答复提示`, () => {
    const f = fixture(), state = f.turn({ reason });
    assert.equal(notices(f.tail(state)).length, 0);
    const tree = f.summary(state);
    assert.equal(text(buttons(tree)[0]), f.t(expected));
    assert.equal(text(statuses(tree)[0]), f.t(expected));
  });
}

test('max-tokens：不显示新增无答复提示，摘要保持原有行为', () => {
  const f = fixture(), state = f.turn({ reason: 'max-tokens', messages: [reasoning] });
  assert.equal(state.spec.answerAnchorSeq, null);
  assert.equal(state.spec.messageCount, 0);
  assert.equal(notices(f.tail(state)).length, 0);
  const tree = f.summary(state);
  assert.equal(text(statuses(tree)[0]), f.t('message.turnProcess.worked'));
  assert.match(text(buttons(tree)[0]), /已完成，用时 /);
});

test('历史 completed 空回合即使后面已有新 turn，仍保留无答复提示', () => {
  const f = fixture(), state = f.turn({ messages: [reasoning] });
  state.snapshot.timeline.turnOrder.push(2);
  assert.equal(state.tail.data.turn, 1);
  assert.equal(state.snapshot.timeline.turnOrder.at(-1), 2);
  const tree = f.tail(state);
  assert.equal(tree.props['data-turn-tail'], 1);
  assert.equal(notices(tree).length, 1);
  assert.equal(text(notices(tree)[0]), f.t('message.turnNoReply'));
});

for (const foldCompletedTurns of [false, true]) {
  test(`foldCompletedTurns=${foldCompletedTurns}：真实 ChatNodeSeat 不过滤 tail，提示与插件共存`, () => {
    const f = fixture(), state = f.turn({ messages: [reasoning] });
    const plugin = vnode('aside', { 'data-plugin-tail': true, children: '插件尾部保留' });
    const tree = f.seat(state, foldCompletedTurns, plugin);
    assert.equal(tree.props['data-chat-flow-kind'], 'turn-tail');
    assert.equal(tree.props['data-turn-process-member'], undefined);
    assert.equal(tree.props['data-turn-process-hidden'], undefined);
    assert.deepEqual(f.hidden, [false]);
    assert.equal(notices(tree).length, 1);
    assert.equal(elements(tree, node => node.props['data-plugin-tail'] === true).length, 1);
    assert.match(text(tree), /插件尾部保留/);
    assert.equal(f.slotCalls.filter(call => call.name === 'conversation.chat.turnTail').length, 1);
  });
}

test('早先正文 closing 与末步思考的真实投影保留插件和消息操作，不误报无答复', () => {
  const f = fixture(), state = f.turn({ messages: [prose, reasoning] });
  assert.notEqual(state.tail.data.closing, null);
  assert.equal(state.spec.answerAnchorSeq, null);
  assert.equal(state.spec.messageCount, 1);
  const tree = f.tail(state, vnode('aside', { 'data-plugin-tail': true, children: '插件' }));
  assert.equal(notices(tree).length, 0);
  assert.equal(elements(tree, node => node.props['data-plugin-tail'] === true).length, 1);
  const actions = elements(tree, node => node.type === 'fixture-message-actions');
  assert.equal(actions.length, 1);
  assert.equal(actions[0].props.text, prose[0].text);
  assert.deepEqual(f.sideEffects, []);
});

test('运行到 completed 再收到 late 正文，提示随真实 spec 更新消失且不自动调用', () => {
  const f = fixture(), state = f.turn({ status: 'open', messages: [reasoning] });
  assert.equal(notices(f.tail(state)).length, 0);
  assert.equal(f.summary(state), null);
  state.value.status = 'closed';
  state.value.end = { type: 'turn/end', seq: 100, time: 126000, data: { turn: 1, reason: { kind: 'completed' } } };
  assert.equal(notices(f.tail(state)).length, 1);
  assert.equal(text(buttons(f.summary(state))[0]), '未收到答复');
  const late = f.turn({ messages: [reasoning, prose] });
  state.spec = late.spec;
  state.control.data = late.spec;
  state.value.data.set('turn-process', late.spec);
  state.value.steps = late.value.steps;
  state.tail.data = late.tail.data;
  state.snapshot = late.snapshot;
  assert.equal(notices(f.tail(state)).length, 0);
  assert.equal(text(statuses(f.summary(state))[0]), f.t('message.turnProcess.worked'));
  assert.deepEqual(f.turnDataReads, ['turn-process', 'turn-process', 'turn-process']);
  assert.deepEqual(f.sideEffects, []);
});
