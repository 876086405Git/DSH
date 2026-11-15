import fs from '@ohos.file.fs';
import util from '@ohos.util';
import hilog from '@ohos.hilog';
import { huks } from '@kit.UniversalKeystoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@ohos.base';

export class SecretStorageError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

class SecretRecord {
  key: string;
  value: string;
  constructor(key: string, value: string) { this.key = key; this.value = value; }
}

// Only ciphertext is written to the app-private directory. The key stays in HUKS.
// One queue spans plugin/engine instances in this process; it is not a cross-process lock.
export class SecretVault {
  private static tail: Promise<void> = Promise.resolve();
  private static durabilityWarned: boolean = false;
  private static readonly alias: string = 'DSH.Go.Secrets.AES256.GCM.v1';
  private static readonly chunkSize: number = 64 * 1024;
  private readonly directory: string;
  private readonly path: string;

  constructor(filesDir: string) {
    this.directory = filesDir + '/dsh-secrets';
    this.path = this.directory + '/vault-v1.bin';
  }

  private unreadable(): SecretStorageError {
    return new SecretStorageError('secrets_unreadable', '已保存的凭据无法验证或读取，原加密数据未被覆盖。');
  }

  private unavailable(): SecretStorageError {
    return new SecretStorageError('secrets_unavailable', '系统安全密钥暂不可用，原加密数据已保留。');
  }

  private queue<T>(operation: () => Promise<T>): Promise<T> {
    const work = SecretVault.tail.then(operation);
    SecretVault.tail = work.then((): void => {}, (): void => {});
    return work.catch((error: Error): T => {
      if (error instanceof SecretStorageError) throw error;
      throw new SecretStorageError('secrets_io', '无法读写本机加密凭据，请重试。');
    });
  }

  private header(): Uint8Array { return new Uint8Array([68, 83, 72, 83, 1, 0, 0, 0]); }
  private aad(): Uint8Array { return new util.TextEncoder().encodeInto('DSH-Go private secrets vault v1'); }

