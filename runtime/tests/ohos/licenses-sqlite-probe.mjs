import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const entry = resolve(process.env.M4_BASH_ROOT, 'dist/bundle/index.js');
try {
  const { Bash } = await import(pathToFileURL(entry));
  const { stdout, stderr, exitCode } = await new Bash().exec("sqlite3 :memory: 'select 1;'");
  console.log(JSON.stringify({ entry, stdout, stderr, exitCode }));
} catch (error) {
  console.log(JSON.stringify({ entry, error: { name: error.name, code: error.code, message: error.message } }));
}
