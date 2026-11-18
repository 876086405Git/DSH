// No engine start, arbitrary destination or content logging in this service.
import { ManagedSkillOwner, ManagedSkillScope, ManagedSkillGate, ManagedSkillQueue, ManagedSkillRequest } from './ManagedSkillCore';
import { OhosManagedSkillStorage } from './ManagedSkillInstaller';

export { ManagedSkillOwner, ManagedSkillScope } from './ManagedSkillCore';

export class ManagedSkillService {
  private readonly gate: ManagedSkillGate = new ManagedSkillGate();
  private readonly queue: ManagedSkillQueue;
  private readonly isCurrent: (scope: ManagedSkillScope) => boolean;

  constructor(guestRoot: string, current: (scope: ManagedSkillScope) => boolean) {
    this.isCurrent = current;
    this.queue = new ManagedSkillQueue(new OhosManagedSkillStorage(guestRoot),
      (action: () => Promise<void>) => { Promise.resolve().then(action); },
      (action: () => void) => { Promise.resolve().then(action); });
  }

  attachOwner(): ManagedSkillOwner {
    const owner = new ManagedSkillOwner();
    const previous = this.gate.attach(owner);
    if (previous !== null) this.queue.cancel(previous);
    return owner;
  }

  detachOwner(owner: ManagedSkillOwner): void { this.gate.detach(owner); this.queue.cancel(owner); }
  ready(runtimeGeneration: number, token: string): void { this.gate.ready(runtimeGeneration, token); }
  stop(runtimeGeneration: number): void { this.gate.stop(runtimeGeneration); }
  retire(): void { this.gate.retire(); }
  generationFor(token: string | null): number | null { return this.gate.generationFor(token); }
  cancel(owner: ManagedSkillOwner, requestId: string | null = null): void { this.queue.cancel(owner, requestId); }

  install(owner: ManagedSkillOwner, raw: Map<string, Object | null> | null,
    onDone: (reply: Map<string, Object | null>) => void): void {
    const request = ManagedSkillRequest.parse(raw);
    const scope = request === null ? null : this.gate.capture(owner, request.expectedToken, request.expectedGeneration);
    if (request === null || scope === null) {
      onDone(new Map<string, Object | null>([['result', null], ['current', false], ['reason', request === null ? 'invalid' : 'stale']]));
      return;
    }
    this.queue.submit(owner, request, () => this.gate.current(scope) && this.isCurrent(scope), onDone);
  }
}
