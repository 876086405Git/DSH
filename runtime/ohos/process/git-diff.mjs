import { diffLines, createTwoFilesPatch } from 'diff';

const binary = bytes => bytes.subarray(0, 8000).includes(0);
const order = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));

export async function treeEntries(git, options, ref) {
  const entries = new Map();
  await git.walk({ ...options, trees: [git.TREE({ ref })], map: async (path, [entry]) => {
    if (!entry || path === '.') return;
    const type = await entry.type();
    if (type === 'tree') return;
    entries.set(path, { path, type, mode: await entry.mode(), oid: await entry.oid() });
    if (type === 'commit') return null;
  } });
  return entries;
}

export async function objectBytes(git, options, entry) {
  if (!entry) return Buffer.alloc(0);
  if (entry.bytes !== undefined) return entry.bytes;
  if (entry.type === 'commit' || entry.mode === 0o160000) return Buffer.from(`Subproject commit ${entry.oid}\n`);
  return Buffer.from((await git.readObject({ ...options, oid: entry.oid, format: 'content' })).object);
}

function counts(before, after) {
  if (binary(before) || binary(after)) return { added: '-', deleted: '-' };
  const parts = diffLines(before.toString('utf8'), after.toString('utf8'), { timeout: 1000 });
  if (!parts) throw Object.assign(new Error('Git line diff exceeded its computation budget'), { code: 'E2BIG' });
  return {
    added: parts.reduce((sum, part) => sum + (part.added ? part.count : 0), 0),
    deleted: parts.reduce((sum, part) => sum + (part.removed ? part.count : 0), 0),
  };
}

// Conservative, deterministic rename matching. Identical blobs are exact; edited
// text candidates use common complete-line bytes and are documented as a subset
// of native Git's similarity heuristics, never as a bit-for-bit clone of them.
function similarity(before, after) {
  if (binary(before) || binary(after) || !before.length || !after.length) return 0;
  const tally = bytes => {
    const map = new Map();
    for (const line of bytes.toString('latin1').match(/[^\n]*\n|[^\n]+$/g) ?? [])
      map.set(line, (map.get(line) ?? 0) + 1);
    return map;
  };
  const left = tally(before), right = tally(after);
  let shared = 0;
  for (const [line, count] of left) shared += line.length * Math.min(count, right.get(line) ?? 0);
  return shared / Math.max(before.length, after.length);
}

export async function changes(git, options, before, after, { renames = false } = {}) {
  const result = [], removed = [], added = [];
  for (const path of new Set([...before.keys(), ...after.keys()])) {
    const old = before.get(path), next = after.get(path);
    if (old && next && old.oid === next.oid && old.mode === next.mode) continue;
    if (old && next) result.push({ path, before: old, after: next });
    else if (old) removed.push(old);
    else added.push(next);
  }
  const content = new Map();
  const bytes = async entry => {
    if (!entry) return Buffer.alloc(0);
    if (!content.has(entry.oid)) content.set(entry.oid, await objectBytes(git, options, entry));
    return content.get(entry.oid);
  };
  const usedOld = new Set(), usedNew = new Set();
  if (renames) {
    if (removed.length * added.length > 10000) throw Object.assign(new Error('Git rename candidate limit exceeded'), { code: 'E2BIG' });
    const pairs = [];
    for (const old of removed) for (const next of added) {
      if ((old.mode & 0o170000) !== (next.mode & 0o170000)) continue;
      const score = old.oid === next.oid ? 1 : await similarity(await bytes(old), await bytes(next));
      if (score >= 0.5) pairs.push({ old, next, score });
    }
    pairs.sort((a, b) => b.score - a.score || order(a.next.path, b.next.path) || order(a.old.path, b.old.path));
    for (const pair of pairs) {
      if (usedOld.has(pair.old.path) || usedNew.has(pair.next.path)) continue;
      usedOld.add(pair.old.path); usedNew.add(pair.next.path);
      result.push({ path: pair.next.path, oldPath: pair.old.path, before: pair.old, after: pair.next });
    }
  }
  for (const old of removed) if (!usedOld.has(old.path)) result.push({ path: old.path, before: old });
  for (const next of added) if (!usedNew.has(next.path)) result.push({ path: next.path, after: next });
  result.sort((a, b) => order(a.path, b.path));
  for (const change of result) {
    change.oldBytes = await bytes(change.before); change.newBytes = await bytes(change.after);
    Object.assign(change, counts(change.oldBytes, change.newBytes));
  }
  return result;
}

export function formatChanges(rows, { numstat = false, nul = false, nameOnly = false } = {}) {
  if (nameOnly) return rows.map(row => row.path + (nul ? '\0' : '\n')).join('');
  if (numstat) return rows.map(row => {
    const name = row.oldPath ? (nul ? `\0${row.oldPath}\0${row.path}` : `${row.oldPath} => ${row.path}`) : row.path;
    return `${row.added}\t${row.deleted}\t${name}${nul ? '\0' : '\n'}`;
  }).join('');
  return rows.map(row => {
    const oldName = row.before ? `a/${row.oldPath ?? row.path}` : '/dev/null';
    const newName = row.after ? `b/${row.path}` : '/dev/null';
    let header = `diff --git a/${row.oldPath ?? row.path} b/${row.path}\n`;
    if (!row.before) header += `new file mode ${row.after.mode.toString(8)}\n`;
    else if (!row.after) header += `deleted file mode ${row.before.mode.toString(8)}\n`;
    else if (row.before.mode !== row.after.mode) header += `old mode ${row.before.mode.toString(8)}\nnew mode ${row.after.mode.toString(8)}\n`;
    if (row.oldPath) header += `rename from ${row.oldPath}\nrename to ${row.path}\n`;
    if (row.added === '-') return header + `Binary files ${oldName} and ${newName} differ\n`;
    if (row.oldBytes.equals(row.newBytes)) return header;
    const patch = createTwoFilesPatch(oldName, newName, row.oldBytes.toString('utf8'), row.newBytes.toString('utf8'), '', '', { context: 3 });
    return header + patch.replace(/^(?:Index:.*\n)?={3,}\n/, '');
  }).join('');
}
