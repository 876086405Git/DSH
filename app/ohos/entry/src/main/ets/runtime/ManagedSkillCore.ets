// Pure admission/queue/transaction logic. No launcher and no platform globals.
export class ManagedSkillOwner {
  private alive: boolean = true;
  get attached(): boolean { return this.alive; }
  detach(): void { this.alive = false; }
}

export class ManagedSkillScope {
  readonly owner: ManagedSkillOwner;
  readonly runtimeGeneration: number;
  readonly token: string;
  readonly generation: number;
  constructor(owner: ManagedSkillOwner, runtimeGeneration: number, token: string, generation: number) {
    this.owner = owner; this.runtimeGeneration = runtimeGeneration; this.token = token; this.generation = generation;
  }
}

export class ManagedSkillGate {
  private owner: ManagedSkillOwner | null = null;
  private active: ManagedSkillScope | null = null;
  private confirmedGeneration: number | null = null;
  private confirmedToken: string | null = null;
  private stoppedGeneration: number = -1;
  private latestRuntimeGeneration: number = -1;
  private serial: number = 0;

  attach(owner: ManagedSkillOwner): ManagedSkillOwner | null {
    const previous = this.owner;
    previous?.detach(); this.owner = owner; this.active = null;
    this.grantReady();
    return previous;
  }

  detach(owner: ManagedSkillOwner): void {
    owner.detach();
    if (this.owner === owner) { this.owner = null; this.active = null; }
  }

  ready(generation: number, token: string): void {
    if (!Number.isSafeInteger(generation) || generation < 0 || token.length === 0 ||
        generation <= this.stoppedGeneration || generation < this.latestRuntimeGeneration) return;
    this.latestRuntimeGeneration = generation;
    this.confirmedGeneration = generation; this.confirmedToken = token;
    this.grantReady();
  }

  private grantReady(): void {
    const owner = this.owner;
    if (owner === null || !owner.attached || this.confirmedGeneration === null || this.confirmedToken === null) return;
    const previous = this.active;
    if (previous !== null && previous.owner === owner && previous.runtimeGeneration === this.confirmedGeneration &&
        previous.token === this.confirmedToken) return;
    this.active = null;
    if (this.serial === Number.MAX_SAFE_INTEGER) return;
    this.active = new ManagedSkillScope(owner, this.confirmedGeneration, this.confirmedToken, ++this.serial);
  }

  stop(generation: number): void {
    if (Number.isSafeInteger(generation)) this.stoppedGeneration = Math.max(this.stoppedGeneration, generation);
    this.retire();
  }

  retire(): void { this.confirmedGeneration = null; this.confirmedToken = null; this.active = null; }

  generationFor(token: string | null): number | null {
    const active = this.active;
    return active !== null && active.owner.attached && active.token === token ? active.generation : null;
  }

  capture(owner: ManagedSkillOwner, token: string, generation: number): ManagedSkillScope | null {
    const active = this.active;
    return active !== null && active.owner === owner && owner.attached && active.token === token &&
      active.generation === generation ? active : null;
  }

  current(scope: ManagedSkillScope): boolean { return this.active === scope && scope.owner.attached; }
}

export class ManagedSkillRequest {
  static readonly MAX_FILES: number = 64;
  static readonly MAX_FILE_BYTES: number = 512 * 1024;
  static readonly MAX_BYTES: number = 1024 * 1024;
  readonly id: string;
  readonly expectedRoot: string;
  readonly expectedToken: string;
  readonly expectedGeneration: number;
  readonly name: string;
  readonly files: Map<string, string>;

  private constructor(id: string, root: string, token: string, generation: number,
    name: string, files: Map<string, string>) {
    this.id = id; this.expectedRoot = root; this.expectedToken = token; this.expectedGeneration = generation;
    this.name = name; this.files = files;
  }

