import { createHash } from 'node:crypto';
import { join } from 'node:path';

const error = message => Object.assign(new Error(message), { code: 'EINVAL' });
const utf8 = new TextDecoder('utf-8', { fatal: true });

/** Read v2/v3 stage records for ls-files/write-tree checks; writes use isomorphic-git. */
export async function readIndex(options) {
  let bytes;
  try { bytes = await options.fs.promises.readFile(join(options.gitdir, 'index')); }
  catch (failure) { if (failure.code === 'ENOENT') return []; throw failure; }
  if (bytes.length < 32 || bytes.toString('ascii', 0, 4) !== 'DIRC') throw error('Invalid Git index');
  if (!createHash('sha1').update(bytes.subarray(0, -20)).digest().equals(bytes.subarray(-20)))
    throw error('Git index checksum mismatch');
  const version = bytes.readUInt32BE(4);
  if (version !== 2 && version !== 3) throw error('OHOS Git currently supports index version 2 and 3');
  const count = bytes.readUInt32BE(8), entries = [];
  let position = 12;
  for (let i = 0; i < count; ++i) {
    const start = position;
    if (position + 62 >= bytes.length - 20) throw error('Truncated Git index');
    const mode = bytes.readUInt32BE(position + 24), oid = bytes.toString('hex', position + 40, position + 60);
    const flags = bytes.readUInt16BE(position + 60);
    position += 62;
    if (flags & 0x4000) position += 2;
    const end = bytes.indexOf(0, position);
    if (end < position || end >= bytes.length - 20) throw error('Invalid Git index path');
    const path = utf8.decode(bytes.subarray(position, end));
    if (!path || path.startsWith('/') || path.split('/').some(part => !part || part === '.' || part === '..'))
      throw error('Unsafe Git index path');
    position = start + Math.ceil((end + 1 - start) / 8) * 8;
    if (position > bytes.length - 20) throw error('Truncated Git index padding');
    entries.push({ path, oid, mode, stage: (flags >> 12) & 3 });
  }
  return entries;
}

export async function stageTree(git, options) {
  const entries = await readIndex(options);
  if (entries.some(entry => entry.stage !== 0)) throw error('Cannot write a tree with unmerged index entries');
  const root = new Map();
  for (const entry of entries) {
    const pieces = entry.path.split('/');
    let current = root;
    for (const name of pieces.slice(0, -1)) {
      if (!current.has(name)) current.set(name, new Map());
      if (!(current.get(name) instanceof Map)) throw error('Index file/directory conflict');
      current = current.get(name);
    }
    current.set(pieces.at(-1), entry);
  }
  async function write(directory) {
    const tree = [];
    for (const [path, entry] of directory) {
      if (entry instanceof Map) tree.push({ path, mode: '040000', type: 'tree', oid: await write(entry) });
      else tree.push({ path, mode: entry.mode.toString(8), type: entry.mode === 0o160000 ? 'commit' : 'blob', oid: entry.oid });
    }
    return git.writeTree({ ...options, tree });
  }
  return write(root);
}
