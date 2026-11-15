import { parentPort } from 'node:worker_threads';
import { borrowInstalledOwnership, installPublication } from '../../ohos/publication/index.mjs';
let code;
try { borrowInstalledOwnership(); } catch (error) { code = error.code; }
parentPort.postMessage({ borrowCode: code, install: await installPublication() });