  private generationParameters(): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_CE },
      // API 20+, within this app's API 26 minimum. Never replace an existing key.
      { tag: huks.HuksTag.HUKS_TAG_KEY_OVERRIDE, value: false }
    ];
  }

  private async key(existingCiphertext: boolean): Promise<void> {
    try {
      if (await this.hasKey()) return;
      if (existingCiphertext) {
        throw new SecretStorageError('secrets_key_missing', '已保存的凭据缺少系统密钥，原加密数据已保留。');
      }
      const generation: huks.HuksOptions = { properties: this.generationParameters() };
      try { await huks.generateKeyItem(SecretVault.alias, generation); }
      catch (error) {
        if ((error as BusinessError).code !== 12000017 ||
            !await this.hasKey()) throw this.unavailable();
      }
    } catch (error) {
      if (error instanceof SecretStorageError) throw error;
      throw this.unavailable();
    }
  }

  private async hasKey(): Promise<boolean> {
    const options: huks.HuksOptions = { properties: [
      { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_CE }
    ] };
    try { return await huks.isKeyItemExist(SecretVault.alias, options); }
    catch (error) {
      // The public Promise API reports an absent alias by rejection, not only false.
      if ((error as BusinessError).code === 12000011) return false;
      throw error as Error;
    }
  }

  private parameters(encrypt: boolean, nonce: Uint8Array, tag?: Uint8Array): huks.HuksParam[] {
    const parameters: huks.HuksParam[] = [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: encrypt ?
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT : huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_CE },
      { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce },
      { tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: this.aad() }
    ];
    if (tag) parameters.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag });
    return parameters;
  }

  private join(parts: Uint8Array[]): Uint8Array {
    let size = 0;
    for (const part of parts) size += part.byteLength;
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) { bytes.set(part, offset); offset += part.byteLength; }
    return bytes;
  }

  private async crypt(encrypt: boolean, input: Uint8Array, nonce: Uint8Array,
    current: () => void, tag?: Uint8Array): Promise<Uint8Array> {
    const parameters = this.parameters(encrypt, nonce, tag);
    let handle: number | undefined;
    let finished = false;
    try {
      current();
      const initial: huks.HuksOptions = { properties: parameters };
      handle = (await huks.initSession(SecretVault.alias, initial)).handle;
      const parts: Uint8Array[] = [];
      let offset = 0;
      while (input.byteLength - offset > SecretVault.chunkSize) {
        current();
        const update: huks.HuksOptions = {
          properties: parameters, inData: input.slice(offset, offset + SecretVault.chunkSize)
        };
        const result = await huks.updateSession(handle, update);
        if (result.outData) parts.push(result.outData);
        offset += SecretVault.chunkSize;
      }
      current();
      const final: huks.HuksOptions = { properties: parameters, inData: input.slice(offset) };
      const result = await huks.finishSession(handle, final);
      finished = true;
      if (result.outData) parts.push(result.outData);
      current();
      // In particular, no partial decryption is exposed before GCM authentication succeeds.
      return this.join(parts);
    } catch (error) {
      if (error instanceof SecretStorageError) throw error;
      if (encrypt) throw this.unavailable();
      throw this.unreadable();
    } finally {
      if (handle !== undefined && !finished) {
        const abort: huks.HuksOptions = { properties: [] };
        try { await huks.abortSession(handle, abort); } catch (_) {}
      }
    }
  }

  private async stat(path: string): Promise<fs.Stat | null> {
    try { return await fs.lstat(path); }
    catch (error) { if ((error as BusinessError).code === 13900002) return null; throw error as Error; }
  }

  private async directoryExists(): Promise<boolean> {
    const stat = await this.stat(this.directory);
    if (stat === null) return false;
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw this.unreadable();
    return true;
  }

  private async readBytes(): Promise<Uint8Array | null> {
    if (!await this.directoryExists()) return null;
    const stat = await this.stat(this.path);
    if (stat === null) return null;
    if (!stat.isFile() || stat.isSymbolicLink() || !Number.isSafeInteger(stat.size) || stat.size < 36) {
      throw this.unreadable();
    }
    const file = await fs.open(this.path, fs.OpenMode.READ_ONLY | fs.OpenMode.NOFOLLOW | fs.OpenMode.NONBLOCK);
    try {
      const actual = await fs.stat(file.fd);
      if (!actual.isFile() || actual.size !== stat.size) throw this.unreadable();
      const bytes = new Uint8Array(actual.size);
      const buffer = new ArrayBuffer(Math.min(SecretVault.chunkSize, actual.size));
      let offset = 0;
      while (offset < bytes.byteLength) {
        const requested = Math.min(buffer.byteLength, bytes.byteLength - offset);
        const count = await fs.read(file.fd, buffer, { offset: offset, length: requested });
        if (!Number.isSafeInteger(count) || count <= 0 || count > requested) throw this.unreadable();
        bytes.set(new Uint8Array(buffer, 0, count), offset);
        offset += count;
      }
      if ((await fs.stat(file.fd)).size !== actual.size) throw this.unreadable();
      return bytes;
    } finally { await fs.close(file); }
  }

  private async load(current: () => void): Promise<Map<string, string>> {
    current();
    const bytes = await this.readBytes();
    current();
    if (bytes === null) return new Map<string, string>();
    const header = this.header();
    for (let i = 0; i < header.byteLength; i++) if (bytes[i] !== header[i]) throw this.unreadable();
    await this.key(true);
    current();
    const nonce = bytes.slice(8, 20);
    const tag = bytes.slice(bytes.byteLength - 16);
    const plaintext = await this.crypt(false, bytes.slice(20, bytes.byteLength - 16), nonce, current, tag);
    if (plaintext.byteLength !== bytes.byteLength - 36) throw this.unreadable();
    try {
      const text = util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(plaintext);
      const records = JSON.parse(text) as SecretRecord[];
      if (!Array.isArray(records)) throw this.unreadable();
      const values = new Map<string, string>();
      for (const record of records) {
        if (record === null || typeof record.key !== 'string' || typeof record.value !== 'string' ||
            values.has(record.key)) throw this.unreadable();
        values.set(record.key, record.value);
      }
      return values;
    } catch (_) { throw this.unreadable(); }
  }

  private async save(values: Map<string, string>, current: () => void): Promise<void> {
    current();
    await this.key(false);
    const records: SecretRecord[] = [];
    values.forEach((value: string, key: string): void => { records.push(new SecretRecord(key, value)); });
    const plaintext = new util.TextEncoder().encodeInto(JSON.stringify(records));
    const nonce = (await cryptoFramework.createRandom().generateRandom(12)).data;
    if (nonce.byteLength !== 12) throw this.unavailable();
    const encrypted = await this.crypt(true, plaintext, nonce, current);
    if (encrypted.byteLength !== plaintext.byteLength + 16) throw this.unavailable();
    const bytes = this.join([this.header(), nonce, encrypted]);
    current();
    if (!await this.directoryExists()) {
      try { await fs.mkdir(this.directory); }
      catch (error) { if ((error as BusinessError).code !== 13900015) throw error as Error; }
      await this.directoryExists();
    }
    // Public fs has mkdtemp, not an invented EXCL flag. The staging directory is private and unique.
    const staging = await fs.mkdtemp(this.directory + '/write-XXXXXX');
    const temporary = staging + '/ciphertext';
    let published = false;
    try {
      current();
      const file = await fs.open(temporary, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.NOFOLLOW);
      try {
        let offset = 0;
        while (offset < bytes.byteLength) {
          current();
          const part = bytes.slice(offset, offset + SecretVault.chunkSize);
          const count = await fs.write(file.fd, part.buffer, { offset: offset });
          if (!Number.isSafeInteger(count) || count <= 0 || count > part.byteLength) {
            throw new SecretStorageError('secrets_io', '加密凭据未完整保存，请重试。');
          }
          offset += count;
        }
        await fs.fsync(file.fd);
      } finally { await fs.close(file); }
      current();
      await fs.rename(temporary, this.path);
      published = true;
      await this.syncDirectory();
    } finally {
      if (!published) { try { await fs.unlink(temporary); } catch (_) {} }
      try { await fs.rmdir(staging); } catch (_) {}
    }
  }

  // Only called after rename/unlink commits. Failure affects durability, not visibility.
  private async syncDirectory(): Promise<void> {
    try {
      const directory = await fs.open(this.directory, fs.OpenMode.READ_ONLY | fs.OpenMode.DIR | fs.OpenMode.NOFOLLOW);
      try { await fs.fsync(directory.fd); } finally { await fs.close(directory); }
    } catch (_) {
      if (!SecretVault.durabilityWarned) {
        SecretVault.durabilityWarned = true;
        hilog.warn(0, 'DshSecrets', 'Credential change committed; directory durability unavailable');
      }
    }
  }

  // Deliberately does not load/decrypt: the confirmed recovery must work on corrupt data.
  recover(current: () => void): Promise<void> {
    return this.queue(async (): Promise<void> => {
      current();
      if (await this.directoryExists()) {
        current();
        let removed = false;
        try { await fs.unlink(this.path); removed = true; }
        catch (error) { if ((error as BusinessError).code !== 13900002) throw error as Error; }
        if (removed) await this.syncDirectory();
      }
      // Clear ciphertext first: a failed unlink must not destroy its usable key.
      // Do not query key existence: an existing but unusable alias also needs deletion.
      current();
      const options: huks.HuksOptions = { properties: [
        { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_CE }
      ] };
      try { await huks.deleteKeyItem(SecretVault.alias, options); }
      catch (error) {
        if ((error as BusinessError).code !== 12000011) {
          throw new SecretStorageError('secrets_recovery_failed', '凭据恢复未完成，请重试以清理本应用的系统密钥。');
        }
      }
    });
  }

  read(key: string, current: () => void): Promise<string | null> {
    return this.queue(async (): Promise<string | null> => (await this.load(current)).get(key) ?? null);
  }

  readAll(current: () => void): Promise<Map<string, string>> {
    return this.queue(async (): Promise<Map<string, string>> => this.load(current));
  }

  write(key: string, value: string, current: () => void): Promise<void> {
    return this.queue(async (): Promise<void> => {
      const values = await this.load(current);
      values.set(key, value);
      await this.save(values, current);
    });
  }

  delete(key: string, current: () => void): Promise<void> {
    return this.queue(async (): Promise<void> => {
      const values = await this.load(current);
      if (!values.delete(key)) return;
      await this.save(values, current);
    });
  }
}
