// Puts the round's result where it can be read without signing in to GitHub.
import { readFileSync } from 'node:fs';

const report = JSON.parse(readFileSync(process.argv[2] + '/report.json', 'utf8'));
const clean = (text) => String(text).replace(/%/g, '%25').replace(/\s+/g, ' ').slice(0, 800);
console.log('::notice title=engine round::' + clean(JSON.stringify({
  status: report.status, stage: report.stage, readyMs: report.readyMs,
  restart: report.restart, restartReadyMs: report.restartReadyMs, approvals: report.approvals,
  phoneEndpoint: report.phoneEndpoint, phoneTools: report.phoneTools,
  browserTools: report.browserTools, systemTools: report.systemTools, modelRequests: report.modelRequests,
  events: report.eventTypes?.slice(-8),
})));
if (report.status !== 'PASS') {
  console.log('::error title=engine round::' + clean(report.error));
  // One annotation holds it all: a step shows ten at most.
  const tail = (report.nativeHost ?? []).join(' | ').replace(/%/g, '%25').replace(/\s+/g, ' ');
  console.log('::error title=engine log::' + tail.slice(-20000));
}
