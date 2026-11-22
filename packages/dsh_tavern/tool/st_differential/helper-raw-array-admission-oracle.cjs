// Actual fixed Helper raw builder + ST message/budget classes. The only token
// adapter returns the measured native cost for the one plain message, and
// throws if an array unexpectedly reaches it. No image token value is guessed.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const { stripTypeScriptTypes } = require('node:module');
const root = path.resolve(process.argv[2]);
// These estimates were measured by the unchanged native default counter in
// the separately frozen helper-array-budget audit (native JSON SHA below).
const measuredPlainCost = 4, measuredNativePartsCost = 36;
const plain = { role: 'user', content: 'Q' };
const image = 'data:image/png;base64,AQ==';
const cases = [
  {name: 'array-before-plain-reserve', kind: 'array', context: 7},
  {name: 'array-at-plain-reserve', kind: 'array', context: 8},
  {name: 'plain-at-plain-reserve', kind: 'plain', context: 8},
  {name: 'empty-array-at-plain-reserve', kind: 'emptyArray', context: 8},
  {name: 'failed-array-at-plain-reserve', kind: 'failedArray', context: 8},
  {name: 'array-before-old-threshold', kind: 'array', context: 43},
  {name: 'array-at-old-threshold', kind: 'array', context: 44},
  {name: 'array-without-explicit-input-slot', kind: 'array', context: 8, explicitInput: false},
].map(test => ({...test, explicitInput: test.explicitInput !== false, maxResponse: 1}));
const pins = {
  utils: ['research/helper/src/function/generate/utils.ts', '9aace591938c207d8c3e81a5619ed39ccc6a1d53a1d3e84190243ca6c69ca3ff'],
  raw: ['research/helper/src/function/generate/generateRaw.ts', '2bcb8b91a0657b6788c32899ec0b8256749cf00c83d1f4a22d7d1e3fca694a57'],
  st: ['research/st/public/scripts/openai.js', '0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604'],
  pm: ['research/st/PromptManager.js', 'b0054793b763d92b265f5f487645b68b4eca0867cb5ad6b5deb1034004b2c1cc'],
};
const texts = {}, extracted = [];
for (const [key, [file, sha]] of Object.entries(pins)) {
  const bytes = fs.readFileSync(path.join(root, file));
  assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'), sha, file);
  texts[key] = bytes.toString('utf8');
}
function block(key, marker) {
  const text = texts[key], start = text.indexOf(marker);
  assert.ok(start >= 0, marker);
  const last = /^}\s*$/m.exec(text.slice(start));
  assert.ok(last, marker);
  const original = text.slice(start, start + last.index + last[0].length);
  extracted.push({ file: pins[key][0], marker, sha256: crypto.createHash('sha256').update(original).digest('hex') });
  return stripTypeScriptTypes(original.replace(/^export /, ''), { mode: 'strip' });
}
const code = [
  block('utils', 'export async function convertFileToBase64('),
  block('utils', 'export async function processImageArrayDirectly('),
  block('utils', 'export function isPromptFiltered('),
  block('raw', 'async function convertSystemPromptsToCollection('),
  block('raw', 'async function processChatHistoryAndInject('),
  block('raw', 'export async function handleCustomPath('),
  block('st', 'class IdentifierNotFoundError '),
  block('st', 'class TokenBudgetExceededError '),
  block('st', 'class InvalidCharacterNameError '),
  block('st', 'class Message {'),
  block('st', 'class MessageCollection {'),
  block('st', 'export class ChatCompletion {'),
  block('pm', 'class Prompt {'),
  block('pm', 'export class PromptCollection {'),
  `
  for (const method of ['setTokenBudget','reserveBudget','add','freeBudget']) {
    const original = ChatCompletion.prototype[method];
    ChatCompletion.prototype[method] = function(...args) {
      observation.completion = this;
      const before = this.tokenBudget;
      const subject = args[0];
      const tokens = typeof subject === 'number' ? subject : subject?.getTokens?.();
      try {
        const result = original.apply(this, args);
        observation.trace.push({ method, before, after: this.tokenBudget, tokens, identifier: subject?.identifier ?? null });
        return result;
      } catch (error) {
        observation.trace.push({ method, before, after: this.tokenBudget, tokens, identifier: subject?.identifier ?? null, error: error.name });
        throw error;
      }
    };
  }
  const create = Message.createAsync;
  Message.createAsync = async function(...args) {
    const message = await create.apply(this,args);
    observation.trace.push({ method: 'Message.createAsync', kind: Array.isArray(message.content) ? 'parts' : typeof message.content, tokens: message.tokens, identifier: message.identifier });
    return message;
  };
  Object.assign(globalThis, { handleCustomPath, processImageArrayDirectly });
  `,
].join('\n');
async function run(test) {
  const observation = { trace: [], counterCalls: [], completion: null };
  const ctx = {
    console: { log() {}, warn() {}, error() {} }, observation,
    DEFAULT_ORDER: 100, default_order: ['user_input'], placeholder_prompt_default_order: ['user_input'],
    power_user: {}, persona_description_positions: { IN_PROMPT: 0 },
    oai_settings: { openai_max_context: test.context, openai_max_tokens: test.maxResponse, squash_system_messages: false, inline_image_quality: 'low' },
    tokenHandler: { countAsync: async message => {
      assert.equal(message.role, plain.role);
      assert.equal(message.content, plain.content);
      observation.counterCalls.push(JSON.parse(JSON.stringify(message)));
      return measuredPlainCost;
    } },
    event_types: { CHAT_COMPLETION_PROMPT_READY: 'ready' },
    eventSource: { emit: name => observation.trace.push({ method: 'emit', name }) },
    isDataURL: value => value.startsWith('data:'),
    fetch: async () => { throw new Error('Controlled download failure'); },
  };
  vm.createContext(ctx); vm.runInContext(code, ctx);
  const config = { order: test.explicitInput ? ['user_input'] : [], overrides: { chat_history: [], with_depth_entries: false } };
  if (test.kind !== 'plain') {
    config.image = test.kind === 'emptyArray' ? [] : [test.kind === 'failedArray' ? 'https://fixture.invalid/failure.png' : image];
    // Actual inputProcessor only prepares nonempty arrays before handleCustomPath.
    if (config.image.length) config.processedImageArray = await ctx.processImageArrayDirectly('Q', config.image);
  }
  const base = { characterInfo: {}, worldInfo: {}, chatContext: { oaiMessages: [], oaiMessageExamples: [] } };
  let prompt, failure;
  try { prompt = (await ctx.handleCustomPath(base, config, 'Q')).prompt; }
  catch (error) { failure = { name: error.name, message: error.message }; }
  const arrayPiece = test.explicitInput && ['array', 'failedArray'].includes(test.kind);
  assert.equal(observation.counterCalls.length, arrayPiece ? 1 : 2, test.name);
  const expectedFailure = !arrayPiece || test.context < 8;
  assert.equal(failure?.name ?? null, expectedFailure ? 'TokenBudgetExceeded' : null, test.name);
  assert.equal(observation.trace.find(row => row.method === 'add').tokens, arrayPiece ? 0 : measuredPlainCost, test.name);
  if (!failure) {
    assert.deepEqual(JSON.parse(JSON.stringify(prompt)), [{role: 'user', content: [
      {type: 'text', text: 'Q'},
      ...(test.kind === 'failedArray' ? [] : [{type: 'image_url', image_url: {url: image, detail: 'low'}}]),
    ]}]);
  }
  return {
    ...test, arrayPiece, trace: observation.trace, counterCalls: observation.counterCalls,
    remainingBudget: observation.completion.tokenBudget,
    failure: failure ?? null, wireMessages: prompt ? JSON.parse(JSON.stringify(prompt)) : null,
  };
}
(async () => {
  const results = [];
  for (const test of cases) results.push(await run(test));
  process.stdout.write(JSON.stringify({
    passed: true, count: results.length, pins, extracted,
    measuredPlainCost, measuredNativePartsCost,
    measurementOriginSha256: 'e4a3e9ae7ffc8c766af966365660af8ff8a76ec3179bc2580f66fd361465bd1a',
    scope: 'Actual fixed Helper raw builder/array conversion and ST message/budget classes. Receiver-preserving method wrappers only observe. The plain token callback uses the separately measured native default estimate; arrays never invoke it. History is explicitly filtered. Network failure and empty media metadata are controlled; no full browser, exact tokenizer or image billing claim.',
    results,
  }, null, 2) + '\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
