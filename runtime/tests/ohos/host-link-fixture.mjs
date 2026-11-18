// Test inputs only: the external Python actor creates entries in its fresh
// workspace. The strict Node process never regains a link creation capability.
import { symlink, writeFile, rename, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';

export async function symlinkFixture(source, destination, type) {
  const requests = process.env.OHOS_TEST_LINK_REQUESTS, responses = process.env.OHOS_TEST_LINK_RESPONSES;
  if (!requests || !responses) return symlink(source, destination, type);
  const name = `${process.pid}-${randomUUID()}.json`, pending = name + '.pending';
  await writeFile(join(requests, pending), JSON.stringify({ operation: 'symlink', source, destination }), { flag: 'wx' });
  await rename(join(requests, pending), join(requests, name));
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    let answer;
    try { answer = JSON.parse(await readFile(join(responses, name), 'utf8')); }
    catch (error) {
      if (error.code !== 'ENOENT') throw error;
      await delay(5); continue;
    }
    await rm(join(responses, name));
    if (!answer.ok) throw Object.assign(new Error(answer.message), { code: answer.code });
    return;
  }
  throw new Error('host symlink fixture handshake timed out');
}
