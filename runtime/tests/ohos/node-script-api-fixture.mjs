import assert from 'node:assert/strict';
import fs from 'node:fs';
import promises from 'node:fs/promises';
import { promisify } from 'node:util';
import { once } from 'node:events';
import { resolve } from 'node:path';

const requests = JSON.parse(process.argv[2]);
assert(['native', 'strict'].includes(process.argv[3]));
const observations = [];
for (const request of requests) {
  const { kind, name, operation, completion } = request;
  const api = kind === 'fs' ? fs : promises;
  if (api[name] === undefined && ['lchmod', 'lchmodSync'].includes(name)) {
    observations.push({ kind, name, nativeUnavailable: true }); continue;
  }
  const stem = `${kind}-${name}-中文`, source = `${stem}.txt`, dest = `${stem}-dest.txt`, dir = `${stem}-dir`;
  fs.writeFileSync(source, '中文 source');
  let args, inspect = () => {}, special;
  switch (operation) {
    case 'access': case 'exists': case 'stat': case 'lstat': case 'statfs': case 'readFile':
    case 'realpath': case 'openAsBlob': args = [source]; break;
    case 'readlink': args = [dest]; break;
    case 'readdir': case 'opendir': fs.mkdirSync(dir); args = [dir]; break;
    case 'chmod': case 'lchmod': args = [source, 0o600]; break;
    case 'chown': case 'lchown': args = [source, process.getuid(), process.getgid()]; break;
    case 'utimes': case 'lutimes': args = [source, new Date(10000), new Date(20000)]; break;
    case 'open': args = [source, 'r']; break;
    case 'mkdir': args = [dir]; inspect = () => assert(fs.statSync(dir).isDirectory()); break;
    case 'mkdtemp': case 'mkdtempDisposable': args = [stem + '-']; break;
    case 'truncate': args = [source, 2]; inspect = () => assert.equal(fs.statSync(source).size, 2); break;
    case 'writeFile': args = [dest, '写入']; inspect = () => assert.equal(fs.readFileSync(dest, 'utf8'), '写入'); break;
    case 'appendFile': args = [source, '+追加']; inspect = () => assert.equal(fs.readFileSync(source, 'utf8'), '中文 source+追加'); break;
    case 'rename': case 'copyFile': case 'link': args = [source, dest]; inspect = () => assert.equal(fs.readFileSync(dest, 'utf8'), '中文 source'); break;
    case 'cp': {
      let calls = 0;
      args = [source, dest, { filter(from, to) {
        calls++; assert.equal(from, resolve(source)); assert.equal(to, resolve(dest)); return true;
      } }];
      inspect = () => { assert(calls > 0); assert.equal(fs.readFileSync(dest, 'utf8'), '中文 source'); }; break;
    }
    case 'rm': case 'unlink': args = [source]; inspect = () => assert.equal(fs.existsSync(source), false); break;
    case 'rmdir': fs.mkdirSync(dir); args = [dir]; inspect = () => assert.equal(fs.existsSync(dir), false); break;
    case 'symlink':
      fs.mkdirSync(dir); args = ['../' + source, `${dir}/link`];
      inspect = () => { assert.equal(fs.readlinkSync(`${dir}/link`), '../' + source); assert.equal(fs.readFileSync(`${dir}/link`, 'utf8'), '中文 source'); }; break;
    case 'glob': args = [source]; break;
    case 'createReadStream': case 'ReadStream': case 'FileReadStream':
      args = [source]; special = 'read-stream'; break;
    case 'createWriteStream': case 'WriteStream': case 'FileWriteStream':
      args = [dest]; special = 'write-stream'; break;
    case 'Utf8Stream': args = [{ dest, sync: true }]; special = 'utf8-stream'; break;
    case 'watch': args = [source]; special = kind === 'fs' ? 'watch' : 'promise-watch'; break;
    case 'watchFile': args = [source, { persistent: false }, () => {}]; special = 'watch-file'; break;
    case 'unwatchFile': {
      const watcher = fs.watchFile(source, { persistent: false }, () => {});
      args = [source]; inspect = () => assert.equal(watcher.listenerCount('change'), 0); break;
    }
    default: throw new Error('Executable fixture missing for path operation ' + operation);
  }
  let value;
  const deniedLink = ['link', 'symlink'].includes(operation) && process.argv[3] === 'strict';
  try {
    if (special === 'promise-watch') {
      const signal = new AbortController();
      const iterator = promises.watch(source, { signal: signal.signal });
      const next = iterator.next(); await promises.writeFile(source, 'watch changed');
      value = await next; assert.equal(value.value.eventType, 'change'); signal.abort(); await iterator.return();
    } else if (completion === 'callback') value = await promisify(api[name])(...args);
    else if (completion === 'iterator') value = await Array.fromAsync(api[name](...args));
    else if (['ReadStream', 'WriteStream', 'FileReadStream', 'FileWriteStream', 'Utf8Stream'].includes(operation)) value = new api[name](...args);
    else value = await api[name](...args);
    if (deniedLink) assert.fail(`${kind}.${name} unexpectedly created a link in strict simulation`);
    if (special === 'read-stream') {
      const chunks = []; for await (const chunk of value) chunks.push(chunk);
      assert.equal(Buffer.concat(chunks).toString(), '中文 source');
    } else if (special === 'write-stream' || special === 'utf8-stream') {
      const closed = once(value, 'close');
      if (special === 'utf8-stream') { value.write('写入'); value.end(); }
      else value.end('写入');
      await closed; assert.equal(fs.readFileSync(dest, 'utf8'), '写入');
    } else if (special === 'watch') value.close();
    else if (special === 'watch-file') { fs.unwatchFile(source); assert.equal(value.listenerCount('change'), 0); }
    else if (operation === 'exists') assert.equal(value, true);
    else if (operation === 'readFile') assert.equal(value.toString(), '中文 source');
    else if (operation === 'realpath') assert.equal(value, resolve(source));
    else if (operation === 'readlink') assert.equal(value, source);
    else if (operation === 'openAsBlob') assert.equal(await value.text(), '中文 source');
    else if (operation === 'stat' || operation === 'lstat') assert(value.isFile());
    else if (operation === 'statfs') assert(value.bsize > 0);
    else if (operation === 'open') {
      if (kind === 'promises') { assert.equal((await value.readFile()).toString(), '中文 source'); await value.close(); }
      else { assert.equal(fs.readFileSync(value, 'utf8'), '中文 source'); fs.closeSync(value); }
    } else if (operation === 'opendir') await value.close();
    else if (operation === 'readdir') assert.deepEqual(value, []);
    else if (operation === 'mkdtemp') { assert(fs.statSync(value).isDirectory()); fs.rmdirSync(value); }
    else if (operation === 'mkdtempDisposable') {
      assert(fs.statSync(value.path).isDirectory()); await value.remove(); assert.equal(fs.existsSync(value.path), false);
    } else if (operation === 'glob') assert.deepEqual(Array.from(value), [source]);
    inspect(); observations.push({ kind, name, called: true });
  } catch (error) {
    if (operation === 'lchmod' && ['ENOSYS', 'ERR_METHOD_NOT_IMPLEMENTED'].includes(error.code)) observations.push({ kind, name, nativeUnavailable: true, code: error.code });
    else if (deniedLink && error.code === 'EACCES') {
      assert.throws(() => fs.lstatSync(args[1]), { code: 'ENOENT' });
      observations.push({ kind, name, originalOhosDenial: true, code: error.code });
    }
    else { console.error('API_CASE_FAILED', kind, name, error); throw error; }
  }
}
assert.equal(await promisify(fs.exists)('fs-readFile-中文.txt'), true);
assert.equal(await promisify(fs.realpath.native)('fs-readFile-中文.txt'), resolve('fs-readFile-中文.txt'));
assert.equal(fs.realpathSync.native('fs-readFile-中文.txt'), resolve('fs-readFile-中文.txt'));
const writer = new fs.Utf8Stream({ dest: 'utf8-original', sync: true });
const closed = once(writer, 'close'); writer.write('a'); writer.flushSync();
fs.Utf8Stream.prototype.reopen.call(writer, 'utf8-reopened'); writer.write('b'); writer.end(); await closed;
assert.equal(fs.readFileSync('utf8-original', 'utf8'), 'a'); assert.equal(fs.readFileSync('utf8-reopened', 'utf8'), 'b');
console.log(JSON.stringify({ status: 'PASS_SCOPED', observations, nested: ['realpath.native', 'realpathSync.native', 'Utf8Stream.prototype.reopen'], cwd: process.cwd() }));
