import childProcess from 'node:child_process';
import { syncBuiltinESMExports } from 'node:module';

// This product preload is an OHOS compatibility boundary, not an OS sandbox.
// Worker threads and the virtual runtime do not create OS child processes.
if (process.platform === 'openharmony') {
  const unavailable = () => {
    throw Object.assign(new Error('[ERR_OHOS_NO_SPAWN] OS child processes are unavailable on OpenHarmony; use the virtual runtime or a remote service.'),
      { code: 'ERR_OHOS_NO_SPAWN' });
  };
  for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) {
    childProcess[name] = unavailable;
  }
  childProcess.ChildProcess.prototype.spawn = unavailable;
  syncBuiltinESMExports();
}
