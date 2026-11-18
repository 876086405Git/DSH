export const guestInstallRequiredMessage = 'ERR_IOS_GUEST_INSTALL_REQUIRED: 请先在设置中安装 Linux 环境，然后重新启动本机引擎。';
export const guestSuspendedMessage = 'ERR_IOS_GUEST_SUSPENDED: Linux 环境上次运行未正常结束，已暂停；请在设置中重新启用，然后重新启动本机引擎。';
// Owner-side metadata store only. No channel/native imports, filesystem probes,
// command execution, or guest boot. Publishing is a trusted bootstrap operation;
// it must never be exposed as a model/config/HTTP mutation API.
const unknown = Object.freeze({
  v: 1, source: 'none', state: 'unavailable', installed: 'unknown',
  available: false, enforcement: 'unknown', python: 'unknown',
  hint: '可连接电脑执行；可选 Linux 环境须由 App 安装并确认可用。',
});
const oneOf = (v, choices) => choices.includes(v);
export function createGuestMetadataStore() {
  let cached = unknown;
  return Object.freeze({
    read: () => cached,
    // A JSON transport value cannot invoke arbitrary property getters while
    // normalizing it. A malformed/new unsupported report replaces stale ready.
    publishJSON(text) {
      cached = unknown;
      if (typeof text !== 'string' || text.length > 4096) return false;
      let value;
      try { value = JSON.parse(text); } catch { return false; }
      if (!value || value.v !== 1 ||
          !oneOf(value.source, ['ios-native-owner', 'linux-test']) ||
          !oneOf(value.state, ['disabled', 'ready', 'busy', 'faulted', 'unavailable', 'suspended']) ||
          !oneOf(value.installed, ['present', 'absent', 'unknown']) ||
          typeof value.available !== 'boolean' ||
          !oneOf(value.enforcement, ['none', 'partial', 'strong', 'unknown']) ||
          !oneOf(value.python, ['supported', 'unsupported', 'unknown'])) return false;
      const suspended = value.suspended === true || value.state === 'suspended';
      const available = !suspended && value.available && value.installed === 'present' &&
        ['ready', 'busy'].includes(value.state);
      cached = Object.freeze({
        v: 1, source: value.source, state: suspended ? 'suspended' : value.state,
        installed: value.installed, available,
        suspended, suspendedReason: suspended ? 'crashed' : null,
        enforcement: value.enforcement === 'strong' ? 'unknown' : value.enforcement, python: value.python,
        // Test readiness is never presented as installed iSH capability.
        testOnly: value.source === 'linux-test',
        hint: value.source === 'linux-test' ? '仅 Linux 测试后端，不证明 iSH 或 Apple 能力。' : unknown.hint,
      });
      return true;
    },
    clear() { cached = unknown; },
  });
}
export function guestDescription(metadata) {
  if (metadata?.suspended || metadata?.state === 'suspended') return guestSuspendedMessage;
  if (!metadata || metadata.source === 'none') return '可选 Linux 执行环境当前不可用，安装状态未知。' + unknown.hint;
  if (metadata.testOnly) return '当前仅接入 Linux 测试后端，不代表 iSH 已安装或可用于设备。';
  if (!metadata.available) return '可选 Linux 执行环境当前不可用（' + metadata.state + '）。' + unknown.hint;
  return '可信原生 owner 的缓存报告：Linux 执行环境可用；约束状态为 ' + metadata.enforcement + '。本查询没有启动或探测环境。'
    + '普通 shell 脚本（包括环境探测、管道、脚本文件和批量 stdin）默认整段在 Linux /bin/sh（Alpine ash）执行，不保证 Bash 专有语法。'
    + '缺少 git、rg、jq 等命令时请在 Linux 内安装；失败不会回退到虚拟 shell。'
    + '仅静态明确且不混用 Linux 或不透明执行的 node <script.js|script.cjs|script.mjs> 脚本仍使用引擎 Node Worker；混合脚本先拒绝、不执行。'
    + '未选择 Node Worker 的动态命令或 source/eval 全在 Linux 内执行，其中的 node 指 Linux 程序，不是引擎 Worker。'
    + '宿主仅映射工作区 /workspace 和私有临时目录 /tmp；完全权限也不会扩大这些宿主挂载范围。';
}

// Apply transport/queue availability without booting or probing either one.
export function guestMetadataView(cached, hasTransport, queueState) {
  const store = createGuestMetadataStore();
  try { store.publishJSON(JSON.stringify(cached)); } catch {}
  const value = store.read();
  const state = value.suspended ? 'suspended' : !hasTransport ? 'unavailable' : ['faulted', 'closed'].includes(queueState) ? queueState : value.state;
  return Object.freeze({...value, state, available: value.available && hasTransport && !['faulted', 'closed'].includes(queueState)});
}
