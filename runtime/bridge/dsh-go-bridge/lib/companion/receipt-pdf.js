// PDF text extraction is optional; importing this module does not load PDF.js.
import { Worker } from 'node:worker_threads';
import * as nodeModule from 'node:module';

const MAX_BYTES = 4 * 1024 * 1024;
const require = nodeModule.createRequire(import.meta.url);

export function canReadReceiptPdf() {
  const [major, minor] = process.versions.node.split('.').map(Number);
  if (!((major > 22 || (major === 22 && minor >= 13)) &&
      typeof nodeModule.registerHooks === 'function')) return false;
  try { return require('pdfjs-dist/package.json').version === '6.5.438'; }
  catch { return false; }
}

function failure(code) {
  return Object.assign(new Error(code), { code });
}

/** Lines are PDF.js extraction order, not OCR or reconstructed visual lines. */
export async function readReceiptPdf(bytes, { signal, maxPages = 5, maxTextBytes = MAX_BYTES } = {}) {
  signal?.throwIfAborted();
  if (!canReadReceiptPdf()) throw failure('pdf_runtime_unavailable');
  if (!(bytes instanceof Uint8Array) || !bytes.byteLength) throw failure('pdf_invalid');
  if (bytes.byteLength > MAX_BYTES) throw failure('pdf_input_limit');
  if (!Number.isInteger(maxPages) || maxPages < 1 || maxPages > 5 ||
      !Number.isInteger(maxTextBytes) || maxTextBytes < 1 || maxTextBytes > MAX_BYTES) {
    throw new TypeError('PDF limits must be within the supported bounds');
  }
  // A separate copy avoids detaching the caller's original, version-checked input.
  const data = Uint8Array.from(bytes);
  const worker = new Worker(new URL('./receipt-pdf-worker.js', import.meta.url), {
    workerData: { data, maxPages, maxTextBytes }, transferList: [data.buffer],
    resourceLimits: { maxOldGenerationSizeMb: 128, maxYoungGenerationSizeMb: 8, stackSizeMb: 4 },
    // Keep inherited runtime preloads and V8 settings, including the OHOS owner.
    stdout: true, stderr: true,
  });
  // Parser diagnostics can contain source text. The caller receives bounded error codes.
  worker.stdout.resume();
  worker.stderr.resume();
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = async (error, value) => {
      if (settled) return;
      settled = true;
      signal?.removeEventListener('abort', abort);
      await worker.terminate();
      if (error !== undefined) reject(error);
      else resolve(value);
    };
    const abort = () => { void finish(signal.reason); };
    worker.on('message', message => {
      void finish(message.error ? failure(message.error) : undefined, message.value);
    });
    worker.on('error', error => {
      void finish(failure(error.code === 'ERR_WORKER_OUT_OF_MEMORY' ? 'pdf_resource_limit' : 'pdf_worker_failed'));
    });
    worker.on('exit', () => { void finish(failure('pdf_worker_failed')); });
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) abort();
  });
}
