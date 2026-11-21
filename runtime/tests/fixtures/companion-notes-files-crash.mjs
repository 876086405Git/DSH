import { readFile } from 'node:fs/promises';
import { notesProviders } from './companion-notes-files-source.mjs';
const [root, record] = process.argv.slice(2);
const reference = JSON.parse(await readFile(record, 'utf8'));
const { LocalFileSystem } = await notesProviders(root);
const fs = new LocalFileSystem({}, { cwd: reference.directory.target.displayPath, diffBasisMaxBytes: 10485760 });
await fs.dshGoPublishNotesFile(reference);
process.kill(process.pid, 'SIGKILL'); // after real link/readback; before any task artifact receipt
