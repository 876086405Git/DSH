import { isMainThread } from 'node:worker_threads';
const failure = () => Object.assign(new Error('Trusted native host lifecycle is unavailable'), { code: 'ERR_OHOS_LIFECYCLE_NATIVE' });
export function readNativeHost() {
  if (!isMainThread) throw failure();
  const binding = process._linkedBinding('dsh_ohos_publication');
  if (typeof binding.getHostLifecycleSnapshot !== 'function') throw failure();
  return validateHostSnapshot(binding.getHostLifecycleSnapshot());
}
export function validateHostSnapshot(value) {
  const integers = ['engineGeneration', 'ownerGeneration', 'revision', 'grantGeneration', 'deadlineMs', 'drainAtMs', 'phase'];
  if (!value || value.version !== 1 || integers.some(key => !Number.isSafeInteger(value[key]) || value[key] < 0) ||
      !Number.isSafeInteger(value.nowMs) || value.nowMs < -1 || ![0, 1].includes(value.available) ||
      ![0, 1].includes(value.foreground) || ![0, 1].includes(value.clockFailed) || value.phase > 7) throw failure();
  return Object.freeze({ ...value });
}
export function nativeAllows(value) {
  return value?.available === 1 && value.clockFailed === 0 && value.nowMs >= 0 &&
    (value.foreground === 1 || value.phase === 7 || (value.phase === 2 && value.nowMs < value.drainAtMs && value.nowMs < value.deadlineMs));
}
