// The trusted OH preload captures one fixed HAP library before plugins load.
// This module never chooses a backend from an environment flag or caller input.
import { Buffer } from 'node:buffer';
import { createRequire } from 'node:module';

const key = Symbol.for('dsh.go.ohos.image-codec');
const CAP = 50 * 1024 * 1024;
const BUILD_PREFIX = 'oh-image-ndk26-v1;decode=rgba8-sdr-srgb;resize=high-fit-inside;orient=explicit;quality=85,75,60;cap=52428800;verify=container+decode;getcolor=';
const mediaTypes = new Set(['image/png', 'image/jpeg', 'image/webp', 'image/gif']);
const maxLimits = Object.freeze({ maxSide: 0xffffffff, maxPixels: Number.MAX_SAFE_INTEGER });

function failure(code, message, stage, cause, retired) {
  const error = new Error(message, cause === undefined ? undefined : { cause });
  Object.assign(error, { code, stage, encodingCapBytes: CAP });
  if (typeof retired === 'boolean') error.resourcesRetired = retired;
  return error;
}

function snapshot(data) {
  if (!(data instanceof Uint8Array) || !(data.buffer instanceof ArrayBuffer)) {
    throw failure('INVALID_IMAGE', 'Expected non-shared encoded image bytes.', 'input');
  }
  // Bind header admission and full decode to the same bytes. The bridge makes
  // its own native snapshot and retains that storage until confirmed close.
  return Buffer.from(data);
}

function dimensions(facts) {
  if (!facts || !Number.isSafeInteger(facts.width) || facts.width <= 0 ||
      !Number.isSafeInteger(facts.height) || facts.height <= 0 ||
      !mediaTypes.has(facts.mimeType)) {
    throw failure('OHOS_IMAGE_CODEC_UNAVAILABLE', 'Image structural facts are incomplete.', 'source-facts');
  }
}

function imageMetadata(facts) {
  dimensions(facts);
  if (!Number.isInteger(facts.orientation) || facts.orientation < 1 || facts.orientation > 8) {
    throw failure('OHOS_IMAGE_CODEC_UNAVAILABLE', 'The image orientation could not be established.', 'source-orientation');
  }
  const transposed = facts.orientation >= 5;
  return {
    mediaType: facts.mimeType,
    width: transposed ? facts.height : facts.width,
    height: transposed ? facts.width : facts.height,
    animated: Number.isSafeInteger(facts.frameCount) && facts.frameCount > 0 ? facts.frameCount > 1 : undefined,
    carriesMetadata: typeof facts.retainedMetadata === 'boolean' ? facts.retainedMetadata : undefined,
    depth: facts.bitDepth === 8 ? 'uchar' : facts.bitDepth === 16 ? 'ushort' : undefined,
    space: facts.colorSpace === 'srgb' || facts.colorSpace === 'other' ? facts.colorSpace : undefined,
    hasAlpha: typeof facts.hasAlpha === 'boolean' ? facts.hasAlpha : undefined,
  };
}

function limitsFor(limits) {
  const side = limits?.maxDimension ?? maxLimits.maxSide;
  const pixels = limits?.maxPixels ?? maxLimits.maxPixels;
  if (!Number.isSafeInteger(side) || side <= 0 || !Number.isSafeInteger(pixels) || pixels <= 0) {
    throw failure('INVALID_IMAGE', 'Image admission limits must be positive integers.', 'source-limits');
  }
  return { maxSide: Math.min(side, maxLimits.maxSide), maxPixels: pixels };
}

function checkedTarget(target) {
  if (!target || !Number.isInteger(target.width) || target.width <= 0 || target.width > 0xffffffff ||
      !Number.isInteger(target.height) || target.height <= 0 || target.height > 0xffffffff ||
      !Number.isSafeInteger(target.maxBytes) || target.maxBytes <= 0) {
    throw failure('ATTACHMENT_WRITE_FAILED', 'Image encoding target is invalid.', 'encode-target');
  }
}

function postCloseError(error) {
  // Retain the native operation error as cause; its pre-close retirement field
  // is a historical observation, not the result of our subsequent close.
  const result = failure(error?.code ?? 'ATTACHMENT_WRITE_FAILED',
    error instanceof Error ? error.message : 'Image operation failed.',
    error?.stage ?? 'image-operation', error, true);
  if (typeof error?.nativeStatus === 'number') result.nativeStatus = error.nativeStatus;
  result.retirement = Object.freeze({ closeRequested: true, confirmed: true });
  return result;
}

async function usingFrame(open, data, limits, operation) {
  // Failed opens are cleaned by the bridge before rejection. When retirement
  // cannot be confirmed, its original error retains the failed owner.
  const frame = await open(data, limits);
  if (!frame || typeof frame.close !== 'function') {
    throw failure('OHOS_IMAGE_CLEANUP_UNCONFIRMED', 'Image frame has no close contract.', 'frame-contract', undefined, false);
  }
  const close = frame.close.bind(frame);
  let value;
  let error;
  let failed = false;
  try {
    value = await operation(frame);
  } catch (cause) {
    failed = true;
    error = cause;
  }
  try {
    await close();
  } catch (cleanup) {
    const cause = failed ? new AggregateError([error, cleanup], 'Image operation and close both failed.') : cleanup;
    const retired = cleanup?.resourcesRetired === true;
    const result = failure(retired ? 'ATTACHMENT_WRITE_FAILED' : 'OHOS_IMAGE_CLEANUP_UNCONFIRMED',
      'Image resource cleanup did not complete successfully.', cleanup?.stage ?? 'close', cause, retired);
    if (typeof cleanup?.nativeStatus === 'number') result.nativeStatus = cleanup.nativeStatus;
    result.retirement = Object.freeze({ closeRequested: true, confirmed: retired });
    throw result;
  }
  if (failed) throw postCloseError(error);
  return value;
}

