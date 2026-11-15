"""Exact iOS-only guest additions."""
FILES = ('runtime/ios/guest/preload-selector.cjs', 'runtime/ios/guest/overrides.mjs', 'runtime/ios/guest/bootstrap.mjs', 'runtime/ios/guest/suspended.mjs', 'runtime/ios/guest/native-channel.mjs', 'runtime/ios/guest/channel.mjs', 'runtime/ios/guest/paths.mjs', 'runtime/ios/guest/provider.mjs', 'runtime/ios/guest/route.mjs', 'runtime/ios/guest/file-paths.mjs', 'runtime/ios/guest/delivery.mjs', 'runtime/ios/guest/metadata.mjs', 'runtime/ios/guest/cleanup-budget.mjs', 'runtime/ios/guest/virtual-filesystem.mjs')
EDITS = {'runtime/ohos/process/index.mjs': (('  get temporaryRoot() { return this.backend.temporaryRoot; }',
                                     '  get temporaryRoot() { return this.backend.temporaryRoot; }\n'
                                     '  isHostPath(path) { return this.backend.roots.some(root => path === root || '
                                     'path.startsWith(root + "/")); }'),
                                    ('  get temporaryRoot() { return this.backend.temporaryRoot; }',
                                     '  get temporaryRoot() { return this.backend.temporaryRoot; }\n'
                                     '  get guestMetadata() { return this.backend.guestMetadata; }')),
 'node_modules/@deepseek-ai/dsh-tool-fs/lib/index.js': (('\t\t...cwd !== void 0 ? { cwd } : {},\n'
                                                         '\t\tsignal: exec.signal',
                                                         '\t\t...cwd !== void 0 ? { cwd } : {},\n'
                                                         '\t\t...exec.agent === void 0 ? {} : { iosGuestWorkspaceRoot: '
                                                         'exec.agent.session.header.cwd },\n'
                                                         '\t\tsignal: exec.signal'),),
 'node_modules/@deepseek-ai/dsh-fs-local/lib/index.js': (('import { FileSystem, FsError, FsTargetKey, FsVersion } from '
                                                          '"@deepseek-ai/dsh-fs";',
                                                          'import { FileSystem, FsError, FsTargetKey, FsVersion } from '
                                                          '"@deepseek-ai/dsh-fs";\n'
                                                          'const guestFilePath = (...args) => '
                                                          "globalThis[Symbol.for('dsh.go.ios.guest.owner')]?.filePath?.(...args) "
                                                          '?? args[0];'),
                                                         ('\tasync resolve(path, opts) {\n'
                                                          '\t\tif (opts?.signal?.aborted) throw new FsError("resolve '
                                                          'aborted", "FS_ABORTED");',
                                                          '\tasync resolve(path, opts) {\n'
                                                          '\t\tif (opts?.signal?.aborted) throw new FsError("resolve '
                                                          'aborted", "FS_ABORTED");\n'
                                                          '\t\tpath = guestFilePath(path, opts, '
                                                          'this.ctx.get("subprocess"));'),
                                                         ('\tasync lstat(path, opts, signal) {\n'
                                                          '\t\tif (signal?.aborted) throw new FsError("lstat aborted", '
                                                          '"FS_ABORTED");',
                                                          '\tasync lstat(path, opts, signal) {\n'
                                                          '\t\tif (signal?.aborted) throw new FsError("lstat aborted", '
                                                          '"FS_ABORTED");\n'
                                                          '\t\tpath = guestFilePath(path, opts, '
                                                          'this.ctx.get("subprocess"), { followFinalLink: false });')),
 'node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js': (('import { isAbsolute, join, parse, relative, sep } '
                                                                'from "node:path";',
                                                                'import { isAbsolute, join, parse, relative, sep } '
                                                                'from "node:path";\n'
                                                                'const guestFilePath = (...args) => '
                                                                "globalThis[Symbol.for('dsh.go.ios.guest.owner')]?.filePath?.(...args) "
                                                                '?? args[0];'),
                                                               ('\t\t\tif (typeof ctx.subprocess.prepare !== '
                                                                '"function") throw Object.assign(new Error("iOS '
                                                                '搜索需要提供受限执行票据的 subprocess 后端"), { code: '
                                                                '"ERR_OHOS_CONFINEMENT_UNAVAILABLE" });',
                                                                '\t\t\t// Both pinned argv builders put the sole '
                                                                'search path after a final --.\n'
                                                                '\t\t\t// Pattern/include flags remain byte-identical, '
                                                                'even when they look like paths.\n'
                                                                '\t\t\tif (exec.agent !== void 0 && command.at(-2) === '
                                                                '"--") {\n'
                                                                '\t\t\t\tcommand[command.length - 1] = '
                                                                'guestFilePath(command.at(-1), { '
                                                                'iosGuestWorkspaceRoot: workspaceRoot }, '
                                                                'ctx.subprocess);\n'
                                                                '\t\t\t}\n'
                                                                '\t\t\tif (typeof ctx.subprocess.prepare !== '
                                                                '"function") throw Object.assign(new Error("iOS '
                                                                '搜索需要提供受限执行票据的 subprocess 后端"), { code: '
                                                                '"ERR_OHOS_CONFINEMENT_UNAVAILABLE" });')),
 'runtime/ohos/process/worker.mjs': (("import { Bash, defineCommand } from './build/just-bash/index.js';",
                                      "import { Bash, defineCommand, parse } from './build/just-bash/index.js';"),
                                     ('filesystem.seal();',
                                      'let routing;\n'
                                      'if (workerData.iosGuestRouting === true) {\n'
                                      "  const { routingTransform } = await import('../../ios/guest/route.mjs');\n"
                                      '  routing = routingTransform(argv, { shellCommands, parse });\n'
                                      '  bash.registerTransformPlugin(routing.plugin);\n'
                                      '}\n'
                                      'filesystem.seal();'),
                                     ("  if (result.exitCode === 127) result.stderr += result.stderrKind === 'bytes'",
                                      "  if (routing?.decision && routing.decision.route !== 'virtual') {\n"
                                      '    parentPort.postMessage({ guestRoute: routing.decision });\n'
                                      '  } else {\n'
                                      "  if (result.exitCode === 127) result.stderr += result.stderrKind === 'bytes'"),
                                     ('  parentPort.postMessage({ exitCode: result.exitCode });',
                                      '  parentPort.postMessage({ exitCode: result.exitCode });\n  }'),
                                     ('const filesystem = createFilesystem(roots, policy);',
                                      'let executionFilesystem = createFilesystem;\n'
                                      'if (workerData.iosGuestTemporaryRoot) {\n'
                                      '  ({ createFilesystem: executionFilesystem } = await '
                                      'import("../../ios/guest/virtual-filesystem.mjs"));\n'
                                      '}\n'
                                      'const filesystem = executionFilesystem(roots, policy, '
                                      'workerData.iosGuestTemporaryRoot ? [{ mountPoint: "/tmp", root: '
                                      'workerData.iosGuestTemporaryRoot }] : []);')),
 'runtime/ohos/process/runtime.mjs': (('    if (policy.mode !== \'read-only\' && policy.mode !== \'workspace-write\') throw new Error(\'非法的受限运行模式\');',
                                        '    if (policy.mode !== \'read-only\' && policy.mode !== \'workspace-write\' && !(policy.mode === \'danger-full-access\' && this.#guest)) throw new Error(\'非法的受限运行模式\');'),
                                       ('  #createOwnedGitServer;',
                                       '  #createOwnedGitServer;\n'
                                       '  #guest;\n'
                                       '  #guestOutput;\n'
                                       '  #guestTemporaryRoot;\n'
                                       '  #guestOwner;\n'
                                       '  get guestMetadata() { return this.#guest?.metadata ?? null; }'),
                                      ('    this.onSpillFailure = onSpillFailure;',
                                       '    this.onSpillFailure = onSpillFailure;\n'
                                       '    // Only the installed, trusted main-process bootstrap publishes this '
                                       'owner.\n'
                                       "    const owner = globalThis[Symbol.for('dsh.go.ios.guest.owner')];\n"
                                       '    this.#guest = internals.guestProvider ?? owner?.provider;\n'
                                       '    this.#guestTemporaryRoot = owner?.temporaryRoot;\n'
                                       '    this.#guestOwner = owner;\n'
                                       '    if (this.#guestTemporaryRoot) this.roots = distinctRoots([...this.roots, '
                                       'this.#guestTemporaryRoot]);\n'
                                       '    this.#guestOutput = internals.deliverGuestOutput ?? owner?.deliverOutput;'),
                                      ('      Promise.resolve().then(() => state.resources?.finish({ cancelled: '
                                       'state.stopped })).then(() => settle(), settle);',
                                       '      Promise.resolve().then(() => state.resources?.finish({ cancelled: '
                                       'state.stopped })).then(async () => {\n'
                                       '        if (!state.guestRoute || state.stopped || state.failure || '
                                       'state.providerFailure) return;\n'
                                       '        state.worker = undefined;\n'
                                       '        state.resources = undefined;\n'
                                       '        state.guestAbort = new AbortController();\n'
                                       '        const deliverGuest = async (label, bytes) => {\n'
                                       '          const signal = state.guestAbort.signal;\n'
                                       "          if (signal.aborted) throw Object.assign(new Error('Guest output "
                                       "delivery cancelled'), { name: 'AbortError', code: 'ABORT_ERR' });\n"
                                       '          if (collected[label]) { collected[label].push(bytes); return; }\n'
                                       '          await this.#guestOutput(output[label] ?? process[label], bytes, '
                                       'signal);\n'
                                       '        };\n'
                                       '        try {\n'
                                       '          state.outcome = await this.#guest.execute({ ...state.guestContext, '
                                       'decision: state.guestRoute,\n'
                                       '            temporaryRoot: this.temporaryRoot, signal: '
                                       'state.guestAbort.signal,\n'
                                       '            graceMs: spec.graceMs, output: deliverGuest });\n'
                                       '        } catch (error) {\n'
                                       "          if (state.stopped && error.code === 'ABORT_ERR') return;\n"
                                       "          if (error.code === 'ERR_IOS_GUEST_FAULTED') throw error;\n"
                                       '          state.failure = error;\n'
                                       '        }\n'
                                       '      }).then(() => settle(), settle);'),
                                      ('        state.stopped = true;\n        state.resources?.stop();',
                                       '        state.stopped = true;\n'
                                       '        state.guestAbort?.abort();\n'
                                       '        state.resources?.stop();'),
                                      ('          } else {\n            state.resources = this.#createOwnedGitServer({',
                                       '          } else {\n'
                                       '            state.guestContext = { argv: [name, ...argv.slice(1)], cwd, '
                                       'policy, env,\n'
                                       "              stdin: typeof spec.stdio.stdin === 'object' ? "
                                       "spec.stdio.stdin.data : '' };\n"
                                       '            state.resources = this.#createOwnedGitServer({'),
                                      ('            if (state.resources.handle(message)) return;\n'
                                       '            if (message.failure)',
                                       '            if (state.resources.handle(message)) return;\n'
                                       '            if (message.guestRoute) { state.guestRoute = message.guestRoute; '
                                       'return; }\n'
                                       '            if (message.failure)'),
                                      ('            if (!state.outcome && !state.failure && !state.stopped) '
                                       'state.failure = new Error(`虚拟进程 worker 未报告结果，退出码 ${exitCode}`);',
                                       '            if (!state.outcome && !state.failure && !state.stopped && '
                                       '!state.guestRoute) state.failure = new Error(`虚拟进程 worker 未报告结果，退出码 '
                                       '${exitCode}`);'),
                                      ('      const observations = await Promise.allSettled(handles.map(handle => '
                                       'handle.waitForExit()));',
                                       '      const observations = await Promise.allSettled([...handles.map(handle => '
                                       'handle.waitForExit()), this.#guest?.dispose()]);'),
                                      ('                roots,\n                env, stdin:',
                                       # A paused Linux (a run that did not finish) hands ordinary
                                       # scripts back to the virtual shell, as if it were not installed.
                                       '                roots, iosGuestRouting: !!this.#guest && '
                                       'this.#guest.metadata?.suspended !== true, iosGuestTemporaryRoot: '
                                       'this.#guestTemporaryRoot,\n'
                                       '                env, stdin:'),
                                      ('const roots = distinctRoots([policy?.workspaceRoot ?? cwd, '
                                       'this.temporaryRoot]);',
                                       'const roots = distinctRoots([policy?.workspaceRoot ?? cwd, '
                                       'this.#guestTemporaryRoot ?? this.temporaryRoot]);'),
                                      ('...spec.env, TMPDIR: this.temporaryRoot',
                                       '...spec.env, TMPDIR: this.#guestTemporaryRoot ? "/tmp" : this.temporaryRoot'),
                                      ('      const owner = this.#temporaryOwner;',
                                       '      await this.#guestOwner?.dispose();\n'
                                       '      const owner = this.#temporaryOwner;')),
 'runtime/ohos/capabilities/snapshot.mjs': (('import { readPublicationCapabilities }',
                                             "const guestMetadataView = () => ({ v: 1, source: 'none', state: "
                                             "'unavailable', installed: 'unknown', available: false, enforcement: "
                                             "'unknown', python: 'unknown' });\n"
                                             'import { readPublicationCapabilities }'),
                                            ('    v: 1, bootId, platform:',
                                             "    iosGuest: ctx.get('subprocess')?.guestMetadata ?? "
                                             'guestMetadataView(undefined, false),\n'
                                             '    v: 1, bootId, platform:')),
 'node_modules/@deepseek-ai/dsh-bash-sandbox/lib/index.js': (('\t\tif (mode === "danger-full-access") return SandboxBashExecutor.decorateResult',
                                                                '\t\t// iOS Linux still needs a one-use workspace ticket in full-access mode.\n'
                                                                '\t\tif (mode === "danger-full-access" && this.ctx.subprocess.guestMetadata == null) return SandboxBashExecutor.decorateResult'),),
 'node_modules/@deepseek-ai/dsh-tool-bash/lib/index.js': (('function bashDescription(ctx) {',
                                                            'function bashDescription(ctx) {\n\tconst guestMetadata = ctx.get("subprocess")?.guestMetadata;'),
                                                           ('import z from "@deepseek-ai/schemastery";',
                                                           'const guestDescription = metadata => '
                                                           "globalThis[Symbol.for('dsh.go.ios.guest.owner')]?.description?.(metadata) "
                                                           "?? '可选 Linux 环境尚未启用。';\n"
                                                           'import z from "@deepseek-ai/schemastery";'),
                                                          ('。没有系统进程、PTY、Python 或 WASM；',
                                                           '。当前虚拟 shell 本身没有系统进程、PTY、Python 或 WASM；'),
                                                          (' + ohos;',
                                                           " + (ohos ? (guestMetadata ? '' : ohos + '\\n') + "
                                                           "guestDescription(guestMetadata) : "
                                                           "'');"))}
