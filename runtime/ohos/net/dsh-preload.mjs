import { isMainThread } from 'node:worker_threads';
import { bootstrapDshNetwork } from './bootstrap.mjs';
import { installFetch } from './fetch.mjs';

// Workers inherit --import, but argv[1] names their worker module, not the DSH CLI.
if (isMainThread) bootstrapDshNetwork(process.argv[1]);
else installFetch();