function checkedEncoded(value, source, target, format) {
  const facts = value?.encodedFacts;
  const mimeType = format === 'jpeg' ? 'image/jpeg' : 'image/webp';
  if (!(value?.data instanceof Uint8Array) || value.data.byteLength === 0 || value.data.byteLength > CAP ||
      ![85, 75, 60].includes(value.quality) || value.mimeType !== mimeType || facts?.mimeType !== mimeType ||
      !Number.isSafeInteger(facts.width) || facts.width <= 0 || !Number.isSafeInteger(facts.height) || facts.height <= 0 ||
      facts.width > target.width || facts.height > target.height || facts.width > source.width || facts.height > source.height ||
      facts.frameCount !== 1 || facts.orientation !== 1 || facts.bitDepth !== 8 || facts.colorSpace !== 'srgb' ||
      facts.retainedMetadata !== false || typeof facts.hasAlpha !== 'boolean') {
    throw failure('ATTACHMENT_WRITE_FAILED', 'Native encoding did not return verified image facts.', 'encoded-facts');
  }
  const expectedAlpha = source.mediaType === 'image/gif' ? undefined : source.hasAlpha;
  if (expectedAlpha !== undefined && facts.hasAlpha !== expectedAlpha &&
      !(expectedAlpha && !facts.hasAlpha && mimeType === 'image/webp')) {
    throw failure('ATTACHMENT_WRITE_FAILED', 'Native encoding changed the source alpha contract.', 'encoded-alpha');
  }
  return {
    // The bridge output owns independent storage; closing the frame cannot
    // release this ArrayBuffer. This view does not copy another C-sized result.
    data: new Uint8Array(value.data.buffer, value.data.byteOffset, value.data.byteLength),
    mediaType: mimeType,
    width: facts.width,
    height: facts.height,
    hasAlpha: facts.hasAlpha,
  };
}

if (process.platform === 'openharmony') {
  let native;
  let descriptor;
  let loadFailure;
  try {
    const require = createRequire(import.meta.url);
    const binding = require('@dsh-go/ohos-native').load('image-codec').binding;
    const policy = binding.colorGetterPolicy;
    if (binding.available !== true || binding.fixtureOnly !== false ||
        !['destroy', 'borrow'].includes(policy) || binding.codecIdentity !== BUILD_PREFIX + policy ||
        typeof binding.inspect !== 'function' || typeof binding.open !== 'function') {
      throw failure('OHOS_IMAGE_CODEC_UNAVAILABLE', 'The packaged image codec is not the expected production build.', 'backend-identity');
    }
    native = Object.freeze({ inspect: binding.inspect.bind(binding), open: binding.open.bind(binding) });
    descriptor = Object.freeze({
      buildId: binding.codecIdentity,
      resizeAlgorithm: 'NDK_HIGH_FIT_INSIDE_WITHOUT_ENLARGEMENT',
      orientation: 'explicit',
      colourspace: 'srgb',
      qualityLadder: Object.freeze([85, 75, 60]),
      encodingCapBytes: CAP,
      alphaSelection: 'known-opaque:jpeg;alpha-or-unknown:webp',
      outputVerification: 'container+decode',
      colorGetterPolicy: policy,
    });
  } catch (cause) {
    loadFailure = cause;
  }
  function ready() {
    if (!native) throw failure('OHOS_IMAGE_CODEC_UNAVAILABLE',
      'The packaged OpenHarmony image codec is unavailable.', 'load', loadFailure);
    return native;
  }
  const service = Object.freeze({
    protocolVersion: 1,
    identity() { ready(); return descriptor; },
    async probe(data) {
      // Container facts only: never infer source sRGB/alpha from converted pixels.
      return imageMetadata(await ready().inspect(snapshot(data)));
    },
    async detect(data, limits) {
      const binding = ready();
      const bytes = snapshot(data);
      const budget = limitsFor(limits);
      const facts = await binding.inspect(bytes);
      dimensions(facts);
      // Preserve attachment admission order: total pixels, then side length.
      if (BigInt(facts.width) * BigInt(facts.height) > BigInt(budget.maxPixels)) {
        throw failure('IMAGE_TOO_MANY_PIXELS', 'Image exceeds the configured decoded-pixel limit.', 'source-pixels');
      }
      if (Math.max(facts.width, facts.height) > budget.maxSide) {
        throw failure('IMAGE_DIMENSION_TOO_LARGE', 'Image exceeds the configured per-side pixel limit.', 'source-side');
      }
      return usingFrame(binding.open, bytes, budget, (frame) => imageMetadata(frame.sourceFacts));
    },
    async encode(data, target) {
      const binding = ready();
      checkedTarget(target);
      return usingFrame(binding.open, snapshot(data), maxLimits, async (frame) => {
        const source = imageMetadata(frame.sourceFacts);
        if (typeof frame.encode !== 'function') throw failure('ATTACHMENT_WRITE_FAILED', 'Image frame cannot encode.', 'frame-contract');
        const format = source.hasAlpha === false ? 'jpeg' : 'webp';
        const encoded = await frame.encode({ width: target.width, height: target.height, softMaxBytes: target.maxBytes, format });
        // The native finite ladder runs once; JavaScript neither retries a
        // failed quality nor treats the soft target as an allocation capacity.
        return checkedEncoded(encoded, source, target, format);
      });
    },
  });
  Object.defineProperty(globalThis, key, { value: service, configurable: false, writable: false });
}
