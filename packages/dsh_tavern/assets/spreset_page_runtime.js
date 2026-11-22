/* Native SPreset App page evaluator. Independent protocol implementation.
 * Source contract: starowo/starowo.github.io@53bd585da14248ba10baaede7fc7ed0cebe1eeeb.
 * Install once in the SAME persistent page as the user's script and localStorage.
 * It never loads regex_bind/inject.js or any other third-party source.
 */
(() => {
  const sessions = new Map();
  const definitions = new Map();
  const evaluations = new Map();
  const registrations = new Map();
  let activeIdentifiers = new Set();
  // This independent public surface mirrors ST's registration receiver. User
  // callbacks must see a registration instance, not the returned definition
  // object or the page global. Private storage leaves own script fields free.
  class ToolDefinition {
    #values;
    constructor(name, displayName, description, parameters, action, formatMessage, shouldRegister, stealth) {
      this.#values = {name, displayName, description, parameters, action, formatMessage, shouldRegister, stealth};
    }
    toFunctionOpenAI() {
      const {name, description, parameters} = this.#values;
      return {type:'function', function:{name,description,parameters}, toString() {
        const item = this.function;
        return '<div><b>' + item.name + '</b></div><div><small>' + item.description +
          '</small></div><pre class="justifyLeft wordBreakAll"><code class="flex padding5">' +
          JSON.stringify(item.parameters, null, 2) + '</code></pre><hr>';
      }};
    }
    async invoke(parameters) { return await Reflect.apply(this.#values.action, this, [parameters]); }
    async formatMessage(parameters) {
      const fields = this.#values;
      return typeof fields.formatMessage === 'function'
        ? await Reflect.apply(fields.formatMessage, this, [parameters])
        : `Invoking tool: ${fields.displayName || fields.name}`;
    }
    async shouldRegister() {
      return typeof this.#values.shouldRegister === 'function'
        ? await Reflect.apply(this.#values.shouldRegister, this, []) : true;
    }
    get displayName() { return this.#values.displayName; }
    get stealth() { return this.#values.stealth; }
  }
  const copy = value => value === undefined ? null : JSON.parse(JSON.stringify(value));
  const trimExpression = source => String(source ?? '').trim().replace(/;\s*$/, '');
  function compile(source, logger) {
    const value = Function('console', `"use strict"; return (\n${trimExpression(source)}\n);`)(logger);
    if (typeof value !== 'function') throw new TypeError('SPreset script must evaluate to a function.');
    return value;
  }
  function compileSync(source, logger) {
    // ChatSquash uses direct eval, so statement completion and declaration
    // syntax differ from the parenthesized expression compilers elsewhere.
    const value = Function('console', 'source', 'return eval(source);')(logger, String(source ?? ''));
    if (typeof value !== 'function') throw new TypeError('SPreset script must evaluate to a function.');
    return value;
  }
  function loggerFor(sink) {
    const logger = Object.create(console);
    for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
      logger[level] = (...values) => {
        const capture = sink.capture;
        if (capture.enabled) {
          const budget = {nodes: 0, truncated: Math.max(0, values.length - 8)};
          const formatted = values.slice(0, 8).map(value => {
            const saved = logValue(value, budget);
            return typeof saved === 'string' ? saved : JSON.stringify(saved);
          });
          let event = {level, stage: sink.request.stage, values: formatted};
          let encoded = JSON.stringify(event);
          if (encoded.length > 65536) {
            budget.truncated++;
            event = {level, stage: sink.request.stage, truncated: true, preview: encoded.slice(0, 16384)};
            encoded = JSON.stringify(event);
          }
          capture.truncatedValues += budget.truncated;
          while (capture.logs.length && (capture.logs.length >= 500 || capture.chars + encoded.length > 512 * 1024)) {
            capture.chars -= JSON.stringify(capture.logs.shift()).length;
            capture.dropped++;
          }
          capture.logs.push(event);
          capture.chars += encoded.length;
        }
        console[level](...values);
      };
    }
    return logger;
  }
  // Snapshot a bounded number of own data properties. Do not invoke getters
  // or serialize an unbounded object merely to discover that it is too large.
  function logValue(value, budget, depth = 0, seen = new Set()) {
    if (++budget.nodes > 500 || depth > 6) {
      budget.truncated++;
      return '[TRUNCATED]';
    }
    if (typeof value === 'string') {
      if (value.length <= 8192) return value;
      budget.truncated++;
      return `[OMITTED string: ${value.length} chars]`;
    }
    if (value === undefined) return '[undefined]';
    if (typeof value === 'function' || typeof value === 'symbol' || typeof value === 'bigint') {
      const text = typeof value === 'function' ? Function.prototype.toString.call(value) : String(value);
      if (text.length <= 8192) return text;
      budget.truncated++;
      return `[OMITTED string: ${text.length} chars]`;
    }
    if (value === null || typeof value !== 'object') return value;
    if (seen.has(value)) return '[Circular]';
    seen.add(value);
    let result;
    try {
      const own = key => {
        const descriptor = Object.getOwnPropertyDescriptor(value, key);
        return descriptor && 'value' in descriptor ? logValue(descriptor.value, budget, depth + 1, seen) : '[Accessor]';
      };
      if (Array.isArray(value)) {
        // Reuse Array.from's ToLength semantics for the count as well, with
        // the original one property read and one numeric conversion.
        const length = Math.min(Number.MAX_SAFE_INTEGER, Math.max(0, Math.trunc(+value.length) || 0));
        budget.truncated += Math.max(0, length - 50);
        result = Array.from({length: Math.min(length, 50)}, (_, index) => own(String(index)));
      } else {
        const keys = Object.keys(value);
        budget.truncated += Math.max(0, keys.length - 50);
        const entries = [];
        for (const key of keys.slice(0, 50)) {
          // Omit the entire slot before reading its value or constructing a
          // snapshot. Truncating a key could collide with another real key.
          if (key.length > 8192) {
            budget.truncated++;
            continue;
          }
          entries.push([key, own(key)]);
        }
        result = Object.fromEntries(entries);
      }
    } catch { result = '[UNSERIALIZABLE]'; }
    seen.delete(value);
    return result;
  }
  const check = signal => {
    if (signal?.aborted || signal?.isCancelled) throw new Error('SPreset evaluation cancelled.');
  };
  function describe(receiver) {
    return {...receiver.toFunctionOpenAI().function, displayName:receiver.displayName, stealth:receiver.stealth,
      hasAction:true, hasFormatMessage:true};
  }
  function retainDefinition(code, identifier, uuid, sink) {
    const saved = uuid ? definitions.get(uuid) : null;
    let retained = saved?.code === code ? saved : null;
    if (!retained) {
      if (!code || !code.trim()) throw new TypeError('ToolBindings code is empty.');
      const key = `runtime:${identifier || ''}:${code}`;
      const cached = evaluations.get(key);
      if (cached && cached.expires > Date.now()) retained = cached.retained;
      else {
        if (cached) evaluations.delete(key);
        const definition = Function('console', code)(loggerFor(sink));
        if (!definition || typeof definition !== 'object') throw new TypeError('ToolBindings must return an object.');
        const missing = ['name', 'description', 'parameters', 'action'].filter(key => !(key in definition));
        if (missing.length) throw new TypeError(`ToolBindings missing ${missing.join(', ')}.`);
        if (typeof definition.name !== 'string' || !definition.name.trim()) throw new TypeError('ToolBindings name must be nonempty text.');
        if (typeof definition.description !== 'string') throw new TypeError('ToolBindings description must be text.');
        if (typeof definition.parameters !== 'object') throw new TypeError('ToolBindings parameters must be an object.');
        if (typeof definition.action !== 'function') throw new TypeError('ToolBindings action must be a function.');
        retained = { definition, code, sink };
        evaluations.set(key, { expires: Date.now() + 1000, retained });
        if (evaluations.size > 512) evaluations.delete(evaluations.keys().next().value);
      }
    }
    if (uuid) definitions.set(uuid, retained);
    return retained;
  }
  async function evaluate(request, signal) {
    check(signal);
    const args = copy(request.arguments ?? []);
    const capture = {enabled: request.captureLogs === true, logs: [], chars: 0, dropped: 0, truncatedValues: 0};
    const sink = { request, capture };
    const logger = loggerFor(sink);
    let value;
    if (request.kind === 'validateFunctionExpression') {
      compile(request.source, logger);
      value = true;
    } else if (request.kind === 'toolRegistry') {
      const input = args[0] ?? {};
      activeIdentifiers = new Set(input.activeIdentifiers ?? []);
      const desired = new Map();
      const used = new Set();
      const diagnostics = [];
      for (const binding of input.bindings ?? []) {
        const { identifier, code, uuid } = binding;
        try {
          const retained = retainDefinition(code, identifier, uuid, sink);
          if (uuid) used.add(uuid);
          const name = retained.definition.name;
          if (desired.has(name)) {
            diagnostics.push({ identifier, message: `Duplicate tool name: ${name}` });
            continue;
          }
          desired.set(name, { retained, identifier, uuid, code });
        } catch (error) {
          diagnostics.push({ identifier, message: error.message || String(error) });
        }
      }
      for (const uuid of definitions.keys()) if (!used.has(uuid)) definitions.delete(uuid);
      for (const [name, registered] of registrations) {
        if (!desired.has(name) || desired.get(name).uuid !== registered.uuid) registrations.delete(name);
      }
      for (const [name, current] of desired) {
        // The original registry does not replace an existing same-name,
        // same-UUID registration, even when its evaluated code changed.
        if (!registrations.has(name)) {
          const definition = current.retained.definition;
          const receiver = new ToolDefinition(name, definition.displayName || name, definition.description,
            definition.parameters, definition.action, definition.formatMessage,
            () => activeIdentifiers.has(current.identifier), definition.stealth ?? false);
          registrations.set(name, {...current, receiver});
        }
      }
      const tools = [];
      for (const [name, registered] of registrations) {
        if (!await registered.receiver.shouldRegister()) continue;
        const sessionId = `tool:${name}`;
        sessions.set(`${request.generationId}:${sessionId}`, registered);
        tools.push({ identifier: registered.identifier, code: registered.code,
          sessionId, definition: describe(registered.receiver) });
      }
      value = { tools, diagnostics };
    } else if (request.kind === 'toolDefinition') {
      if (!request.cacheKey) throw new TypeError('ToolBindings requires a stable cacheKey.');
      const retained = retainDefinition(String(request.source ?? ''), request.identifier, request.cacheKey, sink);
      retained.sink.request = request;
      retained.sink.capture = capture;
      const { definition } = retained;
      retained.receiver ??= new ToolDefinition(definition.name,definition.displayName||definition.name,
        definition.description,definition.parameters,definition.action,definition.formatMessage,()=>true,definition.stealth??false);
      sessions.set(request.sessionId, {retained,receiver:retained.receiver});
      value = describe(retained.receiver);
    } else if (request.kind === 'toolAction' || request.kind === 'toolFormatMessage') {
      const session = sessions.get(request.sessionId);
      const retained = session?.retained ?? (session?.definition ? session : definitions.get(request.cacheKey));
      if (!retained) throw new Error('The retained SPreset tool definition is unavailable.');
      retained.sink.request = request;
      retained.sink.capture = capture;
      const receiver = session?.receiver ?? retained.receiver;
      if (receiver) {
        value = request.kind === 'toolAction'
          ? await receiver.invoke(...args) : await receiver.formatMessage(...args);
      } else {
        const { definition } = retained;
        const callback = request.kind === 'toolAction' ? definition.action : definition.formatMessage;
        if (typeof callback !== 'function') throw new TypeError('The retained tool callback is unavailable.');
        value = await callback(...args);
      }
    } else if (request.kind === 'functionExpression' || request.kind === 'syncFunctionExpression') {
      let session = sessions.get(request.sessionId);
      if (!session || request.reset || session.source !== request.source) {
        session = { source: request.source,
          callback: request.kind === 'syncFunctionExpression' ? compileSync(request.source, logger) : compile(request.source, logger),
          state: {}, sink };
        sessions.set(request.sessionId, session);
      }
      session.sink.request = request;
      session.sink.capture = capture;
      if (request.stage === 'OutputPreprocessing') {
        // JS state can contain functions, Maps, cycles or page objects. Keep it
        // in this realm rather than pretending it can round-trip through JSON.
        args[0].state = session.state;
        value = await session.callback(...args);
        if (value && typeof value === 'object' && value.state !== undefined) session.state = value.state;
        if (value && typeof value === 'object' && !Array.isArray(value)) {
          const key = ['output', 'emit', 'text', 'content'].find(key => Object.hasOwn(value, key));
          if (key !== undefined) value = { output: value[key] == null ? '' : String(value[key]), hold: value.hold == null ? '' : String(value.hold) };
        }
        delete args[0].state;
      } else {
        value = request.kind === 'syncFunctionExpression' ? session.callback(...args) : await session.callback(...args);
      }
    } else {
      throw new TypeError(`Unknown SPreset evaluation kind: ${request.kind}`);
    }
    // A completed action may already have committed effects even if a late
    // cancellation arrived. The App must keep its real bridge receipt facts;
    // this evaluator does not invent committed=false for arbitrary JS.
    return { requestId: request.requestId, value: copy(value), isUndefined: value === undefined,
      arguments: copy(args), scriptLogs: capture.logs, scriptLogsDropped: capture.dropped,
      scriptLogValuesTruncated: capture.truncatedValues };
  }
  globalThis.DshSPresetPageRuntime = Object.freeze({
    evaluate,
    releaseSession(sessionId) { sessions.delete(sessionId); },
    // Call when the active preset/page is replaced, after settling old host
    // RPCs. This does not stop already executing JS. Keep closures on normal
    // generation completion; release only that generation's session entries.
    resetPreset() { sessions.clear(); definitions.clear(); registrations.clear(); activeIdentifiers.clear(); },
  });
})();
