// Fixed SPreset handler and conditional-tag function; downstream squash is an
// explicit observation boundary. This does not assert whole follow equivalence.
const fs = require('node:fs'), vm = require('node:vm');
const assert = require('node:assert/strict'), crypto = require('node:crypto');
const source = fs.readFileSync(process.argv[2], 'utf8');
const sha = value => crypto.createHash('sha256').update(value).digest('hex');
assert.equal(sha(source), '4858bcb57530e3ff6ef68f0c94a4d291e2914c766c274f888e9a2fdf8d0efb59');
const start = source.indexOf('  const handleChatCompletionPromptReady = data => {');
const conditional = source.indexOf('  function consumeConditionalTag(prompts) {', start);
const end = source.indexOf('\n  ctx.eventSource.on(ctx.eventTypes.APP_READY, data => {', conditional);
assert.ok(start >= 0 && conditional > start && end > conditional);
const handleCode = source.slice(start, conditional);
const conditionalCode = source.slice(conditional, end);
const cases = [
  {name: 'enabled-tool-string', enabled: true, tag: '<yes>', content: 'value<yes>', expected: 'value', squashes: 1},
  {name: 'disabled-tool-string', enabled: false, tag: '<yes>', content: 'value<yes>', expected: 'value<yes>', squashes: 1},
  {name: 'unmatched-tool-string', enabled: true, tag: '<yes>', content: 'value<no>', expected: 'value<no>', squashes: 0},
  {name: 'empty-tag-tool-string', enabled: true, tag: '', content: 'value<yes>', expected: 'value<yes>', squashes: 0},
  {name: 'enabled-tool-content-parts', enabled: true, tag: '<yes>', content: [
    {type: 'text', text: 'value<yes>'},
    {type: 'opaque', nested: {'key<yes>': ['<yes>x', 3, false]}},
  ], expected: [
    {type: 'text', text: 'value'},
    {type: 'opaque', nested: {'key<yes>': ['x', 3, false]}},
  ], squashes: 1},
];
const results = [];
for (const test of cases) {
  const input = [{role: 'tool', content: test.content, tool_call_id: 'call<yes>', signature: '<yes>signature'}];
  const data = JSON.parse(JSON.stringify({prompt: input}));
  const seen = [];
  const settings = {enabled: true, role: 'follow', conditional_enabled: test.enabled,
    conditional_tag: test.tag, separate_chat_history: false, parse_clewd: false};
  const ctx = vm.createContext({
    SPresetSettings: {ChatSquash: settings}, SPresetImports: {promptManager: {}},
    console: {log() {}, warn() {}},
    squashPrompts: prompts => {seen.push(JSON.parse(JSON.stringify(prompts))); return prompts;},
    postProcessOriginalMessages: () => {throw new Error('Unexpected disabled ChatSquash branch');},
  });
  vm.runInContext(handleCode + '\n' + conditionalCode + '\nglobalThis.handle = handleChatCompletionPromptReady;', ctx);
  ctx.handle(data);
  assert.equal(seen.length, test.squashes);
  assert.deepEqual(data.prompt, [{...input[0], content: test.expected}]);
  if (test.squashes) assert.deepEqual(seen[0], data.prompt);
  results.push({name: test.name, settings, input, afterConditional: data.prompt, downstreamSquashCalls: seen.length});
}
process.stdout.write(JSON.stringify({
  sourceCommit: '53bd585da14248ba10baaede7fc7ed0cebe1eeeb', sourceSha256: sha(source),
  extracted: [
    {name: 'handleChatCompletionPromptReady', sha256: sha(handleCode)},
    {name: 'consumeConditionalTag', sha256: sha(conditionalCode)},
  ],
  scope: 'Actual fixed conditional handler/function. Downstream squash is only a receiver-neutral observer of the already-mutated message array. No whole follow/tool-ID preservation equivalence claim.',
  passed: true, count: results.length, results,
}, null, 2) + '\n');
