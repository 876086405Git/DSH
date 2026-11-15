// 未经 HarmonyOS SDK 编译、未在真机核实；本文件的纯逻辑另由 Linux 测试执行。
export class RuntimeChannelError extends Error {
  code: string;

  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

export interface RuntimeFile {
  path: string;
  size: number;
  sha256: string;
}

export interface RuntimeManifest {
  schema: number;
  runtimeVersion: string;
  dshVersion: string;
  nodeVersion: string;
  files: RuntimeFile[];
}

function validPayloadPath(path: string): boolean {
  return typeof path === 'string' && path.length > 0 && !path.includes('\\') && !path.includes('\0') &&
    !path.split('/').some((part: string) => part === '' || part === '.' || part === '..') && !/(?:\.node|\.so(?:\.\d+)*)$/i.test(path);
}

export function validateManifest(manifest: RuntimeManifest): RuntimeManifest {
  if (manifest.schema !== 1 || typeof manifest.runtimeVersion !== 'string' ||
      manifest.runtimeVersion.length === 0 || typeof manifest.dshVersion !== 'string' ||
      manifest.nodeVersion !== '24.22.1' || !Array.isArray(manifest.files) || manifest.files.length === 0) {
    throw new RuntimeChannelError('ohos_manifest_invalid', '运行时清单的版本或文件列表无效。');
  }
  const paths = new Set<string>();
  for (const file of manifest.files) {
    if (!validPayloadPath(file.path) || !Number.isSafeInteger(file.size) || file.size < 0 ||
        typeof file.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(file.sha256) || paths.has(file.path)) {
      throw new RuntimeChannelError('ohos_manifest_invalid', '运行时清单含无效路径、原生文件或校验字段。');
    }
    paths.add(file.path);
  }
  for (const path of paths) {
    let parent = path;
    while (parent.includes('/')) {
      parent = parent.substring(0, parent.lastIndexOf('/'));
      if (paths.has(parent)) throw new RuntimeChannelError('ohos_manifest_invalid', '运行时清单的文件与目录路径冲突。');
    }
  }
  for (const entry of ['node_modules/@deepseek-ai/dsh/lib/bin.js', 'runtime/ohos/preload.mjs',
    'runtime/ohos/process/index.mjs', 'runtime/ohos/process/sandbox.mjs',
    'runtime/ohos/lifecycle/index.mjs', 'runtime/ohos/capabilities/index.mjs',
    'runtime/bridge/dsh-go-bridge/lib/index.js', 'runtime/ohos/process/child-process.mjs']) {
    if (!paths.has(entry)) throw new RuntimeChannelError('ohos_manifest_invalid', '运行时缺少固定启动入口。');
  }
  return manifest;
}

export function validateEnvironment(env: Map<string, Object> | null): Record<string, string> {
  const result: Record<string, string> = {};
  if (env === null) return result;
  const reserved = ['NODE_OPTIONS', 'NODE_PATH', 'LD_PRELOAD', 'LD_LIBRARY_PATH', 'DSH_HOME', 'DSH_AGENTS_HOME',
    'NODE_COMPILE_CACHE', 'HOME', 'TMPDIR'];
  env.forEach((value: Object, key: string) => {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key) || typeof value !== 'string' || value.includes('\0') ||
        reserved.includes(key) || key.startsWith('DSH_GO_OHOS_')) {
      throw new RuntimeChannelError('ohos_invalid_env', '环境变量无效或试图覆盖鸿蒙宿主的固定配置。');
    }
    result[key] = value as string;
  });
  return result;
}

export function validateStartOptions(phoneStorage: boolean, mode: string | null): void {
  if (phoneStorage) throw new RuntimeChannelError('ohos_unsupported', '鸿蒙不提供 /sdcard 全盘挂载，请用系统文件选择器导入或导出。');
  if (mode !== null && mode !== 'normal') {
    throw new RuntimeChannelError('ohos_unsupported', '本版本鸿蒙宿主不支持安全模式，请关闭并重新打开 App，或使用已连接的电脑。');
  }
}

