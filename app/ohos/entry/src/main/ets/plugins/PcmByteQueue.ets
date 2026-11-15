// Fixed-capacity byte ring. The caller owns complete-chunk admission and PCM alignment.
// It neither retains a caller's backing buffer nor allocates another PCM backing buffer in a read.
export class PcmByteQueue {
  private readonly bytes: Uint8Array;
  private head: number = 0;
  private length: number = 0;

  constructor(capacity: number) {
    if (!Number.isSafeInteger(capacity) || capacity < 2 || capacity % 2 !== 0) {
      throw new Error('invalid PCM queue capacity');
    }
    this.bytes = new Uint8Array(capacity);
  }

  get size(): number { return this.length; }
  get capacity(): number { return this.bytes.byteLength; }

  append(source: Uint8Array): boolean {
    if (source.byteLength > this.capacity - this.length) return false;
    const tail = (this.head + this.length) % this.capacity;
    const first = Math.min(source.byteLength, this.capacity - tail);
    this.bytes.set(source.subarray(0, first), tail);
    if (first < source.byteLength) this.bytes.set(source.subarray(first), 0);
    this.length += source.byteLength;
    return true;
  }

  take(destination: Uint8Array, count: number): void {
    if (!Number.isSafeInteger(count) || count < 0 || count > this.length || count > destination.byteLength) {
      throw new Error('invalid PCM queue read');
    }
    const first = Math.min(count, this.capacity - this.head);
    destination.set(this.bytes.subarray(this.head, this.head + first), 0);
    if (first < count) destination.set(this.bytes.subarray(0, count - first), first);
    this.head = (this.head + count) % this.capacity;
    this.length -= count;
  }

  clear(): void { this.head = 0; this.length = 0; }
}
