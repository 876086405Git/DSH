import { randomUUID } from 'node:crypto';
import { lstatSync, realpathSync } from 'node:fs';
import { guestSuspendedMessage } from './metadata.mjs';

const denied = () => Object.assign(new Error('ERR_IOS_GUEST_ROOT_GRANT: invalid, cancelled, changed or already used Linux system-disk grant'), { code: 'ERR_IOS_GUEST_ROOT_GRANT' });
const suspended = () => Object.assign(new Error(guestSuspendedMessage), { code: 'ERR_IOS_GUEST_SUSPENDED' });
const identityNumber = value => typeof value === 'string' && /^(0|[1-9][0-9]{0,19})$/.test(value)
  && BigInt(value) <= 0xffffffffffffffffn;
export function createRootWriteGrants({ root, identity, readMetadata }) {
  // The native Owner holds this directory open until its last coordinator ends.
  // A fresh lstat alone could mistake a deleted/reinstalled root with a reused
  // inode for the installation the user approved. Never replace this identity.
  if (!identityNumber(identity?.expectedRootDevice) || !identityNumber(identity?.expectedRootInode)
    || typeof readMetadata !== 'function') throw denied();
  const permission = Object.freeze({ expectedRootDevice: identity.expectedRootDevice,
    expectedRootInode: identity.expectedRootInode });
  const device = BigInt(permission.expectedRootDevice), inode = BigInt(permission.expectedRootInode);
  const key = Symbol('ios guest root write capability');
  const pending = new WeakMap(), staged = new WeakMap();
  const generation = randomUUID();
  let active = true;
  const checkGeneration = () => {
    if (!active) throw denied();
    if (readMetadata()?.suspended === true) throw suspended();
    let now;
    try { now = lstatSync(root, { bigint: true }); } catch { throw denied(); }
    if (now.dev !== device || now.ino !== inode || !now.isDirectory()) throw denied();
  };
  checkGeneration();
  const matches = (record, argv, policy) => record.generation === generation && record.agent.session === record.session &&
    argv.length === 3 && argv[0] === 'bash' && argv[1] === '-c' && argv[2] === record.command &&
    realpathSync(policy.workspaceRoot) === record.workspace && policy.mode === record.mode;
  return Object.freeze({
    async authorize({ reason, command, cwd, policy, approver, agent, callId, signal }) {
      if (typeof reason !== 'string' || !reason.trim() || reason.length > 4096 || !agent?.session ||
          typeof callId !== 'string' || !callId || !signal || typeof approver?.request !== 'function') throw denied();
      if (typeof command !== 'string' || !['read-only', 'workspace-write', 'danger-full-access'].includes(policy?.mode)) throw denied();
      signal.throwIfAborted(); checkGeneration();
      const workspace = realpathSync(policy.workspaceRoot), directory = realpathSync(cwd);
      const mode = policy.mode, session = agent.session;
      const scope = '仅本次命令：允许修改已安装 Linux 的持久系统盘（包括软件包与系统配置），更改会保留到后续命令；不扩大宿主工作区权限。';
      const outcome = await approver.request({ agent, toolName: 'bash', callId, signal,
        reason: scope + ' ' + reason.trim() });
      signal.throwIfAborted(); checkGeneration();
      if (agent.session !== session) throw denied();
      if (outcome !== 'allowed-once') throw Object.assign(new Error('Linux system-disk write approval ' + outcome), { code: 'ERR_IOS_GUEST_ROOT_APPROVAL' });
      const token = Object.freeze({ nonce: randomUUID() });
      const record = { generation, command, cwd: directory, workspace, mode, agent, session,
        callId, signal };
      pending.set(token, record);
      return { ...policy, [key]: token };
    },
    prepare(argv, policy, signal) {
      const descriptor = Object.getOwnPropertyDescriptor(policy, key);
      if (!descriptor) return undefined;
      if (!('value' in descriptor)) throw denied();
      const token = descriptor.value, record = pending.get(token);
      if (!record) throw denied();
      pending.delete(token);
      if (record.signal.aborted || signal?.aborted || !matches(record, argv, policy)) throw denied();
      checkGeneration();
      const ticket = Object.freeze({});
      record.executionSignal = signal;
      staged.set(ticket, record);
      return ticket;
    },
    activate(ticket, argv, policy, cwd, signal) {
      if (ticket === undefined) return undefined;
      const record = staged.get(ticket);
      staged.delete(ticket);
      if (!record || record.signal.aborted || record.executionSignal !== signal || signal?.aborted || !matches(record, argv, policy) || realpathSync(cwd) !== record.cwd) throw denied();
      checkGeneration();
      return permission;
    },
    // Revocation cannot close the native anchor: a failed JS drain can precede
    // an already running coordinator's initialize/start/cleanup.
    close() { active = false; },
  });
}