// Both values come from this application's public Context, never the channel env.
export function resolveNativeLibraryDir(bundleCodeDir: string, nativeLibraryPath: string): string {
  const root = bundleCodeDir.replace(/\/+$/, '');
  const relative = nativeLibraryPath.endsWith('/') ? nativeLibraryPath.slice(0, -1) : nativeLibraryPath;
  if (!root.startsWith('/') || root === '' || root.includes('\0') || relative.includes('\0') ||
      relative.split('/').some((part: string) => part === '' || part === '.' || part === '..')) {
    throw new RuntimeChannelError('ohos_native_library_path', '系统原生库目录无效，请检查 HAP 的解压与库隔离配置。');
  }
  return root + '/' + relative;
}

export class RuntimeLogEntry {
  seq: number;
  line: string;
  stream: string;

  constructor(seq: number, line: string, stream: string) {
    this.seq = seq;
    this.line = line;
    this.stream = stream;
  }

  toMap(): Map<string, Object | null> {
    return new Map<string, Object | null>([['seq', this.seq], ['line', this.line], ['stream', this.stream]]);
  }
}

export class RuntimeLogSnapshot {
  entries: RuntimeLogEntry[];
  throughSeq: number;

  constructor(entries: RuntimeLogEntry[], throughSeq: number) {
    this.entries = entries;
    this.throughSeq = throughSeq;
  }

  toMap(): Map<string, Object | null> {
    return new Map<string, Object | null>([
      ['entries', this.entries.map((entry: RuntimeLogEntry) => entry.toMap())], ['throughSeq', this.throughSeq]
    ]);
  }
}

export class RuntimeLogs {
  private sequence: number = 0;
  private entries: RuntimeLogEntry[] = [];
  private secrets: string[] = [];

  rememberSecret(value: string): void {
    if (value.length > 0 && !this.secrets.includes(value)) this.secrets.push(value);
  }

