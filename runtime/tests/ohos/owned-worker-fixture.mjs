import { parentPort, workerData } from 'node:worker_threads';
import { createOwnedGitClient } from '../../ohos/process/owned-client.mjs';
const client = createOwnedGitClient(parentPort);
parentPort.on('message', message => {
  if (message?.kind === 'exit-now') {
    parentPort.postMessage({ kind: 'outcome', exitCode: 0, ignoredPendingOperation: true });
    process.exit(0);
  }
});
try {
  if (workerData.operation === 'index') {
    const index = await client.api.createIndex({ target: workerData.target, content: Buffer.from('first') });
    parentPort.postMessage({ kind: 'index', value: index });
    if (workerData.hold) await new Promise(() => {});
    await client.api.writeIndex(index.id, Buffer.from('second'));
    await client.api.commitIndex(index.id);
  } else {
    await client.api.writeMetadata({ target: workerData.target, content: Buffer.from('complete metadata') });
  }
  parentPort.postMessage({ kind: 'outcome', exitCode: 0 });
} catch (error) {
  parentPort.postMessage({ kind: 'outcome', exitCode: workerData.catchAsSuccess ? 0 : 1,
    handledCode: error.code, committed: error.committed,
    causeCode: error.cause?.code });
} finally {
  client.close();
  parentPort.close();
}
