import fs from '@ohos.file.fs';
import resourceManager from '@ohos.resourceManager';
import zlib from '@ohos.zlib';
import { RuntimeChannelError, RuntimeFile, RuntimeManifest } from './RuntimeCore';
import { RuntimeArchiveSource, RuntimeZip, RuntimeZipEntry, runtimeCrc32 } from './RuntimeZip';

export const RUNTIME_ARCHIVE_ASSET: string = 'dsh-runtime/runtime.zip';
const CHUNK: number = 256 * 1024;

class RawArchiveSource implements RuntimeArchiveSource {
  readonly length: number;
  private descriptor: resourceManager.RawFileDescriptor;

  constructor(descriptor: resourceManager.RawFileDescriptor) {
    if (!Number.isSafeInteger(descriptor.fd) || descriptor.fd < 0 || !Number.isSafeInteger(descriptor.offset) ||
        descriptor.offset < 0 || !Number.isSafeInteger(descriptor.length) || descriptor.length < 0 ||
        !Number.isSafeInteger(descriptor.offset + descriptor.length)) {
      throw new RuntimeChannelError('ohos_archive_invalid', '运行时原始资源描述符无效。');
    }
    this.descriptor = descriptor;
    this.length = descriptor.length;
  }

  async read(offset: number, length: number): Promise<ArrayBuffer> {
    if (!Number.isSafeInteger(offset) || !Number.isSafeInteger(length) || offset < 0 || length < 0 ||
        offset > this.length || length > this.length - offset || length > 32 * 1024 * 1024) {
      throw new RuntimeChannelError('ohos_archive_invalid', '运行时归档读取越界。');
    }
    const buffer = new ArrayBuffer(length);
    let done = 0;
    while (done < length) {
      // OH fs.read always starts at the beginning of its ArrayBuffer. A short
      // read must not overwrite bytes already received.
      const part = done === 0 ? buffer : new ArrayBuffer(length - done);
      const count = await fs.read(this.descriptor.fd, part, {
        offset: this.descriptor.offset + offset + done, length: length - done
      });
      if (!Number.isSafeInteger(count) || count <= 0 || count > length - done) {
        throw new RuntimeChannelError('ohos_read_failed', '运行时归档提前结束或读取长度无效。');
      }
      if (done !== 0) new Uint8Array(buffer).set(new Uint8Array(part, 0, count), done);
      done += count;
    }
    return buffer;
  }
}

class PendingInflate {
  zip: zlib.Zip;
  input: ArrayBuffer;
  output: ArrayBuffer;

  constructor(zip: zlib.Zip, input: ArrayBuffer, output: ArrayBuffer) {
    this.zip = zip;
    // Official NAPI stores raw buffer pointers, not copied input/output. Keep
    // both owners alive until inflateEnd has actually completed.
    this.input = input;
    this.output = output;
  }
}

export class OhosRuntimeArchive {
  // ResourceManager closes by asset name. Serialize sessions across storage
  // instances so a diagnostics query cannot close an installer's descriptor.
  private static queue: Promise<void> = Promise.resolve();
  private static pendingRaw: resourceManager.ResourceManager | null = null;
  private static pendingInflate: PendingInflate | null = null;
  private resources: resourceManager.ResourceManager;
  private source: RawArchiveSource | null = null;
  private index: RuntimeZip | null = null;
  private extracting: boolean = false;

  constructor(resources: resourceManager.ResourceManager) {
    // guestRoot and remote-only queries must remain free of resource/file I/O.
    this.resources = resources;
  }

  async readManifest(): Promise<RuntimeManifest> {
    if (this.index !== null) return this.index.manifest;
    await this.withBundledRuntime(async () => {});
    return this.requireIndex().manifest;
  }

  private requireIndex(): RuntimeZip {
    if (this.index === null) throw new RuntimeChannelError('ohos_archive_not_open', '运行时归档尚未打开。');
    return this.index;
  }

  async withBundledRuntime(work: () => Promise<void>): Promise<void> {
    const operation = OhosRuntimeArchive.queue.then(async () => {
      if (OhosRuntimeArchive.pendingInflate !== null) {
        const status = await OhosRuntimeArchive.pendingInflate.zip.inflateEnd({});
        if (status !== zlib.ReturnStatus.OK) throw new RuntimeChannelError('ohos_archive_close', '运行时解压状态未成功释放。');
        OhosRuntimeArchive.pendingInflate = null;
      }
      if (OhosRuntimeArchive.pendingRaw !== null) {
        await OhosRuntimeArchive.pendingRaw.closeRawFd(RUNTIME_ARCHIVE_ASSET);
        OhosRuntimeArchive.pendingRaw = null;
      }
      let opened = false;
      try {
        const descriptor = await this.resources.getRawFd(RUNTIME_ARCHIVE_ASSET);
        opened = true;
        this.source = new RawArchiveSource(descriptor);
        if (this.index === null) this.index = await RuntimeZip.read(this.source);
        else if (this.index.length !== this.source.length) {
          throw new RuntimeChannelError('ohos_archive_changed', '进程内运行时归档长度发生变化，请重开应用。');
        }
        await work();
      } finally {
        this.source = null;
        if (opened) {
          // If close rejects, the next session (even a new storage instance)
          // retries the retired owner before opening another raw descriptor.
          OhosRuntimeArchive.pendingRaw = this.resources;
          await this.resources.closeRawFd(RUNTIME_ARCHIVE_ASSET);
          OhosRuntimeArchive.pendingRaw = null;
        }
      }
    });
    OhosRuntimeArchive.queue = operation.catch(() => {});
    return operation;
  }