  append(line: string, stream: string): RuntimeLogEntry {
    let safe = line.replace(/([?&](?:token|key|api_key)=)[^\s&#]+/gi, '$1[REDACTED]')
      .replace(/(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;]+/gi, '$1[REDACTED]')
      .replace(/((?:api[_-]?key|access[_-]?token|refresh[_-]?token)\s*[:=]\s*)[^\s,;]+/gi, '$1[REDACTED]');
    for (const secret of this.secrets) safe = safe.split(secret).join('[REDACTED]');
    if (safe.length > 8192) safe = safe.substring(0, 8192) + ' [日志行已截断]';
    const entry = new RuntimeLogEntry(++this.sequence, safe, stream);
    this.entries.push(entry);
    if (this.entries.length > 2000) this.entries.shift();
    return entry;
  }

  snapshot(lines: number): RuntimeLogSnapshot {
    const count = Number.isFinite(lines) ? Math.max(0, Math.min(2000, Math.trunc(lines))) : 0;
    return new RuntimeLogSnapshot(count === 0 ? [] : this.entries.slice(-count), this.sequence);
  }
}

export interface RuntimeStorage {
  exists(path: string): Promise<boolean>;
  readText(path: string): Promise<string>;
  writeTextAtomic(path: string, content: string): Promise<void>;
  ensureDirectory(path: string): Promise<void>;
  matches(path: string, file: RuntimeFile): Promise<boolean>;
  copyRawFile(asset: string, target: string, file: RuntimeFile): Promise<void>;
  rename(from: string, to: string): Promise<void>;
  removeFile(path: string, keepDirectory?: boolean): Promise<void>;
  removeEmptyParents(path: string, boundary: string): Promise<void>;
}

export interface InstallProgress {
  step: string;
  done: number;
  total: number;
}

interface InstallJournal {
  schema: number;
  runtimeVersion: string;
  ownedPaths: string[];
  stagingHashes: string[];
}

export class RuntimeInstaller {
  private storage: RuntimeStorage;
  readonly base: string;
  readonly root: string;
  private installing: boolean = false;

  constructor(storage: RuntimeStorage, base: string) {
    this.storage = storage;
    this.base = base;
    this.root = base + '/tree';
  }

  async installed(): Promise<RuntimeManifest | null> {
    if (await this.storage.exists(this.base + '/installing.json')) return null;
    if (!await this.storage.exists(this.base + '/installed.json')) return null;
    return validateManifest(JSON.parse(await this.storage.readText(this.base + '/installed.json')) as RuntimeManifest);
  }

  async install(manifest: RuntimeManifest, progress: (event: InstallProgress) => void): Promise<void> {
    if (this.installing) throw new RuntimeChannelError('install_busy', '运行时正在安装。');
    validateManifest(manifest);
    this.installing = true;
    try {
      await this.storage.ensureDirectory(this.base);
      await this.storage.ensureDirectory(this.root);
      await this.storage.ensureDirectory(this.base + '/staging');
      let previous: RuntimeManifest | null = null;
      if (await this.storage.exists(this.base + '/installed.json')) {
        previous = validateManifest(JSON.parse(await this.storage.readText(this.base + '/installed.json')) as RuntimeManifest);
      }
      const owned = new Set<string>(previous === null ? [] : previous.files.map((file: RuntimeFile) => file.path));
      const staged = new Set<string>();
      if (await this.storage.exists(this.base + '/installing.json')) {
        const journal = JSON.parse(await this.storage.readText(this.base + '/installing.json')) as InstallJournal;
        if (journal.schema !== 1 || !Array.isArray(journal.ownedPaths) || !Array.isArray(journal.stagingHashes) ||
            !journal.ownedPaths.every((path: string) => validPayloadPath(path)) ||
            !journal.stagingHashes.every((hash: string) => typeof hash === 'string' && /^[a-f0-9]{64}$/.test(hash))) {
          throw new RuntimeChannelError('ohos_install_journal_invalid', '安装归属记录损坏，未按猜测的路径删除文件。');
        }
        journal.ownedPaths.forEach((path: string) => owned.add(path));
        journal.stagingHashes.forEach((hash: string) => staged.add(hash));
      }
      manifest.files.forEach((file: RuntimeFile) => { owned.add(file.path); staged.add(file.sha256); });
      const journal: InstallJournal = {
        schema: 1, runtimeVersion: manifest.runtimeVersion,
        ownedPaths: Array.from(owned), stagingHashes: Array.from(staged)
      };
      await this.storage.writeTextAtomic(this.base + '/installing.json', JSON.stringify(journal));
      const current = new Set<string>(manifest.files.map((file: RuntimeFile) => file.path));
      const directories = new Set<string>();
      for (const file of manifest.files) {
        let parent = file.path;
        while (parent.includes('/')) {
          parent = parent.substring(0, parent.lastIndexOf('/'));
          directories.add(parent);
        }
      }
      for (const path of Array.from(owned).sort((a: string, b: string) => b.length - a.length)) {
        if (!current.has(path)) {
          await this.storage.removeFile(this.root + '/' + path, directories.has(path));
          await this.storage.removeEmptyParents(this.root + '/' + path, this.root);
        }
      }
      const changed: RuntimeFile[] = [];
      let checked = 0;
      for (const file of manifest.files) {
        if (!await this.storage.matches(this.root + '/' + file.path, file)) changed.push(file);
        progress({step: 'verify', done: ++checked, total: manifest.files.length});
      }
      let total = 0;
      for (const file of changed) total += file.size;
      let done = 0;
      progress({step: 'extract', done: done, total: total});
      for (const file of changed) {
        const target = this.root + '/' + file.path;
        const staging = this.base + '/staging/' + file.sha256 + '.tmp';
        await this.storage.ensureDirectory(target.substring(0, target.lastIndexOf('/')));
        await this.storage.copyRawFile('dsh-runtime/files/' + file.path, staging, file);
        if (!await this.storage.matches(staging, file)) {
          throw new RuntimeChannelError('ohos_checksum_failed', '随包运行时文件校验失败，安装未提交。');
        }
        await this.storage.rename(staging, target);
        done += file.size;
        progress({step: 'extract', done: done, total: total});
      }
      progress({step: 'configure', done: 0, total: 1});
      for (const hash of staged) await this.storage.removeFile(this.base + '/staging/' + hash + '.tmp');
      await this.storage.writeTextAtomic(this.base + '/installed.json', JSON.stringify(manifest));
      await this.storage.removeFile(this.base + '/installing.json');
      progress({step: 'configure', done: 1, total: 1});
    } finally {
      this.installing = false;
    }
  }
}
