// Execute the real, fixed ST 1.19.0 converter on synthetic inputs.
// Usage: node tool/st_differential/postprocessing-oracle.mjs /path/to/ST/src/prompt-converters.js
// No browser host, substitute macro engine, or copied conversion algorithm.
import fs from 'node:fs';
import crypto from 'node:crypto';
import vm from 'node:vm';

const input = JSON.parse(fs.readFileSync('test/fixtures/st-postprocessing-input.json', 'utf8'));
const source = fs.readFileSync(process.argv[2], 'utf8');
if (crypto.createHash('sha256').update(source).digest('hex') !== input.sourceSha256) {
  throw new Error('Expected the recorded ST 1.19.0 prompt-converters.js bytes.');
}
function declaration(prefix, end) {
  const start = source.indexOf(prefix);
  if (start < 0) throw new Error(`Missing source declaration: ${prefix}`);
  const stop = source.indexOf(end, start);
  if (stop < 0) throw new Error(`Missing source declaration ending: ${prefix}`);
  return source.slice(start, stop + end.length).replace(/^export /, '');
}
const context = vm.createContext({ crypto, getConfigValue: (_name, fallback) => fallback });
vm.runInContext([
  declaration('const PROMPT_PLACEHOLDER =', '\n'),
  declaration('export const PROMPT_PROCESSING_TYPE =', '\n};'),
  declaration('export function postProcessPrompt(', '\n}'),
  declaration('export function mergeMessages(', '\n}'),
  'globalThis.runConverter = postProcessPrompt;',
].join('\n'), context);
const names = { ...input.names, startsWithGroupName(text) {
  return this.groupNames.some(name => text.startsWith(`${name}: `));
} };
const cases = input.cases.flatMap(item => item.modes.map(mode => {
  const recorded = { id: `${item.id}/${mode || 'none'}`, mode, messages: item.messages };
  try { recorded.expected = context.runConverter(structuredClone(item.messages), mode, names); }
  catch (error) { recorded.expectedError = error.name; }
  return recorded;
}));
const output = { sourceCommit: input.sourceCommit, sourceSha256: input.sourceSha256,
  sourceUrl: `https://github.com/SillyTavern/SillyTavern/blob/${input.sourceCommit}/src/prompt-converters.js`,
  names: input.names, cases };
fs.writeFileSync('test/fixtures/st-postprocessing.json', `${JSON.stringify(output, null, 2)}\n`);
console.log(`ST oracle: ${cases.length} recorded mode/shape cases`);
