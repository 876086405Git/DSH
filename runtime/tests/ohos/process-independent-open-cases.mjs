export const independentOpenFiles = {
  'stdout.bin': Buffer.from([0x41, 0x42, 0, 0xc3, 0xa9, 0x80, 0x43, 0x44, 0x45]),
  'stderr.bin': Buffer.from([0x31, 0xff, 0x32]),
  'all-bytes.bin': Buffer.from(Array.from({ length: 256 }, (_, index) => index)),
};

const text = '{ printf ABCDEFGHI; printf 123 >&2; }';
const raw = '{ cat stdout.bin; cat stderr.bin >&2; }';
export const independentOpenCases = [
  { name: 'two-truncating-opens', command: `${text} > result.bin 2> result.bin` },
  { name: 'append-then-truncate', command: `${text} >> result.bin 2> result.bin`, initial: 'old-prefix' },
  { name: 'reverse-open-order', command: `${text} 2> result.bin > result.bin` },
  { name: 'truncate-then-append', command: `${text} > result.bin 2>> result.bin` },
  { name: 'two-appending-opens', command: `${text} >> result.bin 2>> result.bin`, initial: 'old-prefix' },
  { name: 'explicit-clobber', command: `${text} >| result.bin 2>| result.bin`, initial: 'old-prefix-longer-than-output' },
  { name: 'old-tail-truncated-on-open', command: `${text} > result.bin 2> result.bin`, initial: 'old-prefix-longer-than-output' },
  { name: 'empty-stderr', command: '{ printf ABCDEFGHI; :; } > result.bin 2> result.bin' },
  { name: 'empty-stdout', command: '{ printf 123 >&2; } > result.bin 2> result.bin' },
  { name: 'both-empty', command: ': > result.bin 2> result.bin', initial: 'old-prefix' },
  { name: 'stderr-longer', command: '{ printf 123; printf ABCDEFGHI >&2; } > result.bin 2> result.bin' },
  { name: 'raw-tail', command: `${raw} > result.bin 2> result.bin` },
  { name: 'raw-append-truncate', command: `${raw} >> result.bin 2> result.bin`, initial: 'old-prefix' },
  { name: 'all-byte-tail', command: '{ cat all-bytes.bin; cat stderr.bin >&2; } > result.bin 2> result.bin' },
  { name: 'utf8-tail', command: "{ printf '甲乙丙'; printf '丁' >&2; } > result.bin 2> result.bin" },
  { name: 'unicode-path', command: `${raw} > '结果.bin' 2> '结果.bin'`, output: '结果.bin' },
  { name: 'lexical-alias', command: `${raw} > result.bin 2> ./result.bin` },
  { name: 'symlink-alias', command: `${raw} > result.bin 2> alias.bin`, symlink: true },
  { name: 'function-return', command: 'f(){ cat stdout.bin; cat stderr.bin >&2; return 7; }; f > result.bin 2> result.bin' },
  { name: 'brace-exit', command: '{ cat stdout.bin; cat stderr.bin >&2; exit 7; } > result.bin 2> result.bin' },
  { name: 'nested-shell', command: "bash -c 'cat stdout.bin; cat stderr.bin >&2' > result.bin 2> result.bin" },
  { name: 'loop-two-writes', command: 'for x in 1 2; do cat stdout.bin; cat stderr.bin >&2; done > result.bin 2> result.bin' },
  { name: 'stdout-pieces', command: '{ printf ABC; printf DEF; printf 123 >&2; } > result.bin 2> result.bin' },
  { name: 'dup-stderr-control', command: `${text} 2> result.bin 1>&2` },
  { name: 'dup-stdout-control', command: `${text} > result.bin 2>&1` },
  { name: 'dup-append-control', command: `${text} 2>> result.bin 1>&2`, initial: 'old-prefix' },
  { name: 'discard-control', command: `${text} > /dev/null 2> result.bin` },
];

// Existing broader limitations are measured separately; a local file-write
// repair must not silently claim persistent FD or interstream-order parity.
export const independentOpenAdjacentCases = [
  { name: 'stderr-first-buffered-group', command: '{ printf 123 >&2; printf ABCDEFGHI; } > result.bin 2> result.bin' },
  { name: 'persistent-standard-fds', command: 'exec > result.bin 2> result.bin; printf ABCDEFGHI; printf 123 >&2' },
  { name: 'persistent-numeric-fds', command: 'exec 3> result.bin 4> result.bin; printf ABCDEFGHI >&3; printf 123 >&4' },
];
