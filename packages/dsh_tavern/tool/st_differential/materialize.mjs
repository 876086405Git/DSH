import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const [output, fixtureArgument, ...extra] = process.argv.slice(2);
if (!output || extra.length) throw new Error('Usage: node materialize.mjs <new-output-directory> [fixtures.json]');
const fixtureFile = fixtureArgument ?? path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '../../test/fixtures/st-differential.json');
const fixtures = JSON.parse(await fs.readFile(fixtureFile, 'utf8'));
if (!Array.isArray(fixtures) || !fixtures.length) throw new Error('Expected nonempty fixtures.');
const ids = fixtures.map(fixture => fixture?.id);
if (new Set(ids).size !== ids.length || ids.some(id => typeof id !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,63}$/.test(id))) {
  throw new Error('Fixture ids must be unique safe leaf names.');
}
await fs.mkdir(output, { recursive: true });
for (const fixture of fixtures) {
  const directory = path.join(output, fixture.id);
  await fs.mkdir(directory, { recursive: true });
  const write = (name, value) => fs.writeFile(path.join(directory, name),
    typeof value === 'string' ? value : JSON.stringify(value, null, 2) + '\n', { flag: 'wx' });
  await write('card.json', fixture.card);
  await write('preset.json', fixture.preset);
  await write('chat.jsonl', [fixture.chatHeader, ...fixture.messages].map(value => JSON.stringify(value)).join('\n') + '\n');
  await write('settings.json', { settings: fixture.settings, globalVariables: fixture.globalVariables,
    generationType: fixture.generationType, bookBindings: fixture.books.map(book => ({ id: book.id, source: book.source })) });
  for (const book of fixture.books) {
    if (!/^[a-zA-Z0-9_-]+$/.test(book.id)) throw new Error(`Unsafe synthetic book id: ${book.id}`);
    await write(`${book.id}.json`, book.json);
  }
}
console.log(`MATERIALIZED ${fixtures.length} fixtures in ${path.resolve(output)}`);
