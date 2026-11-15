// The lifecycle owner is already installed by the product. Reading its class
// creates no binding probe, guest boot, or timer. This is not a config surface.
export function createCleanupBudget() {
  let clock;
  let closed = false;
  return Object.freeze({
    deadline(ms, reason) {
      if (closed) throw new Error('Guest cleanup budget owner is closed');
      if (!clock) {
        const source = globalThis[Symbol.for('dsh.go.ohos.lifecycle')]?.clock;
        if (!source || typeof source.bootId !== 'string' || typeof source.deadline !== 'function') {
          throw new Error('iOS lifecycle activity budget owner is unavailable');
        }
        // This is the trusted, iOS-generated ActiveBudgetClock class, with a
        // fresh never-paused instance: logical tool pause must not stall cleanup.
        clock = new source.constructor(source.bootId);
      }
      return clock.deadline(undefined, ms, reason);
    },
    dispose() { closed = true; clock?.dispose(); },
  });
}
