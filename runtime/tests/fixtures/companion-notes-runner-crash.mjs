import {link} from 'node:fs/promises';
import {openFixture, until} from './companion-notes-runner-fixture.mjs';
const [root, scenario] = process.argv.slice(2);
const f = await openFixture(root, {link: async (from, to) => {
  if (scenario === 'after-link') await link(from, to);
  else if (scenario !== 'before-link') throw new Error('unknown crash point');
  // The actual aggregate publicationAttempted commit has already completed.
  process.kill(process.pid, 'SIGKILL');
}});
if (scenario === 'saved-intent') {
  const save = f.store.savePublishIntent.bind(f.store);
  f.store.savePublishIntent = async (...args) => {
    await save(...args);
    process.kill(process.pid, 'SIGKILL'); // durable stage reference, before the attempted marker
  };
}
f.start();
await until(() => false, 'child must die at the actual publication boundary');
