// Public OH facts only. No identifiers, Android SDK substitution, or native-host import.
import hidebug from '@ohos.hidebug';
import deviceInfo from '@ohos.deviceInfo';
import display from '@ohos.display';
import process from '@ohos.process';
import { Any } from '@ohos/flutter_ohos';

// Android's PerformanceRules.LOW_MEMORY_BYTES and MAX_CPUS.
const LOW_MEMORY_BYTES: number = 5 * 1024 * 1024 * 1024;
const MAX_CPUS: number = 128;
// _SC_NPROCESSORS_CONF and _SC_NPROCESSORS_ONLN of the system's libc (sysroot unistd.h).
const SC_CPUS_CONFIGURED: number = 83;
const SC_CPUS_ONLINE: number = 84;
// What stands in for Android's declared media performance class in a high tier. The panel
// is the one capability the system declares here. It says nothing measured.
const HIGH_REFRESH_HZ: number = 90;

export function systemMemoryBytes(): number | null {
  if (!canIUse('SystemCapability.HiviewDFX.HiProfiler.HiDebug')) return null;
  try {
    // Public getSystemMemInfo reports /proc/meminfo MemTotal in KB.
    const bytes = Number(hidebug.getSystemMemInfo().totalMem) * 1024;
    return Number.isSafeInteger(bytes) && bytes > 0 ? bytes : null;
  } catch (_) { return null; }
}

export function ohosDeviceIdentity(): Map<string, Any> {
  const facts: Map<string, Any> = new Map<string, Any>();
  facts.set('platform', 'ohos');
  try {
    facts.set('manufacturer', deviceInfo.manufacture);
    facts.set('brand', deviceInfo.brand);
    facts.set('model', deviceInfo.productModel);
    facts.set('osVersion', deviceInfo.osFullName);
    facts.set('apiVersion', deviceInfo.sdkApiVersion);
    facts.set('abis', deviceInfo.abiList.split(',').map((value: string): string => value.trim()).filter((value: string): boolean => value.length > 0));
  } catch (_) { /* Missing facts remain absent, never invented. */ }
  return facts;
}

function cpuCount(name: number): number | null {
  try {
    const count = new process.ProcessManager().getSystemConfig(name);
    return Number.isInteger(count) && count > 0 && count <= MAX_CPUS ? count : null;
  } catch (_) { return null; }
}

function supportedRefreshRates(): number[] {
  try {
    const rates: number[] = display.getDefaultDisplaySync().supportedRefreshRates ?? [];
    return rates.filter((rate: number): boolean => Number.isFinite(rate) && rate > 0);
  } catch (_) { return []; }
}

// Android's PerformanceRules.classify and reasons, on the facts this system has.
function tierReasons(bytes: number | null, cores: number | null): string[] {
  const reasons: string[] = [];
  if (bytes !== null && bytes < LOW_MEMORY_BYTES) reasons.push('memory_below_5_gib');
  if (cores !== null && cores <= 2) reasons.push('at_most_two_cores');
  return reasons;
}

export function performanceDeviceFacts(): Map<string, Any> {
  const bytes = systemMemoryBytes();
  const cores = cpuCount(SC_CPUS_CONFIGURED);
  const rates = supportedRefreshRates();
  const low = tierReasons(bytes, cores);
  // A default, not a benchmark. Dart only ever asks whether this is low.
  const high = low.length === 0 && bytes !== null && cores !== null && cores >= 4 &&
    rates.some((rate: number): boolean => rate >= HIGH_REFRESH_HZ);
  const facts: Map<string, Any> = new Map<string, Any>();
  facts.set('policyVersion', 1);
  facts.set('platform', 'ohos');
  facts.set('tier', low.length > 0 ? 'low' : high ? 'high' : 'medium');
  facts.set('reasons', low.length > 0 ? low : [high ? 'declared_refresh_with_capacity' : 'no_low_tier_evidence']);
  facts.set('totalMemoryBytes', bytes);
  facts.set('lowRam', null);
  facts.set('cpuCores', cores);
  facts.set('availableProcessors', cpuCount(SC_CPUS_ONLINE));
  facts.set('cpuMaxKhz', []);
  facts.set('supportedRefreshRates', rates);
  facts.set('mediaPerformanceClass', null);
  facts.set('cached', false);
  facts.set('measuredAtMs', Date.now());
  // No Android sdkInt, and no tier inferred from an OH API number.
  try { facts.set('apiVersion', deviceInfo.sdkApiVersion); } catch (_) {}
  return facts;
}
