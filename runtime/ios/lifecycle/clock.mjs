import { performance } from 'node:perf_hooks';

// Older native hosts have no activity binding. Keep their original clock.
let read;
try {
  const binding = process._linkedBinding('dsh_ios_activity_clock');
  read = () => binding.now();
} catch {
  console.warn('[dsh-ios] Activity clock unavailable; using monotonic elapsed time.');
  read = () => performance.now();
}

export const activeNow = () => read();
