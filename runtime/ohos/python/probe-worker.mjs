import { parentPort, workerData } from 'node:worker_threads';
import { createRequire } from 'node:module';
const native = createRequire(import.meta.url)(workerData.addon);
parentPort.on('message', ({ source, args }) => {
  try {
    // JSON is decoded as data, never interpolated as Python syntax.
    const prefix = `import sys,json\nsys.argv=json.loads(${JSON.stringify(JSON.stringify(args))})\n`;
    parentPort.postMessage(JSON.parse(native.run(prefix + source, 30000, (stream, chunk) => parentPort.postMessage({ stream, chunk }))));
  } catch (error) { parentPort.postMessage({ error: error.message }); }
});
