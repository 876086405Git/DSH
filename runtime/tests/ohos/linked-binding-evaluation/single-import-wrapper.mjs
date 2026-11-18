// Experiment only, copied to a path matching the host's layout contract.
// Its first sim step and final observer are instrumentation, never a product plan.
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
const runtime = process.env.DSH_M6_TEST_RUNTIME;
const fixtures = process.env.DSH_M6_TEST_FIXTURES;
await import(pathToFileURL(join(runtime, 'sim/preload.mjs')).href);
if (process.env.DSH_M6_TEST_REGISTER === 'modern') {
  // Candidate order: existing network -> own dynamic native bootstrap -> publication.
  await import(pathToFileURL(join(runtime, 'net/dsh-preload.mjs')).href);
  await import(pathToFileURL(join(fixtures, 'bootstrap.mjs')).href);
  await import(pathToFileURL(join(runtime, 'publication/preload.mjs')).href);
} else if (process.env.DSH_M6_TEST_REGISTER === 'missing') {
  // Same reviewed wrapper, after disabling static registration, must fail.
  await import(pathToFileURL(join(runtime, 'preload.mjs')).href);
} else {
  throw new Error('Unknown fixed registration experiment');
}
await import(pathToFileURL(join(fixtures, 'observe-wrapper.mjs')).href);
