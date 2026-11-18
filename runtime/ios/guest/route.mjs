// Runs on the already parsed just-bash tree, before its interpreter can perform
// an expansion, redirection, or command. It selects one backend for the request.
const builtins = new Set((': true false cd export unset exit local set break continue return eval shift getopts compgen complete compopt pushd popd dirs source . read mapfile readarray declare typeset readonly let command builtin shopt exec wait type hash help test [').split(' '));
const opaqueCommands = new Set(['source', '.', 'eval', 'alias', 'fc', 'trap', 'let', 'declare', 'typeset', 'local', 'read', 'mapfile', 'readarray', 'git']);

export function literalWord(word) {
  if (!word) return undefined;
  if (['Literal', 'SingleQuoted', 'Escaped'].includes(word.type)) return word.value;
  if (word.type !== 'Word' && word.type !== 'DoubleQuoted') return undefined;
  let result = '';
  for (const part of word.parts) {
    const value = literalWord(part);
    if (value === undefined) return undefined;
    result += value;
  }
  return result;
}

export function planScript(ast, { shellCommands, parse }) {
  const available = new Set([...shellCommands, ...builtins]);
  const functions = new Map(), activeCalls = new Set(), missing = new Set(), opaque = new Set();
  let scanOnly = false, unresolvedCommand = false;
  const constants = new Map(), dormantNames = new Set(), dormantSources = new Set();
  let node = false;
  const walk = (value, visit, inFunction = false) => {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) { for (const child of value) walk(child, visit, inFunction); return; }
    if (value.type === 'HereDoc' && value.quoted) return;
    if (visit(value, inFunction) === false) return;
    for (const child of Object.values(value)) walk(child, visit, inFunction || value.type === 'FunctionDef');
  };

  const nestedScript = source => {
    if (source === undefined) { opaque.add('dynamic shell source'); return; }
    try {
      const result = planScript(parse(source), { shellCommands, parse });
      for (const name of result.missing) missing.add(name);
      for (const reason of result.opaque) opaque.add(reason);
      node ||= result.node;
      unresolvedCommand ||= result.unresolvedCommand === true;
    } catch { opaque.add('unparsed nested source'); }
  };
  const executableWord = word => {
    dormantNames.delete(word);
    const literal = literalWord(word);
    if (literal !== undefined) return literal;
    const quoted = word?.type === 'Word' && word.parts.length === 1 ? word.parts[0] : undefined;
    const part = quoted?.type === 'DoubleQuoted' && quoted.parts.length === 1 ? quoted.parts[0] : undefined;
    if (part?.type === 'ParameterExpansion' && part.operation === null) return constants.get(part.parameter);
  };
  const target = (words, index) => {
    if (index < words.length) {
      if (scanOnly && literalWord(words[index]) === undefined) dormantNames.add(words[index]);
      inspectCommand(scanOnly ? literalWord(words[index]) : executableWord(words[index]), words.slice(index + 1), false);
    }
  };
  const optionTarget = (name, words, flags, valued) => {
    let i = 0;
    for (; i < words.length; i++) {
      const value = scanOnly ? literalWord(words[i]) : executableWord(words[i]);
      if (value === undefined) { if (!scanOnly) { unresolvedCommand = true; opaque.add(`dynamic ${name} options`); } return; }
      if (value === '--') { i++; break; }
      if (!value.startsWith('-') || value === '-') break;
      if (flags.has(value)) continue;
      if (valued.has(value)) { if (literalWord(words[++i]) === undefined) opaque.add(`dynamic ${name} option value`); continue; }
      if ([...valued].some(flag => flag.startsWith('--') ? value.startsWith(flag + '=') : value.startsWith(flag) && value.length > flag.length)) continue;
      if (!scanOnly) unresolvedCommand = true;
      opaque.add(`unproved ${name} options`); return;
    }
    return i;
  };
  const inspectCommand = (name, words, allowFunction = true) => {
    if (name === undefined || name === '') {
      if (!scanOnly) { unresolvedCommand = true; opaque.add('unresolved command name'); functions.clear(); constants.clear(); }
      return;
    }
    if (name.split('/').at(-1) === 'node') node = true;
    if (!scanOnly && !available.has(name) && !(allowFunction && functions.has(name))) missing.add(name);
    if (opaqueCommands.has(name)) opaque.add(name);
    if (!scanOnly && allowFunction && functions.has(name)) {
      if (activeCalls.has(name)) { opaque.add('recursive function'); return; }
      const body = functions.get(name);
      constants.clear(); // A shell function may write caller variables.
      activeCalls.add(name);
      inspect(body);
      activeCalls.delete(name);
      return;
    }
    if (!scanOnly && (opaqueCommands.has(name) || name === 'unset')) functions.clear();
    if (!scanOnly && (opaqueCommands.has(name) || ['unset', 'export', 'readonly', 'set', 'shift', 'getopts'].includes(name)
      || name === 'printf' && words.some(word => literalWord(word) === '-v'))) constants.clear();
    if (name === 'bash' || name === 'sh') {
      if (literalWord(words[0]) === '-c') {
        const source = scanOnly ? literalWord(words[1]) : executableWord(words[1]);
        if (scanOnly && source === undefined) dormantSources.add(words[1]);
        else {
          dormantSources.delete(words[1]);
          if (source === undefined) {
            unresolvedCommand = true;
            opaque.add('unresolved shell source');
          } else nestedScript(source);
        }
      }
      else if (literalWord(words[0]) !== '--help') opaque.add('shell file or stdin');
    } else if (name === 'env') {
      let i = optionTarget(name, words, new Set(['-i', '--ignore-environment']), new Set(['-u', '--unset', '-C', '--chdir']));
      if (i === undefined) return;
      while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(literalWord(words[i]) ?? '')) i++;
      target(words, i);
    } else if (name === 'command') {
      const values = words.map(literalWord);
      let i = 0;
      while (values[i]?.startsWith('-')) {
        if (values[i] === '--') { i++; break; }
        if (/^-[pVv]+$/.test(values[i])) {
          if (/[Vv]/.test(values[i])) return; // Describes a command without running it.
          i++; continue;
        }
        if (!scanOnly) unresolvedCommand = true;
        opaque.add('unproved command options'); return;
      }
      target(words, i);
    } else if (name === 'builtin') {
      target(words, literalWord(words[0]) === '--' ? 1 : 0);
    } else if (name === 'exec') {
      let i = 0;
      while (i < words.length) {
        const value = scanOnly ? literalWord(words[i]) : executableWord(words[i]);
        if (value === undefined) { if (!scanOnly) { unresolvedCommand = true; opaque.add('dynamic exec options'); } return; }
        if (value === '--') { i++; break; }
        if (value === '-a') { if (literalWord(words[++i]) === undefined) opaque.add('dynamic exec name'); i++; continue; }
        if (/^-[cl]+$/.test(value)) { i++; continue; }
        if (value.startsWith('-')) { if (!scanOnly) unresolvedCommand = true; opaque.add('unproved exec options'); return; }
        break;
      }
      target(words, i);
    } else if (name === 'timeout') {
      const i = optionTarget(name, words, new Set(['--preserve-status', '--foreground', '-v', '--verbose']), new Set(['-s', '--signal', '-k', '--kill-after']));
      if (i !== undefined) {
        if (literalWord(words[i]) === undefined) opaque.add('dynamic timeout duration');
        target(words, i + 1);
      }
    } else if (name === 'xargs') {
      const i = optionTarget(name, words, new Set(['-0', '--null', '-r', '--no-run-if-empty', '-t', '--verbose', '-x', '--exit']), new Set(['-n', '--max-args', '-P', '--max-procs', '-L', '--max-lines', '-I', '--replace', '-d', '--delimiter', '-E', '--eof']));
      if (words.some(word => /^-(?:I|i)|^--replace/.test(literalWord(word) ?? ''))) opaque.add('xargs replacement');
      if (i !== undefined) target(words, i);
    } else if (name === 'find') {
      for (let i = 0; i < words.length; i++) {
        const value = literalWord(words[i]);
        if (value === undefined) { opaque.add('dynamic find expression'); continue; }
        if (!['-exec', '-execdir', '-ok', '-okdir'].includes(value)) continue;
        const start = ++i;
        while (i < words.length && ![';', '+'].includes(literalWord(words[i]))) i++;
        target(words.slice(start, i), 0);
      }
    } else if (name === 'split' || name === 'sort') {
      const option = name === 'split' ? '--filter' : '--compress-program';
      for (let i = 0; i < words.length; i++) {
        const value = literalWord(words[i]);
        if (value === undefined) { opaque.add(`dynamic ${name} options`); continue; }
        if (value !== option && !value.startsWith(option + '=')) continue;
        opaque.add(`${name} external program`);
        const code = value === option ? literalWord(words[i + 1]) : value.slice(option.length + 1);
        if (name === 'split') nestedScript(code);
        else if (code?.split('/').at(-1) === 'node') node = true;
      }
    } else if (name === 'printf' && words.some(word => literalWord(word) === '-v')) {
      opaque.add('printf variable target');
    } else if (name === 'set' && words.some(word => /^-[a-z]*x/.test(literalWord(word) ?? ''))) {
      opaque.add('shell trace expansion');
    } else if (name === 'awk' || name === 'sed') {
      // Embedded languages may launch commands beyond this AST. They can run
      // wholly in Linux, but cannot be combined with the engine's Node Worker.
      opaque.add(`${name} embedded language`);
    }
  };
  // Scan every body/branch for Node and opaque executable text, even when a
  // function is never called. This pass grants no function bindings.
  scanOnly = true;
  walk(ast, value => {
    if (value.type === 'SimpleCommand' && value.name) {
      if (literalWord(value.name) === undefined) dormantNames.add(value.name);
      inspectCommand(literalWord(value.name), value.args);
    }
    if (value.type === 'ArithCommandSubst') nestedScript(value.command);
  });
  scanOnly = false;
  const inspect = tree => walk(tree, value => {
    if (value.type === 'FunctionDef') {
      // Non-dominating declarations may replace an earlier binding, but must
      // never grant a binding. Their bodies were covered by the Node scan.
      functions.delete(value.name);
      return false;
    }
    if (value.type === 'SimpleCommand' && value.name) {
      if (value.assignments?.length) constants.clear();
      inspectCommand(executableWord(value.name), value.args);
    }
    if (value.type === 'Assignment' || value.type?.startsWith('Arith')
      || value.type === 'ParameterExpansion' && value.operation !== null) constants.clear();
    if (value.type === 'Statement' && value.deferredError) opaque.add('deferred syntax error');
    if (value.type === 'ArithCommandSubst') nestedScript(value.command);
    if (['ArithBracedExpansion', 'ArithDynamicBase', 'ArithDynamicNumber', 'ArithVariable', 'ArithArrayElement', 'ArithDynamicElement', 'ArithDynamicAssignment', 'Transform'].includes(value.type)) opaque.add('dynamic arithmetic or parameter code');
    if (value.type === 'Assignment' && (value.name.includes('[') || ['BASH_ENV', 'ENV', 'PS4', 'PS1', 'PROMPT_COMMAND'].includes(value.name))) opaque.add('shell variable may contain executable text');
  });
  for (const statement of ast.statements) {
    const pipeline = statement.pipelines?.[0];
    const command = pipeline?.commands?.[0];
    const definite = !statement.background && !statement.deferredError && !statement.operators?.length
      && statement.pipelines?.length === 1 && pipeline.commands.length === 1
      && !pipeline.negated && command.type === 'FunctionDef'
      && !command.redirections?.length;
    if (definite) functions.set(command.name, command.body);
    else {
      const single = !statement.background && !statement.deferredError && !statement.operators?.length
        && statement.pipelines?.length === 1 && pipeline.commands.length === 1 && !pipeline.negated;
      const assignments = command?.type === 'SimpleCommand' && !command.name && !command.redirections?.length ? command.assignments : undefined;
      if (single && assignments?.length && assignments.every(row => !row.append && !row.array
        && /^[A-Za-z_][A-Za-z0-9_]*$/.test(row.name) && literalWord(row.value) !== undefined)) {
        for (const row of assignments) {
          if (['BASH_ENV', 'ENV', 'PS4', 'PS1', 'PROMPT_COMMAND'].includes(row.name)) opaque.add('shell variable may contain executable text');
          constants.set(row.name, literalWord(row.value));
        }
      } else {
        // Never merge bindings from conditional, loop, pipeline or subshell
        // execution. A possible write invalidates previous constant knowledge.
        if (!single || command?.type !== 'SimpleCommand') constants.clear();
        inspect(statement);
      }
    }

  }
  if (dormantSources.size) opaque.add('unresolved shell source in deferred body');
  if (dormantNames.size) opaque.add('unresolved executable in deferred body');
  // This transform is installed only when a trusted Linux owner is present.
  // Keep one Linux filesystem/PATH for ordinary scripts, even when every
  // command also exists virtually. Dynamic code stays wholly inside Linux;
  // only statically identified, self-contained Node Worker scripts stay virtual.
  return Object.freeze({
    route: node ? missing.size || unresolvedCommand || opaque.size ? 'unsupported' : 'virtual' : 'guest',
    missing: [...missing].sort(), node, unresolvedCommand, opaque: [...opaque].sort(),
  });
}

export function routingTransform(argv, options) {
  // For -c, inspect the complete body before expansion or any user effects.
  // File/stdin invocations go straight to Linux at the outer parse: never read
  // a mutable script in the virtual filesystem just to decide where to run it.
  const shell = argv[0] === 'bash' || argv[0] === 'sh';
  const inline = argv[1] === '-c' && argv.length >= 3;
  let parses = 0, decision;
  return {
    get decision() { return decision; },
    plugin: { name: 'ios-guest-route', transform({ ast, metadata }) {
      if (!shell || inline && parses++ !== 1) return { ast, metadata };
      decision = inline ? planScript(ast, options) : Object.freeze({
        route: 'guest', missing: [], node: false, unresolvedCommand: false,
        opaque: ['shell file or stdin runs only in Linux'],
      });
      // An arbitrary exception is swallowed by just-bash's command dispatcher.
      // An empty AST makes the interpreter perform no user effects; the worker
      // reports the decision instead of publishing this placeholder exit code.
      return { ast: decision.route === 'virtual' ? ast : { type: 'Script', statements: [] }, metadata };
    } },
  };
}