# Root grants exist only in exact installed-iOS replacements. Default modules stay byte-identical.
FILES += ('runtime/ios/guest/root-grants.mjs',)
EDITS['node_modules/@deepseek-ai/dsh-tool-bash/lib/index.js'] += (
    ('\t\t\t\tworkdir: {', '\t\t\t\tlinux_root_write: { type: "string", description: "Optional nonempty reason requesting one-call permission to modify the installed Linux system disk (packages/configuration). Always asks independently of workspace mode; omit for ordinary reads or workspace/tmp writes." },\n\t\t\t\tworkdir: {'),
    ('\t\t\t\tconst policy = approvedMode', '\t\t\t\tlet policy = approvedMode'),
    ('\t\t\t\tconst dshEnv = ctx.shellEnv.collect(exec);',
     '\t\t\t\tif (args.linux_root_write !== void 0) {\n'
     '\t\t\t\t\tconst owner = globalThis[Symbol.for("dsh.go.ios.guest.owner")];\n'
     '\t\t\t\t\tif (!owner) throw new Error("Linux system-disk approval requires the installed iOS owner");\n'
     '\t\t\t\t\tpolicy = await owner.authorizeRootWrite({ reason: args.linux_root_write, command: args.command, cwd: workdir, policy, approver: ctx.get("approval"), agent: exec.agent, callId: exec.callId, signal: exec.signal });\n'
     '\t\t\t\t}\n\t\t\t\tconst dshEnv = ctx.shellEnv.collect(exec);'),
)
EDITS['runtime/ohos/process/runtime.mjs'] += (
    ('    const token = randomUUID();', '    const rootGrant = this.#guestOwner?.prepareRootGrant(argv, policy, signal);\n    const token = randomUUID();'),
    ('{ argv: [...argv], policy: { ...policy, workspaceRoot }, signal, cancel }', '{ argv: [...argv], policy: { ...policy, workspaceRoot }, rootGrant, signal, cancel }'),
    ('    let policy;', '    let policy;\n    let rootPermission;'),
    ('      policy = prepared.policy;', '      policy = prepared.policy;\n      rootPermission = this.#guestOwner?.activateRootGrant(prepared.rootGrant, argv, policy, realpathSync(resolve(spec.cwd)), spec.signal);'),
    ('state.guestContext = { argv: [name, ...argv.slice(1)], cwd, policy, env,', 'state.guestContext = { argv: [name, ...argv.slice(1)], cwd, policy, rootPermission, env,'),
)
INPUT_GUARDS = {'runtime/ohos/lifecycle/budget.mjs': ('export class ActiveBudgetClock {', '  constructor(bootId) {'),
 'runtime/ohos/lifecycle/coordinator.mjs': ("import { ActiveBudgetClock } from './budget.mjs';",
                                            '    this.bootId = bootId;\n'
                                            '    this.clock = new ActiveBudgetClock(bootId);'),
 'runtime/ohos/lifecycle/index.mjs': ('Object.defineProperty(globalThis, lifecycleSymbol, { value: coordinator, '
                                      'configurable: false, writable: false });',)}
def specialize(name, original):
    data = original
    for before, after in EDITS[name]:
        before, after = before.encode(), after.encode()
        if data.count(before) != 1:
            raise ValueError('iOS guest input differs from verified shared source: ' + name)
        data = data.replace(before, after)
    return data
