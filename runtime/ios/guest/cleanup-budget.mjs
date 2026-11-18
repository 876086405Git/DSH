import { ActiveBudgetClock } from '../../ohos/lifecycle/budget.mjs';

// iOS owns its cleanup budget independently of the OHOS lifecycle plugin.
// The specialized clock uses the native activity clock and never pauses for
// logical tool pauses, so a cancelled guest still has a bounded exit wait.
export function createCleanupBudget() {
  let clock;
  let closed = false;
  return Object.freeze({
    deadline(ms, reason) {
      if (closed) throw new Error('Guest cleanup budget owner is closed');
      if (!clock) {
        clock = new ActiveBudgetClock('ios-guest-cleanup');
      }
      return clock.deadline(undefined, ms, reason);
    },
    dispose() { closed = true; clock?.dispose(); },
  });
}
