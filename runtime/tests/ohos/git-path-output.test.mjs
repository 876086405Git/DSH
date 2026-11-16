import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fixture } from './git-owned-fixture.mjs';

// Native Git recorded byte outputs, independent of the OH formatting helper.
const oracle = JSON.parse(await readFile(new URL('./git-path-output-oracle.json', import.meta.url), 'utf8'));
for (const sample of oracle.cases) {
  test(`Git path fields preserve native quoting and NUL bytes: core.quotePath=${JSON.stringify(sample.quotePath)}`, async t => {
    const f = await fixture(t);
    await f.run(['init']);
    for (const name of oracle.names) await writeFile(join(f.dir, name), 'content\n');
    await f.run(['add', '--all']);
    if (sample.quotePath === '-1') {
      // The existing OH setter rejects dash-prefixed values. A repository may
      // nevertheless already contain Git's valid signed boolean integer.
      const config = join(f.dir, '.git/config');
      await writeFile(config, await readFile(config, 'utf8') + '\n[core]\n\tquotePath = -1\n');
    } else if (sample.quotePath !== null) await f.run(['config', 'core.quotePath', sample.quotePath]);
    for (const expected of sample.results) {
      const actual = await f.run(expected.args);
      assert.equal(actual.exitCode, expected.exitCode, expected.args.join(' '));
      assert.equal(actual.stderr, expected.stderr, expected.args.join(' '));
      assert.deepEqual(Buffer.from(actual.stdout), Buffer.from(expected.stdout), expected.args.join(' '));
    }
  });
}

// Native patch path headers, not hunk/index formatting, define this comparison.
const patchOracle = JSON.parse(await readFile(new URL('./git-patch-output-oracle.json', import.meta.url), 'utf8'));
for (const sample of patchOracle.cases) for (const cached of [false, true]) {
  test(`Git text patch path: ${JSON.stringify(sample.name)} cached=${cached} quotePath=${sample.quotePath}`, async t => {
    const f = await fixture(t);
    await f.run(['init']);
    await writeFile(join(f.dir, sample.name), patchOracle.old);
    await f.run(['add', '--all']); await f.run(['commit', '-m', 'base']);
    if (sample.quotePath !== null) await f.run(['config', 'core.quotePath', sample.quotePath]);
    await writeFile(join(f.dir, sample.name), patchOracle.new);
    if (cached) await f.run(['add', '--all']);
    const result = await f.run(['diff', ...(cached ? ['--cached'] : []), '--', sample.name]);
    const headers = result.stdout.split('\n').filter(line => /^(diff --git |--- |\+\+\+ )/.test(line));
    assert.equal(headers.length, 3);
    for (let index = 0; index < headers.length; index++) {
      // jsdiff permits an empty tab-delimited timestamp after a file header.
      assert(headers[index] === sample.headers[index] || (index > 0 && headers[index] === sample.headers[index] + '\t'),
        JSON.stringify({ actual: headers[index], expected: sample.headers[index] }));
    }
  });
}
