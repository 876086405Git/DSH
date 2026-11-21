// Rule-only companion state. Reads project time; only accepted events persist an anchor.
// These constants are product defaults, not psychological measurements.
const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
export const EVENT_TYPES = ["visit", "pet", "snack", "play", "rest"];
export const EVENT_COOLDOWN_MS = 30_000;
const GAIN_INTERVAL_MS = 6 * HOUR;
const clamp = (value) => Math.max(0, Math.min(1, value));
const relax = (value, target, elapsed, halfLife) => target + (value - target) * 2 ** (-elapsed / halfLife);

export function initialState(now) {
  return {
    valence: 0.25, energy: 0.75, closeness: 0,
    activity: "idle", activityUntil: null,
    lastVisitAt: null, lastInteractionAt: null,
    anchorAt: now, lastGainAt: null,
    lastEvents: Object.fromEntries(EVENT_TYPES.map((type) => [type, null])),
  };
}

export function advanceState(state, now) {
  // Never move the saved anchor backwards: a clock correction must not accrue time twice.
  const at = Math.max(now, state.anchorAt);
  const elapsed = at - state.anchorAt;
  const next = {
    ...state,
    valence: relax(state.valence, 0.25, elapsed, 40 * MINUTE),
    energy: relax(state.energy, 0.75, elapsed, 2 * HOUR),
    anchorAt: at,
    lastEvents: { ...state.lastEvents },
  };
  if (next.activityUntil !== null && at >= next.activityUntil) {
    next.activity = "idle";
    next.activityUntil = null;
  }
  return next;
}

export function publicState(state, now) {
  const current = advanceState(state, now);
  let thought = "enjoy-company";
  if (current.activity === "snack") thought = "enjoy-snack";
  else if (current.activity === "play") thought = "enjoy-play";
  else if (current.activity === "rest") thought = "rest";
  else if (current.energy < 0.4) thought = "take-it-easy";
  return {
    valence: current.valence, energy: current.energy, closeness: current.closeness,
    activity: current.activity, activityUntil: current.activityUntil,
    lastVisitAt: current.lastVisitAt, lastInteractionAt: current.lastInteractionAt,
    thought,
  };
}

export function applyEvent(state, type, now) {
  const next = advanceState(state, now);
  const at = next.anchorAt;
  const previous = next.lastEvents[type];
  if (previous !== null && at - previous < EVENT_COOLDOWN_MS) return null;
  next.lastEvents[type] = at;
  if (type === "visit") next.lastVisitAt = at;
  else next.lastInteractionAt = at;
  if (type === "visit") next.valence += 0.04;
  if (type === "pet") next.valence += 0.06;
  if (type === "snack") {
    next.valence += 0.05;
    next.energy += 0.03;
    next.activity = "snack";
    next.activityUntil = at + 45_000;
  }
  if (type === "play") {
    next.valence += 0.08;
    next.energy -= 0.04;
    next.activity = "play";
    next.activityUntil = at + 90_000;
  }
  if (type === "rest") {
    next.activity = "rest";
    next.activityUntil = at + 15 * MINUTE;
  }
  if (type !== "rest" && (next.lastGainAt === null || at - next.lastGainAt >= GAIN_INTERVAL_MS)) {
    next.closeness = clamp(next.closeness + 0.01);
    next.lastGainAt = at;
  }
  next.valence = clamp(next.valence);
  next.energy = clamp(next.energy);
  return next;
}
