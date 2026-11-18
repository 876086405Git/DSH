// 一个清单供执行器、O6 能力协议和 bash 工具说明使用。
export const shellCommands = Object.freeze([
  'echo', 'cat', 'printf', 'ls', 'mkdir', 'mktemp', 'rmdir', 'touch', 'rm',
  'cp', 'mv', 'ln', 'chmod', 'pwd', 'readlink', 'head', 'tail', 'wc', 'stat',
  'grep', 'fgrep', 'egrep', 'rg', 'git', 'sed', 'awk', 'sort', 'uniq', 'comm', 'cut',
  'paste', 'tr', 'rev', 'nl', 'fold', 'expand', 'unexpand', 'strings', 'split',
  'column', 'join', 'tee', 'find', 'basename', 'dirname', 'tree', 'du', 'env',
  'printenv', 'alias', 'unalias', 'history', 'xargs', 'true', 'false', 'yes',
  'clear', 'bash', 'sh', 'jq', 'base64', 'diff', 'date', 'sleep', 'timeout',
  'seq', 'expr', 'md5sum', 'sha1sum', 'sha256sum', 'file', 'help', 'which',
  'tac', 'hostname', 'od', 'gzip', 'gunzip', 'zcat', 'time', 'whoami', 'node',
]);

export const subprocessCommands = Object.freeze(['bash', 'sh', 'rg', 'git', 'node']);
export const unavailableMessage = '这个命令在鸿蒙本机不可用，可以连接电脑执行';

export const capabilities = Object.freeze({
  kind: 'virtual',
  commands: shellCommands,
  // 已完成的外层 shell 语句逐段交付；单个命令和复合语句内部仍缓冲。
  streamingOutput: true,
  stdin: 'batch',
  pty: false,
  processSpawn: false,
  // Runtime instances additionally require the inherited product preload.
  nodeScripts: 'worker-rebased',
  python: false,
  wasm: false,
});