  static parse(raw: Map<string, Object | null> | null): ManagedSkillRequest | null {
    if (!(raw instanceof Map)) return null;
    const id = raw.get('requestId'); const root = raw.get('expectedRoot'); const token = raw.get('expectedToken');
    const generation = raw.get('expectedGeneration'); const name = raw.get('name'); const files = raw.get('files');
    if (typeof id !== 'string' || id.length === 0 || id.length > 200 ||
        typeof root !== 'string' || root.length === 0 || root.length > 4096 ||
        typeof token !== 'string' || token.length === 0 || token.length > 4096 ||
        typeof generation !== 'number' || !Number.isSafeInteger(generation) || generation < 1 ||
        typeof name !== 'string' || !['dsh-go-ui', 'dsh-go-plugin', 'dsh-go-guide', 'dsh-go-support'].includes(name) ||
        !(files instanceof Map) || files.size < 1 || files.size > ManagedSkillRequest.MAX_FILES) return null;
    const checked = new Map<string, string>();
    let units = 0;
    let invalid = false;
    files.forEach((value: Object | null, key: Object) => {
      if (invalid) return;
      if (typeof key !== 'string' || key.length > 512 ||
          !/^[A-Za-z0-9_-][A-Za-z0-9._-]*(\/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$/.test(key) ||
          typeof value !== 'string' || value.length > ManagedSkillRequest.MAX_FILE_BYTES) {
        invalid = true; return;
      }
      units += value.length;
      if (units > ManagedSkillRequest.MAX_BYTES) { invalid = true; return; }
      checked.set(key, value);
    });
    if (invalid || !checked.has('SKILL.md')) return null;
    return new ManagedSkillRequest(id, root, token, generation, name, checked);
  }
}

export class ManagedSkillOutcome {
  readonly result: string | null;
  readonly reason: string | null;
  constructor(result: string | null = null, reason: string | null = null) {
    this.result = result; this.reason = reason;
  }
}

export class ManagedSkillRetired extends Error {
  constructor() { super('Managed skill permission retired'); }
}

export function requireManagedSkillCurrent(current: () => boolean): void {
  if (!current()) throw new ManagedSkillRetired();
}

export function validManagedSkillUtf16(text: string): boolean {
  for (let index = 0; index < text.length; index++) {
    const unit = text.charCodeAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (++index >= text.length) return false;
      const next = text.charCodeAt(index);
      if (next < 0xDC00 || next > 0xDFFF) return false;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) return false;
  }
  return true;
}

export function managedSkillText(text: string): boolean {
  const front = /^---\r?\n([\s\S]*?)\r?\n---/.exec(text);
  return front !== null && front[1].split(/\r?\n/).some((line: string) => line.trimStart().startsWith('# dsh-go:managed'));
}

export interface ManagedSkillStorage {
  root(): Promise<string>;
  canonical(path: string): Promise<string>;
  isDirectory(path: string): Promise<boolean>;
  permits(directory: string, paths: string[]): Promise<boolean>;
  exists(path: string): Promise<boolean>;
  encode(text: string): Uint8Array;
  readText(path: string, limit: number): Promise<string | null>;
  writeFile(path: string, bytes: Uint8Array, current: () => boolean): Promise<void>;
}

class ManagedSkillBytes {
  readonly path: string;
  readonly text: string;
  readonly bytes: Uint8Array;
  constructor(path: string, text: string, bytes: Uint8Array) { this.path = path; this.text = text; this.bytes = bytes; }
}

export async function installManagedSkill(storage: ManagedSkillStorage, request: ManagedSkillRequest,
  current: () => boolean): Promise<ManagedSkillOutcome> {
  try {
    requireManagedSkillCurrent(current);
    const root = await storage.root();
    if (await storage.canonical(request.expectedRoot) !== root) return new ManagedSkillOutcome(null, 'stale');
    const bytes: ManagedSkillBytes[] = [];
    let total = 0;
    let tooLarge = false;
    request.files.forEach((text: string, path: string) => {
      if (tooLarge) return;
      // OH TextEncoder replaces malformed UTF-16; Kotlin's encoder rejects it.
      if (!validManagedSkillUtf16(text)) throw new Error('Invalid UTF-16');
      const data = storage.encode(text);
      total += data.byteLength;
      if (data.byteLength > ManagedSkillRequest.MAX_FILE_BYTES || total > ManagedSkillRequest.MAX_BYTES) tooLarge = true;
      bytes.push(new ManagedSkillBytes(path, text, data));
    });
    if (tooLarge || !managedSkillText(request.files.get('SKILL.md') as string)) return new ManagedSkillOutcome(null, 'invalid');
    requireManagedSkillCurrent(current);
    const home = root + '/root/.dsh';
    if (!await storage.isDirectory(home)) return new ManagedSkillOutcome('noHome');
    const directory = home + '/skills/' + request.name;
    if (!await storage.permits(directory, bytes.map((file: ManagedSkillBytes) => file.path))) {
      return new ManagedSkillOutcome('userOwned');
    }
    const skill = directory + '/SKILL.md';
    const existed = await storage.exists(skill);
    if (existed) {
      const previous = await storage.readText(skill, ManagedSkillRequest.MAX_FILE_BYTES);
      if (previous === null || !managedSkillText(previous)) return new ManagedSkillOutcome('userOwned');
    }
    const order = bytes.filter((file: ManagedSkillBytes) => file.path !== 'SKILL.md')
      .concat(bytes.filter((file: ManagedSkillBytes) => file.path === 'SKILL.md'));
    let changed = false;
    for (const file of order) {
      requireManagedSkillCurrent(current);
      const path = directory + '/' + file.path;
      if (await storage.readText(path, file.bytes.byteLength + 3) === file.text) continue;
      requireManagedSkillCurrent(current);
      await storage.writeFile(path, file.bytes, current);
      changed = true;
    }
    return new ManagedSkillOutcome(!existed ? 'installed' : changed ? 'updated' : 'unchanged');
  } catch (error) {
    return new ManagedSkillOutcome(null, error instanceof ManagedSkillRetired ? 'cancelled' : 'io');
  }
}

