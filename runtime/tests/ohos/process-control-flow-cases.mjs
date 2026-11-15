// Shared test input only. Native Bash independently checks every expected byte.
const binary = Buffer.from([0, 255, 195, 169, 128, 10]);
const doubled = Buffer.concat([binary, binary]);
const allBytes = Buffer.from(Array.from({ length: 256 }, (_, index) => index));
export const controlFlowFiles = {
  binary, 'all-bytes': allBytes, 'utf8-first': Buffer.from([195]), 'utf8-second': Buffer.from([169]),
  'return.sh': Buffer.from('cat binary; return 7\n'),
  'exit.sh': Buffer.from('cat binary; exit 7\n'),
};
const row = (name, command, stdout = binary, exitCode = 7, file = null) => ({
  name, command, exitCode, stdoutHex: stdout.toString('hex'), stderrHex: '',
  fileHex: file === null ? null : file.toString('hex'),
});
export const controlFlowCases = [
  row('top-level exit', 'cat binary; exit 7'),
  row('brace exit', '{ cat binary; exit 7; }'),
  row('subshell exit', '(cat binary; exit 7)'),
  row('nested shell exit', "bash -c 'cat binary; exit 7'"),
  row('function return', 'f(){ cat binary; return 7; }; f'),
  row('function exit', 'f(){ cat binary; exit 7; }; f'),
  row('function return file', 'f(){ cat binary; return 7; }; f > result.bin', Buffer.alloc(0), 7, binary),
  row('brace exit file', '{ cat binary; exit 7; } > result.bin', Buffer.alloc(0), 7, binary),
  row('function return pipe', 'f(){ cat binary; return 7; }; f | cat', binary, 0),
  row('for break', 'for x in 1 2; do cat binary; break; done', binary, 0),
  row('for continue', 'for x in 1 2; do cat binary; continue; done', doubled, 0),
  row('two-level break', 'for x in 1 2; do for y in 1 2; do cat binary; break 2; done; done', binary, 0),
  row('two-level continue', 'for x in 1 2; do for y in 1 2; do cat binary; continue 2; done; done', doubled, 0),
  row('while condition break', 'for x in 1 2; do while { cat binary; break 2; }; do :; done; done', binary, 0),
  row('while condition continue', 'for x in 1 2; do while { cat binary; continue 2; }; do :; done; done', doubled, 0),
  row('if return', 'f(){ if true; then cat binary; return 7; fi; }; f'),
  row('case return', 'f(){ case x in x) cat binary; return 7;; esac; }; f'),
  row('for return', 'f(){ for x in 1 2; do cat binary; return 7; done; }; f'),
  row('C-style for return', 'f(){ for ((i=0;i<2;i++)); do cat binary; return 7; done; }; f'),
  row('while return', 'f(){ while true; do cat binary; return 7; done; }; f'),
  row('until return', 'f(){ until false; do cat binary; return 7; done; }; f'),
  row('nested brace return', 'f(){ { { cat binary; return 7; }; }; }; f'),
  row('source return', '. ./return.sh'),
  row('script exit', 'bash ./exit.sh'),
  row('errexit', 'set -e; { cat binary; false; }; printf UNREACHABLE', binary, 1),
  row('stderr merged at return', "f(){ cat binary; printf '你好' >&2; return 7; }; f 2>&1", Buffer.concat([binary, Buffer.from('你好')])),
  row('mixed text and bytes', "f(){ printf '前'; cat binary; printf '后'; return 7; }; f", Buffer.concat([Buffer.from('前'), binary, Buffer.from('后')])),
  row('split UTF-8 before return', 'f(){ cat utf8-first; cat utf8-second; return 7; }; f', Buffer.from([195, 169])),
  row('all byte values before return', 'f(){ cat all-bytes; return 7; }; f', allBytes),
  row('preceding and following statements', "printf '前'; f(){ cat binary; return 7; }; f; printf '后'", Buffer.concat([Buffer.from('前'), binary, Buffer.from('后')]), 0),
  row('Unicode command substitution exit', 'printf "<%s>" "$(printf 你好; exit 7)"', Buffer.from('<你好>'), 0),
  row('Unicode command substitution return', 'f(){ printf 你好; return 7; }; printf "<%s>" "$(f)"', Buffer.from('<你好>'), 0),
];
