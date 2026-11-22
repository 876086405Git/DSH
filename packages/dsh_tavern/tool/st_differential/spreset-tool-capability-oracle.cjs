// Execute only fixed ST support/model-selection functions, not the site runtime.
const fs = require('node:fs');
const crypto = require('node:crypto');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const [toolPath, openaiPath, inputPath, destination] = process.argv.slice(2);
assert.ok(toolPath && openaiPath && inputPath && destination);
function read(file, expected) {
  const bytes = fs.readFileSync(file);
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), expected);
  return bytes.toString('utf8');
}
function between(source, start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, start);
  return source.slice(a, b);
}
const toolSha = '934be74f6bd672a821e5f3e5dc34ad4548c1cac60ee41c48feaa630e6e2f7712';
const openaiSha = '0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604';
const tool = read(toolPath, toolSha), openai = read(openaiPath, openaiSha);
const selector = between(openai, 'export function getChatCompletionModel(', 'function getOpenRouterModelTemplate(').replace(/^export /, '');
const modelFields = [...new Set([...selector.matchAll(/settings\.([a-z_]+_model)/g)].map(match => match[1]))];
const websiteLine = openai.split('\n').find(line => line.startsWith('const openrouter_website_model ='));
assert.ok(websiteLine);
const context = vm.createContext({ console: {error() {}}, main_api: 'openai', model_list: [], oai_settings: {} });
vm.runInContext([
  websiteLine,
  between(openai, 'export const chat_completion_sources =', 'const character_names_behavior =').replace(/^export /, ''),
  between(openai, 'export const custom_prompt_post_processing_types =', 'const openrouter_middleout_types =').replace(/^export /, ''),
  selector,
  'class ToolManager {',
  between(tool, '    static isToolCallingSupported(', '    /**\n     * Utility function to get tool calls from the response data.'),
  '}',
].join('\n'), context);
const input = JSON.parse(fs.readFileSync(inputPath, 'utf8'));
const cases = input.cases.map(row => {
  context.oai_settings = {
    ...Object.fromEntries(modelFields.map(field => [field, row.model])),
    chat_completion_source: row.source,
    function_calling: true,
    custom_prompt_post_processing: '',
  };
  context.model_list = row.catalog;
  // Verify the host-facing fixture fact against the source's actual first match.
  const match = vm.runInContext('Array.isArray(model_list) ? model_list.find(m => m.id === getChatCompletionModel()) : null', context);
  assert.deepEqual(row.lookup, match ? {kind:'matched',row:JSON.parse(JSON.stringify(match))} : {kind:'noMatch'}, row.id);
  let expected;
  try {
    const value = vm.runInContext('ToolManager.isToolCallingSupported()', context);
    expected = { supported: Boolean(value), rawType: value === undefined ? 'undefined' : value === null ? 'null' : typeof value };
  } catch (error) {
    expected = { error: error.name };
  }
  return { ...row, expected };
});
fs.writeFileSync(destination, JSON.stringify({
  source: {
    commit:'7e8663cd9c184a550b37238218bdd32c6efc68e9',
    toolCallingSha256:toolSha, openaiSha256:openaiSha,
    method:'ToolManager.isToolCallingSupported; true function, not a support stub',
  },
  scope:input.scope,
  cases,
}, null, 2) + '\n');
console.log(JSON.stringify({catalogVectors:cases.length,destination}));
