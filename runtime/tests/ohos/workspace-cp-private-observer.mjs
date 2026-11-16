// Test-only, module-local observations. No built-in replacement or strong byte references.
const tags = new WeakMap();
const reads = [], conversions = [], writes = [];
let nextId = 1;
export function observeRead(bytes, size, partCount) {
  const id = nextId++;
  tags.set(bytes, id);
  reads.push({ id, size, partCount, isBuffer: Buffer.isBuffer(bytes), byteLength: bytes.byteLength });
}
export function copyFrom(...args) {
  // This is the original operation, called only if the source conversion branch is evaluated.
  const result = Buffer.from(...args);
  const content = args[0];
  conversions.push({ readId: content !== null && typeof content === 'object' ? tags.get(content) ?? null : null,
    outputBytes: result.byteLength, inputBytes: content?.byteLength ?? null });
  return result;
}
export function observeWrite(content, bytes, target) {
  writes.push({ target, readId: tags.get(content) ?? null,
    inputBytes: content.byteLength, outputBytes: bytes.byteLength,
    inputIsBuffer: Buffer.isBuffer(content), sameObject: content === bytes,
    sameBacking: content.buffer === bytes.buffer });
}
export function observations() {
  return { reads: reads.map(row => ({ ...row })), conversions: conversions.map(row => ({ ...row })),
    writes: writes.map(row => ({ ...row })) };
}
