// Test-only observation barrier. A failed real job must not leave a test
// waiting forever for output or a marker that can no longer be produced.
export async function beforeJobExit(job, observe, { label, stderr = () => '', signal } = {}) {
  const stop = new AbortController();
  const observationSignal = signal ? AbortSignal.any([signal, stop.signal]) : stop.signal;
  const ended = job.done.then(outcome => {
    const error = new Error(`${label} was not observed before Python ended: ${JSON.stringify(outcome)}\n${stderr()}`);
    error.code = 'ERR_OHOS_TEST_JOB_ENDED_EARLY'; error.outcome = outcome;
    throw error;
  });
  try { return await Promise.race([observe(observationSignal), ended]); }
  finally { stop.abort(); }
}
