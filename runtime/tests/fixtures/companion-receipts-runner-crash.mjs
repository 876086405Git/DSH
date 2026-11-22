import {link} from 'node:fs/promises';
import {openReceipts} from './companion-receipts-runner-fixture.mjs';
const [root, scenario] = process.argv.slice(2);
let reads = 0;
const f = await openReceipts(root, {
  read: async (_args, actual) => {
    if (++reads === 5 && scenario === 'before-candidate') process.kill(process.pid, 'SIGKILL');
    return actual();
  },
  link: async (from, to) => {
    if (scenario === 'after-link') { await link(from, to); process.kill(process.pid, 'SIGKILL'); }
    if (scenario === 'before-link') process.kill(process.pid, 'SIGKILL');
    return link(from, to);
  },
});
if (scenario === 'saved-intent') {
  const save = f.store.savePublishIntent.bind(f.store);
  f.store.savePublishIntent = async (...args) => { await save(...args); process.kill(process.pid, 'SIGKILL'); };
}
if (scenario === 'after-write-claim') {
  const claim = f.store.claimStep.bind(f.store);
  f.store.claimStep = async (...args) => {
    const result = await claim(...args);
    if (args[2] === 'writeSheet') process.kill(process.pid, 'SIGKILL');
    return result;
  };
}
f.start();
await f.settled();
throw new Error('The child failed to reach its expected actual publication boundary');
