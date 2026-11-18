// Expose private functions only in a temporary test module beside the installed provider.
// The original provider bytes are never changed by this test helper.
import { readFile, writeFile, unlink } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';

export async function loadInternals(packageName, exports) {
  const require = createRequire(join(resolve(process.env.DSH_TEST_PREFIX ?? process.cwd()), 'package.json'));
  const original = require.resolve(packageName);
  const path = join(dirname(original), `.ohos-test-${randomUUID()}.mjs`);
  await writeFile(path, `${await readFile(original, 'utf8')}\nexport { ${exports.join(', ')} };\n`, { flag: 'wx' });
  try {
    return await import(pathToFileURL(path));
  } finally {
    await unlink(path);
  }
}
