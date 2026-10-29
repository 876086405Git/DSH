// Install Guard — 版本范围比较（零依赖，只覆盖 package.json 常见写法）
// 支持：* / latest / ^x.y.z / ~x.y.z / >=x / <=x / >x / <x / =x / x.y.z / x.y / x.x / 组合空格 / || 多段

export function parseVersion(text) {
  if (typeof text !== 'string') return undefined;
  const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:[-+]([0-9A-Za-z.-]+))?$/.exec(text.trim());
  if (!m) return undefined;
  return {
    major: Number(m[1]),
    minor: m[2] === undefined ? 0 : Number(m[2]),
    patch: m[3] === undefined ? 0 : Number(m[3]),
    pre: m[4] || '',
  };
}

export function compareVersions(a, b) {
  for (const key of ['major', 'minor', 'patch']) {
    if (a[key] !== b[key]) return a[key] < b[key] ? -1 : 1;
  }
  if (a.pre === b.pre) return 0;
  if (!a.pre) return 1;
  if (!b.pre) return -1;
  return a.pre < b.pre ? -1 : 1;
}

function satisfiesComparator(version, comparator) {
  const c = comparator.trim();
  if (!c || c === '*' || c === 'latest' || c === 'x') return true;
  const op = /^(>=|<=|>|<|=|\^|~)?\s*(.+)$/.exec(c);
  if (!op) return false;
  const operator = op[1] || '';
  const target = parseVersion(op[2]);
  if (!target) return false;
  const cmp = compareVersions(version, target);

  switch (operator) {
    case '>':
      return cmp > 0;
    case '>=':
      return cmp >= 0;
    case '<':
      return cmp < 0;
    case '<=':
      return cmp <= 0;
    case '=':
      return cmp === 0;
    case '^': {
      if (cmp < 0) return false;
      if (target.major > 0) return version.major === target.major;
      if (target.minor > 0) return version.major === 0 && version.minor === target.minor;
      return version.major === 0 && version.minor === 0 && version.patch === target.patch;
    }
    case '~': {
      if (cmp < 0) return false;
      return version.major === target.major && version.minor === target.minor;
    }
    default:
      return cmp === 0;
  }
}

export function satisfies(versionText, rangeText) {
  const version = parseVersion(versionText);
  if (!version) return false;
  if (typeof rangeText !== 'string' || !rangeText.trim()) return true;

  return rangeText
    .split('||')
    .map((part) => part.trim())
    .filter(Boolean)
    .some((part) => {
      const comparators = part.split(/\s+/).filter(Boolean);
      if (comparators.length === 1) {
        const single = comparators[0];
        if (/^[0-9]/.test(single) || /^v?[0-9]/.test(single)) {
          const bare = single.replace(/^v/, '');
          const segments = bare.split('.');
          if (segments.length === 1) return version.major === Number(segments[0]);
          if (segments[1] === 'x' || segments[1] === '*') return version.major === Number(segments[0]);
          if (segments.length === 2) {
            return version.major === Number(segments[0]) && version.minor === Number(segments[1]);
          }
        }
      }
      return comparators.every((c) => satisfiesComparator(version, c));
    });
}
