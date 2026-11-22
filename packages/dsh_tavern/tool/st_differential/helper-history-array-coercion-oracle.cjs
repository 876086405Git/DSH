// Actual fixed Helper input/raw builders and ST substituteParams/Message classes.
// The real substituteParams performs String coercion before the observed modern
// or legacy macro-backend boundary; no identity substituteParams replaces it.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const crypto = require('node:crypto'), assert = require('node:assert/strict');
const { stripTypeScriptTypes } = require('node:module');
const root = path.resolve(process.argv[2]);
const image = 'data:image/png;base64,AQ==';
const pins = {
  utils: ['research/helper/src/function/generate/utils.ts', '9aace591938c207d8c3e81a5619ed39ccc6a1d53a1d3e84190243ca6c69ca3ff'],
  raw: ['research/helper/src/function/generate/generateRaw.ts', '2bcb8b91a0657b6788c32899ec0b8256749cf00c83d1f4a22d7d1e3fca694a57'],
  st: ['research/st/public/scripts/openai.js', '0b77c30282825540265d5a09e681e5ccacf6760b05111ec880ffe237a9250604'],
  pm: ['research/st/PromptManager.js', 'b0054793b763d92b265f5f487645b68b4eca0867cb5ad6b5deb1034004b2c1cc'],
  script: ['research/st/public/script.js', '955c603d0bad84bac5a716f0818d85c2543e44d4c43878e0d63ef1e55ca91855'],
  input: ['research/helper/src/function/generate/inputProcessor.ts', 'db994f43c5672c6264bd6da4ebc72d0533d9fcdab6ea54d3d0611cc44a997b7a'],
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
  block('utils', 'export function processUserInput('),
  block('input', 'export function processInitialUserInput('),
  block('input', 'export async function processUserInputWithImages('),
  block('script', 'export function substituteParams('),
  block('raw', 'async function populationInjectionPrompts('),
  block('raw', 'async function filteredGetExtensionPrompt('),
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
  Object.assign(globalThis, { handleCustomPath, processUserInputWithImages });
  `,
].join('\n');
async function run(test) {
  const observation = { trace: [], counterCalls: [], completion: null };
  const macroInputs = [], warnings = [];
  const macro = (value, engine) => {
    macroInputs.push({engine, content: value});
    observation.trace.push({method: 'macroBackend', engine, content: value});
    return value;
  };
  const ctx = {
    console: { log() {}, warn: (...args) => warnings.push(args[0]), error() {} }, observation,
    DEFAULT_ORDER: 100, default_order: ['user_input'], placeholder_prompt_default_order: ['user_input'],
    power_user: {experimental_macro_engine: test.modern}, persona_description_positions: { IN_PROMPT: 0 },
    oai_settings: { openai_max_context: 1024, openai_max_tokens: 1, squash_system_messages: false,
      inline_image_quality: 'low', new_chat_prompt: '', send_if_empty: '' },
    tokenHandler: { countAsync: async message => {
      assert.equal(typeof message.content, 'string');
      observation.counterCalls.push(JSON.parse(JSON.stringify(message)));
      return message.content.length; // Explicit control, not a tokenizer estimate.
    } },
    event_types: { CHAT_COMPLETION_PROMPT_READY: 'ready' },
    eventSource: { emit: name => observation.trace.push({ method: 'emit', name }) },
    isDataURL: value => value.startsWith('data:'),
    fetch: async () => { throw new Error('Controlled download failure'); },
    getRegexedString: value => value, regex_placement: {USER_INPUT: 1},
    substituteParamsLegacy: value => macro(value, 'legacy'), MacroEnvBuilder: {buildFromRawEnv: value => value},
    MacroEngine: {evaluate: value => macro(value, 'modern')},
    extension_prompts: {}, _: {get: (object, key, fallback) => object[key] ?? fallback},
    extension_prompt_roles: {SYSTEM: 0, USER: 1, ASSISTANT: 2},
    extension_prompt_types: {IN_PROMPT: 0, IN_CHAT: 1}, MAX_INJECTION_DEPTH: 10000,
    isImageInliningSupported: () => test.imageGate,
    setupChatCompletionPromptManager: () => null,
  };
  vm.createContext(ctx); vm.runInContext(code, ctx);
  const inputImage = test.kind === 'failedArray' ? ['https://fixture.invalid/failure.png']
    : test.kind === 'failedSingle' ? 'https://fixture.invalid/failure.png'
    : test.kind === 'array' ? [image]
    : test.kind === 'emptyArray' ? [] : undefined;
  const input = test.inputPresent === false ? undefined : test.input;
  const prepared = await ctx.processUserInputWithImages(input, false, inputImage);
  const config = {order: [test.explicitInput ? 'user_input' : 'chat_history'],
    overrides: {with_depth_entries: false, ...(test.filteredHistory ? {chat_history: []} : {})}, image: inputImage,
    processedImageArray: prepared.processedImageArray};
  const base = {characterInfo: {}, worldInfo: {}, chatContext: {
    oaiMessages: test.seedHistory ? [{role: 'user', content: 'H'}] : [], oaiMessageExamples: []}};
  const prompt = (await ctx.handleCustomPath(base, config, prepared.processedUserInput)).prompt;
  const wire = JSON.parse(JSON.stringify(prompt));
  const array = ['array', 'failedArray'].includes(test.kind);
  const coerced = array && !test.explicitInput && !test.filteredHistory;
  const text = test.input ?? '';
  const expectedContent = !array || test.filteredHistory ? text : test.explicitInput
    ? [{type: 'text', text}, ...(test.kind === 'failedArray' ? [] : [{type: 'image_url', image_url: {url: image, detail: 'low'}}])]
    : test.kind === 'failedArray' ? '[object Object]' : '[object Object],[object Object]';
  assert.deepEqual(wire, [...(test.seedHistory ? [{role: 'user', content: 'H'}] : []), {role: 'user', content: expectedContent}]);
  assert.equal(warnings.filter(value => value === 'substituteParams: content will be coerced to string').length, coerced ? 1 : 0);
  assert.ok(macroInputs.every(value => typeof value.content === 'string'));
  assert.ok(macroInputs.every(value => value.engine === (test.modern ? 'modern' : 'legacy')));
  if (coerced) {
    const at = observation.trace.findIndex(row => row.method === 'macroBackend' && row.content === expectedContent);
    const createAt = observation.trace.findLastIndex(row => row.method === 'Message.createAsync' && row.identifier.startsWith('chat_history-'));
    assert.ok(at >= 0 && createAt > at, 'Real coercion/macro dispatch must precede history Message token counting.');
    assert.equal(macroInputs.at(-1).content, expectedContent);
  }
  return {...test, wireMessages: wire, macroInputs, warnings, counterCalls: observation.counterCalls, trace: observation.trace};
}
(async () => {
  const results = [];
  if (process.argv[3] === '--media-off-control') {
    for (const modern of [false, true]) {
      results.push(await run({modern, kind: 'array', explicitInput: false, imageGate: false, input: 'Q', inputPresent: true, filteredHistory: false, seedHistory: true}));
    }
  } else {
  for (const modern of [false, true]) {
    for (const kind of ['plain', 'array', 'failedArray', 'emptyArray', 'failedSingle']) {
      for (const explicitInput of [false, true]) {
        results.push(await run({modern, kind, explicitInput, imageGate: true, input: 'Q', inputPresent: true, filteredHistory: false}));
      }
    }
    results.push(await run({modern, kind: 'array', explicitInput: false, imageGate: true, input: 'Q', inputPresent: true, filteredHistory: true}));
    for (const inputPresent of [false, true]) {
      results.push(await run({modern, kind: 'array', explicitInput: false, imageGate: true, input: '', inputPresent, filteredHistory: false}));
    }
  }
  }
  process.stdout.write(JSON.stringify({passed: true, count: results.length, pins, extracted,
    scope: 'Actual fixed Helper input/image/raw/history functions and ST substituteParams/Message/collection classes. Empty WI/injection/name state, observed identity macro backends and regex identity, image capability and network are explicit boundaries. The actual substituteParams owns the coercion and engine dispatch; actual native variable-macro side effects are tested separately. String coercion executes before both macro evaluator branches; no full extension/browser or exact token claim.',
    results}, null, 2) + '\n');
})().catch(error => {console.error(error);process.exitCode = 1;});
