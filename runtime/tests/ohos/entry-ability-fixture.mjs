// Explicit test-only EntryAbility import contract. Real plugin/SDK targets stay
// in each consumer fixture; this module never loads or replaces product code.
export const entryAbilityImports = Object.freeze({
  '../plugins/PastePlugin': ['default'],
  '../plugins/AppLinksPlugin': ['default'],
  '../plugins/SecretsPlugin': ['default'],
  '../plugins/AttachmentFilesPlugin': ['default'],
  '../plugins/IslandsPlugin': ['default'],
  '../plugins/NotifyPlugin': ['default'],
  '@ohos/flutter_ohos': ['FlutterAbility', 'FlutterEngine'],
  '../plugins/ConnectivityPlugin': ['default'],
  '../plugins/GeneratedPluginRegistrant': ['GeneratedPluginRegistrant'],
  '../runtime/RuntimePlugin': ['RuntimePlugin'],
  '../runtime/RuntimeController': ['RuntimeController'],
  '../plugins/FilesMediaPlugin': ['default'],
  '../plugins/NativeFilesPlugin': ['default'],
  '../plugins/AuthorizedWorkspacesPlugin': ['default'],
  '../plugins/NativeMediaPlugin': ['default'],
  '../plugins/NativeVoiceStopControl': ['NativeVoiceStopControl'],
  '../plugins/PerformancePlugin': ['default'],
  '../plugins/OhosKeyboardLog': ['OhosKeyboardLog'],
  '../plugins/DiagnosticsPlugin': ['default'],
  '../plugins/UsagePlugin': ['default'],
  '../runtime/NativeHost': ['loadNativeHost'],
  '../plugins/WebFilesPlugin': ['default'],
  '../plugins/HmsSharePlugin': ['default'],
  '../plugins/HmsShareInbox': ['HmsShareInbox'],
  '../plugins/ShortcutsPlugin': ['default'],
  '../plugins/LauncherIconPlugin': ['default'],
  '../plugins/PictureShortcutPlugin': ['default'],
  '../plugins/LaunchPlugin': ['default'],
  '../plugins/LaunchClipPlugin': ['default'],
  '../plugins/MediaVideoPlugin': ['default'],
  '../plugins/VoicePlugin': ['default'],
  '../plugins/SpeechPlugin': ['default'],
  '../plugins/CompanionVoicePlugin': ['default'],
  '../plugins/StreamingAsrPlugin': ['default'],
  '../plugins/CompanionWidgetPlugin': ['default'],
  '@ohos.app.ability.Want': ['default'],
  '@ohos.app.ability.AbilityConstant': ['default'],
  '@ohos.window': ['default'],
});

export function assertEntryAbilityImports(source) {
  const seen = new Set();
  const imports = [...source.matchAll(/^import (.+?) from ['"]([^'"]+)['"];$/gm)];
  if ([...source.matchAll(/^\s*import\b/gm)].length !== imports.length) {
    throw new Error('Unsupported EntryAbility import syntax');
  }
  for (const [, binding, specifier] of imports) {
    const expected = entryAbilityImports[specifier];
    if (!expected) throw new Error('Unregistered EntryAbility import: ' + specifier);
    if (seen.has(specifier)) throw new Error('Duplicate EntryAbility import: ' + specifier);
    seen.add(specifier);
    let names;
    if (/^[A-Za-z_$][\w$]*$/.test(binding)) names = ['default'];
    else if (/^\{\s*[A-Za-z_$][\w$]*(?:\s*,\s*[A-Za-z_$][\w$]*)*\s*\}$/.test(binding)) {
      names = binding.slice(1, -1).split(',').map(name => name.trim());
    } else throw new Error('Unsupported EntryAbility import binding: ' + binding);
    if (names.join(',') !== expected.join(',')) {
      throw new Error('Unregistered EntryAbility exports: ' + specifier + ': ' + names.join(','));
    }
  }
  if (imports.length !== Object.keys(entryAbilityImports).length) {
    throw new Error('EntryAbility import set changed; update the explicit fixture contract');
  }
}

class EntryPluginStub {
  static registerWith() {}
  static receive() { return false; }
  static onForeground() {}
  static onBackground() {}
  static onDestroy() {}
  static applyFrameCache() {}
  setForeground() {}
  attach() {}
  detach() {}
  onAttachedToEngine() {}
}

export function createEntryAbilityImports(overrides = {}) {
  for (const specifier of Object.keys(overrides)) {
    if (!specifier.startsWith('.') || !Object.hasOwn(entryAbilityImports, specifier)) {
      throw new Error('Unregistered EntryAbility override: ' + specifier);
    }
    if (typeof overrides[specifier] !== 'function') throw new TypeError('Entry override must be a loader');
  }
  return specifier => {
    const names = entryAbilityImports[specifier];
    if (!specifier.startsWith('.') || !names) throw new Error('Unregistered EntryAbility import: ' + specifier);
    if (Object.hasOwn(overrides, specifier)) return overrides[specifier]();
    // NativeHost is an actual host boundary, never silently stubbed by this map.
    if (specifier === '../runtime/NativeHost') throw new Error('EntryAbility NativeHost requires explicit boundary');
    const exports = Object.fromEntries(names.map(name => [name, EntryPluginStub]));
    return new Proxy(Object.freeze(exports), {
      get(target, name) {
        if (name === '__esModule') return true;
        if (typeof name === 'symbol') return Reflect.get(target, name);
        if (!Object.hasOwn(target, name)) throw new Error('Unregistered EntryAbility export: ' + specifier + ': ' + name);
        return target[name];
      },
    });
  };
}
