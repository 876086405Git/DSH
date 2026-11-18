// TypeScript semantic check against fixed public OH declarations; not an ArkTS compiler.
import { createRequire } from 'node:module';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, join, dirname, parse } from 'node:path';
import { createHash } from 'node:crypto';
const [source, sdk, output, processPrefix] = process.argv.slice(2).map(x => resolve(x));
const ts = createRequire(join(processPrefix, 'package.json'))('typescript');
mkdirSync(output, { recursive: true });
const sources = [];
const staged = new Map();
function stage(input) {
  input = resolve(input);
  if (staged.has(input)) return staged.get(input);
  const target = join(output, 'sources', input.slice(parse(input).root.length)).replace(/\.ets$/, '.ts');
  staged.set(input, target);
  const bytes = readFileSync(input);
  sources.push({ path: input, sha256: createHash('sha256').update(bytes).digest('hex') });
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, bytes);
  for (const match of bytes.toString('utf8').matchAll(/from\s+['"](\.[^'"]+)['"]/g)) {
    const imported = resolve(dirname(input), match[1]);
    if (existsSync(imported + '.ets')) stage(imported + '.ets');
    else if (existsSync(imported + '.ts')) stage(imported + '.ts');
  }
  return target;
}
const plugin = stage(source);
writeFileSync(join(output, 'flutter.d.ts'), `
import common from '@ohos.app.ability.common';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import AbilityConstant from '@ohos.app.ability.AbilityConstant';
export type Any = any; // Flutter's public ESObject bridge, not a product cast.
export interface BinaryMessenger { setMessageHandler(name: string, handler: null): void; }
export interface FlutterPluginBinding { getApplicationContext(): common.Context; getBinaryMessenger(): BinaryMessenger; }
export interface FlutterPlugin { getUniqueClassName(): string; onAttachedToEngine(binding: FlutterPluginBinding): void; onDetachedFromEngine(binding: FlutterPluginBinding): void; }
export interface AbilityAware { onAttachedToAbility(binding: AbilityPluginBinding): void; onDetachedFromAbility(): void; }
export interface AbilityPluginBinding { getAbility(): UIAbility; addOnNewWantListener(listener: NewWantListener): void; removeOnNewWantListener(listener: NewWantListener): void; }
export interface NewWantListener { onNewWant(want: Want, launch: AbilityConstant.LaunchParam): void; }
export interface MethodCall { method: string; argument(key: string): Any; }
export interface MethodResult { success(value: Any): void; error(code: string, message: string, details: Any): void; notImplemented(): void; }
export interface MethodCallHandler { onMethodCall(call: MethodCall, result: MethodResult): void; }
export class MethodChannel { constructor(messenger: BinaryMessenger, name: string); setMethodCallHandler(handler: MethodCallHandler | null): void; invokeMethod(method: string, args: Any): void; }
export interface EventSink { success(event: Any): void; error(code: string, message: string, details: Any): void; endOfStream(): void; }
export interface StreamHandler { onListen(args: Any, events: EventSink): void; onCancel(args: Any): void; }
export class EventChannel { constructor(messenger: BinaryMessenger, name: string); setStreamHandler(handler: StreamHandler): void; }
`);
const main = source.split('/ets/')[0];
const hostTypes = join(main, 'cpp/types/libdsh_host/index.d.ts');
writeFileSync(join(output, 'host.d.ts'), readFileSync(hostTypes));
for (const [name, exports] of Object.entries({
  MethodCall: 'MethodCall as default',
  MethodChannel: 'MethodChannel as default, MethodCallHandler, MethodResult',
  EventChannel: 'EventChannel as default, StreamHandler, EventSink',
  Any: 'Any as default',
})) writeFileSync(join(output, name + '.d.ts'), `export { ${exports} } from './flutter';\n`);
const options = { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS, strict: true, noEmit: true,
  skipLibCheck: true, types: [], baseUrl: output, paths: {
    'libdsh_host.so': [join(output, 'host.d.ts')], '@ohos/flutter_ohos': [join(output, 'flutter.d.ts')],
    '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin': [join(output, 'flutter.d.ts')],
    '@ohos/flutter_ohos/src/main/ets/plugin/common/*': [join(output, '*.d.ts')],
    '@ohos.*': [join(sdk, '@ohos.*.d.ts')],
  }, moduleResolution: ts.ModuleResolutionKind.Node10 };
const program = ts.createProgram([plugin], options);
const diagnostics = ts.getPreEmitDiagnostics(program).map(x => ({ code: x.code,
  file: x.file?.fileName, line: x.file && x.start !== undefined ? x.file.getLineAndCharacterOfPosition(x.start).line + 1 : null,
  message: ts.flattenDiagnosticMessageText(x.messageText, '\n') }));
const report = { compiler: ts.version, source, sources, sdk, scope: 'TypeScript+fixed public OH .d.ts+minimal public Flutter signatures; not ArkTS/hvigor', diagnostics };
writeFileSync(join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2)); process.exitCode = diagnostics.length ? 1 : 0;
