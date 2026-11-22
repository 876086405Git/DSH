import { fail } from './errors.js';

// Strict RFC 4648 standard alphabet and canonical zero padding bits.
// Validate before Buffer.from: Node's base64 decoder is intentionally permissive.
export function base64DecodedLength(value, limit) {
  if (!Number.isSafeInteger(limit) || limit < 1) fail('invalid_request');
  if (typeof value !== 'string' || value.length === 0 || value.length % 4 !== 0) {
    fail('response');
  }
  if (value.length > 4 * Math.ceil(limit / 3)) fail('too_large');
  const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
  const length = value.length / 4 * 3 - padding;
  if (length > limit) fail('too_large');
  const end = value.length - padding;
  // Only the known trailing padding may fall outside the base64 alphabet.
  const firstInvalid = value.search(/[^A-Za-z0-9+/]/);
  if (firstInvalid !== (padding ? end : -1)) fail('response');
  if (padding) {
    const last = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'.indexOf(value[end - 1]);
    if ((last & (padding === 2 ? 15 : 3)) !== 0) fail('response');
  }
  return length;
}
