import { Any, MethodCall } from '@ohos/flutter_ohos';

export class NativeMediaError extends Error {
  readonly code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

export class NativeMediaKey {
  readonly owner: string;
  readonly generation: number;
  readonly lease: string;
  private constructor(owner: string, generation: number, lease: string) {
    this.owner = owner; this.generation = generation; this.lease = lease;
  }
  static parse(call: MethodCall): NativeMediaKey {
    const owner: Any = call.argument('owner');
    const generation: Any = call.argument('generation');
    const lease: Any = call.argument('lease');
    if (typeof owner !== 'string' || !/^[0-9a-f]{16,64}$/.test(owner) ||
        typeof generation !== 'number' || !Number.isSafeInteger(generation) || generation < 0 || generation > 2147483647 ||
        typeof lease !== 'string' || lease.length < 1 || lease.length > 256 || /[\x00-\x1f\x7f]/.test(lease)) {
      throw new NativeMediaError('bad-request', '媒体操作缺少有效的所有者、世代或授权。');
    }
    return new NativeMediaKey(owner, generation, lease);
  }
  matches(call: MethodCall): boolean {
    return call.argument('owner') === this.owner && call.argument('generation') === this.generation && call.argument('lease') === this.lease;
  }
}

export function nativeClipRelative(cacheDir: string, key: NativeMediaKey, path: Any, type: Any): string {
  const relative = 'native-media/' + key.owner + '/clip';
  if (!cacheDir.startsWith('/') || cacheDir.endsWith('/') || /[\x00-\x1f\x7f]/.test(cacheDir) ||
      typeof path !== 'string' || path !== cacheDir + '/' + relative || typeof type !== 'string' ||
      !['audio/mpeg', 'audio/wav', 'audio/ogg', 'audio/mp4', 'audio/aac'].includes(type)) {
    throw new NativeMediaError('media-invalid', '只能播放当前所有者下载到应用缓存的音频片段。');
  }
  return relative;
}