  async extract(file: RuntimeFile, write: (buffer: ArrayBuffer, length: number) => Promise<void>): Promise<void> {
    if (this.source === null) {
      await this.withBundledRuntime(async () => { await this.extract(file, write); });
      return;
    }
    if (this.extracting) throw new RuntimeChannelError('ohos_archive_busy', '运行时归档正在读取另一文件。');
    this.extracting = true;
    try {
      await this.inflate(this.source, this.requireIndex().file(file), write);
    } finally {
      this.extracting = false;
    }
  }

  private async inflate(source: RawArchiveSource, entry: RuntimeZipEntry,
    write: (buffer: ArrayBuffer, length: number) => Promise<void>): Promise<void> {
    const zip = await zlib.createZip();
    let input: ArrayBuffer = new ArrayBuffer(0);
    const output = new ArrayBuffer(CHUNK);
    let initialized = false;
    try {
      const init = await zip.inflateInit2({ nextIn: input, availableIn: 0, nextOut: output, availableOut: CHUNK }, -15);
      if (init !== zlib.ReturnStatus.OK) throw new RuntimeChannelError('ohos_archive_inflate', '运行时解压初始化失败。');
      initialized = true;
      let loaded = 0;
      let available = 0;
      let consumed = 0;
      let produced = 0;
      let crc = 0;
      const magic = new Uint8Array(4);
      while (true) {
        const request: zlib.ZStream = { nextOut: output, availableOut: CHUNK };
        if (available === 0 && loaded < entry.packedSize) {
          input = await source.read(entry.dataOffset + loaded, Math.min(CHUNK, entry.packedSize - loaded));
          loaded += input.byteLength;
          available = input.byteLength;
          request.nextIn = input;
          request.availableIn = available;
        }
        const status = await zip.inflate(request, zlib.CompressFlushMode.NO_FLUSH);
        // inflate does not mutate `request`; this is the public way to obtain
        // the updated internal counters. getZStreamSync is not in our SDK.
        const state = await zip.getZStream();
        if (state.availableIn === undefined || state.availableOut === undefined ||
            state.totalIn === undefined || state.totalOut === undefined ||
            !Number.isSafeInteger(state.availableIn) || !Number.isSafeInteger(state.availableOut) ||
            state.availableIn < 0 || state.availableIn > available ||
            state.availableOut < 0 || state.availableOut > CHUNK) {
          throw new RuntimeChannelError('ohos_archive_inflate', '运行时解压状态无效。');
        }
        const used = available - state.availableIn;
        const count = CHUNK - state.availableOut;
        if (state.totalIn !== consumed + used || state.totalOut !== produced + count ||
            produced + count > entry.size) {
          throw new RuntimeChannelError('ohos_size_mismatch', '运行时解压长度超过清单或内部计数不一致。');
        }
        if (produced < 4 && count > 0) {
          magic.set(new Uint8Array(output, 0, Math.min(count, 4 - produced)), produced);
          if (produced + count >= 4 && magic[0] === 127 && magic[1] === 69 && magic[2] === 76 && magic[3] === 70) {
            throw new RuntimeChannelError('ohos_native_payload', '原生 ELF 必须随 HAP 的 libs 交付，不能落地到可写目录。');
          }
        }
        crc = runtimeCrc32(new Uint8Array(output, 0, count), crc);
        if (count > 0) await write(output, count);
        consumed += used;
        produced += count;
        available = state.availableIn;
        if (status === zlib.ReturnStatus.STREAM_END) {
          if (loaded !== entry.packedSize || available !== 0 || consumed !== entry.packedSize ||
              produced !== entry.size || crc !== entry.crc) {
            throw new RuntimeChannelError('ohos_checksum_failed', '运行时归档成员的长度或 CRC 校验失败。');
          }
          return;
        }
        if (status !== zlib.ReturnStatus.OK || (used === 0 && count === 0) ||
            (available === 0 && loaded === entry.packedSize && count < CHUNK)) {
          throw new RuntimeChannelError('ohos_archive_inflate', '运行时压缩流未正常结束。');
        }
      }
    } finally {
      if (initialized) {
        const pending = new PendingInflate(zip, input, output);
        OhosRuntimeArchive.pendingInflate = pending;
        const status = await zip.inflateEnd({});
        if (status !== zlib.ReturnStatus.OK) throw new RuntimeChannelError('ohos_archive_close', '运行时解压状态未成功释放。');
        OhosRuntimeArchive.pendingInflate = null;
      }
    }
  }
}
