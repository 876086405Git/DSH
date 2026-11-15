export const fixtureFiles = {
  '.gitignore': 'ignored.txt\nignored-dir/\n',
  '.ignore': 'ignore-only.txt\n',
  '.rgignore': 'rg-only.txt\n',
  'keep.txt': 'needle 中文\n',
  'other.md': 'needle markdown\n',
  'ignored.txt': 'needle gitignored\n',
  'ignore-only.txt': 'needle ignore\n',
  'rg-only.txt': 'needle rgignore\n',
  'ignored-dir/hidden.txt': 'needle pruned\n',
  'nested/keep.txt': 'needle nested\n',
  'nested/.gitignore': 'local-hidden.txt\n',
  'nested/local-hidden.txt': 'needle local ignored\n',
  // Different pattern: routine differential cases stay byte-for-byte comparable.
  'external-only.txt': 'CONTROL_EXCLUDE_ONLY\n',
};
const patterns = [
  ['implicit-no-include', ['--json', '--regexp=needle']],
  ['directory-no-include', ['--json', '--regexp=needle', '--', '.']],
  ['positive-include', ['--json', '--regexp=needle', '--glob=**/*.txt', '--', '.']],
  ['nested-directory', ['--json', '--regexp=needle', '--', 'nested']],
  ['nested-cwd', ['--json', '--regexp=needle', '--', '.'], 'nested'],
  ['no-ignore', ['--json', '--no-ignore', '--regexp=needle', '--', '.']],
];
export const cases = [
  ...['directory', 'worktree', 'submodule'].flatMap(repo => patterns.map(([name, args, cwd = '']) => ({ name: `${repo}-${name}`, repo, args, cwd, equivalence: 'exact' }))),
  { name: 'directory-info-exclude-kept', repo: 'directory', cwd: '', args: ['--json', '--regexp=CONTROL_EXCLUDE_ONLY', '--', '.'], equivalence: 'exact' },
  ...['worktree', 'submodule'].map(repo => ({ name: `${repo}-bash-entry`, repo, cwd: '', args: ['--json', '--regexp=needle', '--', '.'], shell: true, equivalence: 'exact' })),
  ...['worktree', 'submodule'].map(repo => ({ name: `${repo}-private-info-exclude-skipped`, repo, cwd: '', args: ['--json', '--regexp=CONTROL_EXCLUDE_ONLY', '--', '.'], equivalence: repo === 'worktree' ? 'documented-extra-result' : 'exact', extraPath: 'external-only.txt' })),
];