type ManagedSkillCallback = (reply: Map<string, Object | null>) => void;
type ManagedSkillExecute = (action: () => Promise<void>) => void;
type ManagedSkillDeliver = (action: () => void) => void;

class ManagedSkillPermission {
  readonly owner: ManagedSkillOwner;
  readonly scopeCurrent: () => boolean;
  cancelled: boolean = false;
  constructor(owner: ManagedSkillOwner, scopeCurrent: () => boolean) { this.owner = owner; this.scopeCurrent = scopeCurrent; }
  current(): boolean { return !this.cancelled && this.owner.attached && this.scopeCurrent(); }
}

class ManagedSkillJob {
  readonly owner: ManagedSkillOwner;
  readonly request: ManagedSkillRequest;
  readonly permission: ManagedSkillPermission;
  readonly callback: ManagedSkillCallback;
  responded: boolean = false;
  constructor(owner: ManagedSkillOwner, request: ManagedSkillRequest, current: () => boolean, callback: ManagedSkillCallback) {
    this.owner = owner; this.request = request; this.permission = new ManagedSkillPermission(owner, current); this.callback = callback;
  }
}

export class ManagedSkillQueue {
  private active: ManagedSkillJob | null = null;
  private pending: ManagedSkillJob | null = null;
  private readonly storage: ManagedSkillStorage;
  private readonly execute: ManagedSkillExecute;
  private readonly deliver: ManagedSkillDeliver;

  constructor(storage: ManagedSkillStorage, execute: ManagedSkillExecute, deliver: ManagedSkillDeliver) {
    this.storage = storage; this.execute = execute; this.deliver = deliver;
  }

  submit(owner: ManagedSkillOwner, request: ManagedSkillRequest, current: () => boolean, callback: ManagedSkillCallback): void {
    const job = new ManagedSkillJob(owner, request, current, callback);
    if (!job.permission.current()) { this.respond(job, new ManagedSkillOutcome(null, 'stale')); return; }
    if ((this.active !== null && this.active.owner === owner && this.active.request.id === request.id) ||
        (this.pending !== null && this.pending.owner === owner && this.pending.request.id === request.id)) {
      this.respond(job, new ManagedSkillOutcome(null, 'duplicate')); return;
    }
    if (this.active === null) {
      this.active = job; this.schedule(job);
    } else {
      const replaced = this.pending; this.pending = job;
      if (replaced !== null) {
        replaced.permission.cancelled = true;
        this.respond(replaced, new ManagedSkillOutcome(null, 'cancelled'));
      }
    }
  }

  cancel(owner: ManagedSkillOwner, requestId: string | null = null): void {
    const active = this.active; const pending = this.pending;
    if (active !== null && active.owner === owner && (requestId === null || active.request.id === requestId)) {
      active.permission.cancelled = true;
      this.respond(active, new ManagedSkillOutcome(null, 'cancelled'));
    }
    if (pending !== null && pending.owner === owner && (requestId === null || pending.request.id === requestId)) {
      pending.permission.cancelled = true; this.pending = null;
      this.respond(pending, new ManagedSkillOutcome(null, 'cancelled'));
    }
  }

  private schedule(job: ManagedSkillJob): void {
    this.execute(async () => {
      try { this.respond(job, await installManagedSkill(this.storage, job.request, () => job.permission.current())); }
      finally {
        if (this.active === job) {
          this.active = this.pending; this.pending = null;
          if (this.active !== null) this.schedule(this.active);
        }
      }
    });
  }

  private respond(job: ManagedSkillJob, outcome: ManagedSkillOutcome): void {
    if (job.responded) return;
    job.responded = true;
    // The deferred callback retains permission and result, not a replaced bundle.
    const permission = job.permission; const callback = job.callback;
    this.deliver(() => {
      const current = permission.current() && outcome.reason !== 'stale' && outcome.reason !== 'cancelled';
      callback(new Map<string, Object | null>([
        ['result', outcome.result], ['current', current], ['reason', current ? outcome.reason : 'stale']
      ]));
    });
  }
}
