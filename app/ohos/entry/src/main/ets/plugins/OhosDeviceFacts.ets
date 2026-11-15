// Public OH facts only. No identifiers, Android SDK substitution, or native-host import.
import hidebug from '@ohos.hidebug';
import deviceInfo from '@ohos.deviceInfo';
import { Any } from '@ohos/flutter_ohos';

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

export function performanceDeviceFacts(): Map<string, Any> {
  const bytes = systemMemoryBytes();
  // Same existing product memory cutoff as Android. This is a default, not a benchmark.
  const low = bytes !== null && bytes < 5 * 1024 * 1024 * 1024;
  const facts: Map<string, Any> = new Map<string, Any>();
  facts.set('policyVersion', 1);
  facts.set('platform', 'ohos');
  facts.set('tier', low ? 'low' : 'medium');
  facts.set('reasons', low ? ['memory_below_5_gib'] : ['no_low_tier_evidence']);
  facts.set('totalMemoryBytes', bytes);
  facts.set('lowRam', null);
  facts.set('cpuCores', null);
  facts.set('availableProcessors', null);
  facts.set('cpuMaxKhz', []);
  facts.set('mediaPerformanceClass', null);
  facts.set('cached', false);
  facts.set('measuredAtMs', Date.now());
  // No Android sdkInt and no high tier inferred from an OH API number.
  try { facts.set('apiVersion', deviceInfo.sdkApiVersion); } catch (_) {}
  return facts;
}
