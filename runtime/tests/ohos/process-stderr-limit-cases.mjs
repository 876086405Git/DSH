const binary = Buffer.from([0, 255, 195, 169, 128, 10]);
const errorBytes = Buffer.from([254, 240, 159, 152, 128, 10]);
const chinese = Buffer.from('你好');
const allBytes = Buffer.from(Array.from({ length: 256 }, (_, i) => i));
export const stderrLimitFiles = {
  b: binary, e: errorBytes, chinese, all: allBytes,
  first: chinese.subarray(0, 2), rest: chinese.subarray(2),
  'limit.sh': Buffer.from('cat e >&2; cat e >&2\n'),
};
const twice = value => Buffer.concat([value, value]);
const repeat = command => `for x in 1 2; do for y in 1 2; do ${command}; continue 2; done; done`;
export const stderrLimitCases = [
  { name: 'nonempty earlier statement stays delivered once', command: 'cat e >&2; cat e >&2',
    budget: 11, stdout: Buffer.alloc(0), prefix: errorBytes, exactBudget: 12, completeStderr: twice(errorBytes), requireEarlyDelivery: true },
  { name: 'first rejected output has only a text diagnostic', command: 'cat e >&2',
    budget: 5, stdout: Buffer.alloc(0), prefix: Buffer.alloc(0), exactBudget: 6, completeStderr: errorBytes,
    directDiagnostic: 'bash: cat: output size limit exceeded (5 bytes)\n' },
  { name: 'original nested continue at 23 bytes', command: repeat('cat b; cat e >&2'),
    budget: 23, stdout: twice(binary), prefix: errorBytes, exactBudget: 24, completeStderr: twice(errorBytes) },
  { name: 'function output before budget failure', command: 'f(){ cat e >&2; cat e >&2; }; f',
    budget: 11, stdout: Buffer.alloc(0), prefix: errorBytes, exactBudget: 12, completeStderr: twice(errorBytes) },
  { name: 'subshell output before budget failure', command: '(cat e >&2; cat e >&2)',
    budget: 11, stdout: Buffer.alloc(0), prefix: errorBytes, exactBudget: 12, completeStderr: twice(errorBytes) },
  { name: 'eval output before budget failure', command: 'eval "cat e >&2; cat e >&2"',
    budget: 11, stdout: Buffer.alloc(0), prefix: errorBytes, exactBudget: 12, completeStderr: twice(errorBytes) },
  { name: 'source output before budget failure', command: '. ./limit.sh',
    budget: 11, stdout: Buffer.alloc(0), prefix: errorBytes, exactBudget: 12, completeStderr: twice(errorBytes) },
  { name: 'valid UTF-8 prefix', command: repeat('cat b; cat chinese >&2'),
    budget: 23, stdout: twice(binary), prefix: chinese, exactBudget: 24, completeStderr: twice(chinese) },
  { name: 'UTF-8 split across accepted commands', command: 'for x in 1 2; do cat first >&2; cat rest >&2; continue; done',
    budget: 11, stdout: Buffer.alloc(0), prefix: Buffer.concat([chinese, chinese.subarray(0, 2)]), exactBudget: 12, completeStderr: twice(chinese) },
  { name: 'all 256 byte values', command: 'for x in 1 2; do cat all >&2; continue; done',
    budget: 511, stdout: Buffer.alloc(0), prefix: allBytes, exactBudget: 512, completeStderr: twice(allBytes) },
];
