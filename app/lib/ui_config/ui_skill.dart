// The dsh-go-ui skill that teaches a host's agent to edit ui.json. The files
// ship in assets/skills/dsh-go-ui/ (flat; manifest.json maps each to its place
// in the skill folder).
//
// - On-device engine: written into `$DSH_HOME/skills/dsh-go-ui/` each time the
//   engine comes up. DSH watches that root, so the skill appears without a
//   restart. The app keeps the folder current while SKILL.md carries the
//   managed line (a YAML comment inside the front matter — DSH only reads a
//   skill whose first line is `---`); once the person deletes that line the
//   folder is theirs.
// - Remote hosts: only after the person confirms ([UiSkillRemoteInstaller]):
//   over SSH with [uiSkillShellScript], elsewhere by handing the agent
//   [uiSkillInstallPrompt] to send.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart' show BuildContext;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../runtime/runtime_bridge.dart';
import '../runtime/runtime_state.dart';
import '../state/android_features.dart' show operatingSystemProvider;
import '../state/hosts_state.dart';
import 'ui_config_state.dart';

const uiSkillName = 'dsh-go-ui';
const uiSkillAssetDir = 'assets/skills/dsh-go-ui/';

/// The second skill the app ships: teaches a host's agent to write a small
/// local native plugin (sdk/plugin-kit/skill, built into
/// assets/skills/dsh-go-plugin/ by sdk/plugin-kit/scripts/sync-skill.mjs).
/// Installed and kept current exactly like [uiSkillName], in its own folder.
const pluginSkillName = 'dsh-go-plugin';

/// The third: the app's own user guide (docs/guide, built into
/// assets/skills/dsh-go-guide/ by tool/guide_sync.py), so the agent can answer
/// how to use the app. Read-only; installed and kept current the same way.
const guideSkillName = 'dsh-go-guide';

/// The fourth: troubleshooting and bug-report playbook. Reads the diagnostics
/// snapshot the app writes into the engine (`$DSH_HOME/dsh-app/diagnostics.md`)
/// and turns a symptom into a redacted environment summary / issue draft.
const supportSkillName = 'dsh-go-support';

/// Uses the same report, prompt and checked adapter as companion light mode.
const companionAdaptSkillName = 'companion-adapt';

/// The fifth: turns a clawd-on-desk theme into an importable pet pack. The converter
/// and its friends ship as text next to SKILL.md (app/tool/pet_theme_convert.py is
/// the source of truth) and are written to the skill folder's scripts/ so the agent
/// can run them on the host.
const petThemeSkillName = 'pet-theme';

/// The managed line inside SKILL.md's front matter.
const uiSkillManagedMarker = '# dsh-go:managed';

final _safePath = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$');

/// The skill's files: path inside the skill folder → text.
class UiSkillBundle {
  UiSkillBundle(Map<String, String> files, {this.name = uiSkillName})
    : files = Map.unmodifiable({
        for (final MapEntry(:key, :value) in files.entries)
          if (_safePath.hasMatch(key)) key: value,
      });

  final Map<String, String> files;

  /// The skill's folder name under `$DSH_HOME/skills/`.
  final String name;

  String get skillMd => files['SKILL.md'] ?? '';

  /// SKILL.md last, so DSH never sees the skill before its files.
  List<MapEntry<String, String>> get writeOrder => [
    ...files.entries.where((e) => e.key != 'SKILL.md'),
    ...files.entries.where((e) => e.key == 'SKILL.md'),
  ];
}

typedef UiAssetReader = Future<String> Function(String key);

/// Reads a bundled skill (manifest first): [uiSkillName] unless [name] says
/// otherwise.
Future<UiSkillBundle> loadUiSkillBundle([UiAssetReader? read, String name = uiSkillName, String? os]) async {
  // Read once per engine start: kept in the bundle's cache, the skills'
  // text (about 1 MiB) would stay in memory for the whole run.
  final reader = read ?? (String key) => rootBundle.loadString(key, cache: false);
  final assetDir = 'assets/skills/$name/';
  final manifest = jsonDecode(await reader('${assetDir}manifest.json'));
  final files = (manifest as Map)['files'] as Map;
  // What HarmonyOS says differently takes the same path, so nothing of Android's
  // is left behind when it installs over an earlier copy.
  final harmony = os == 'ohos' ? manifest['harmony'] as Map? : null;
  final assets = {
    for (final MapEntry(key: asset, value: target) in files.entries) '$target': '$asset',
    if (harmony != null)
      for (final MapEntry(key: asset, value: target) in harmony.entries) '$target': '$asset',
  };
  return UiSkillBundle({
    for (final MapEntry(key: target, value: asset) in assets.entries) target: await reader('$assetDir$asset'),
  }, name: name);
}

/// Whether [skillMd] still carries the managed line in its front matter.
bool isManagedUiSkill(String skillMd) {
  final match = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---').firstMatch(skillMd);
  if (match == null) return false;
  return match.group(1)!.split('\n').any((line) => line.trimLeft().startsWith(uiSkillManagedMarker));
}

enum UiSkillInstallResult {
  /// Written for the first time.
  installed,

  /// Some files were out of date and were rewritten.
  updated,

  /// Already current.
  unchanged,

  /// The person took the folder over (managed line removed): left alone.
  userOwned,

  /// DSH home doesn't exist yet (the engine never ran).
  noHome,
}

/// Writes [bundle] into `<rootfs>/root/.dsh/skills/<bundle.name>/`. Files are
/// replaced atomically and only when their text differs. This synchronous IO
/// reference helper requires exclusive ownership of [rootfs]. The running
/// Android engine's auto-installer uses the native serialized transaction;
/// this is never a fallback around that runtime lifecycle boundary.
Future<UiSkillInstallResult> installUiSkill(Directory rootfs, UiSkillBundle bundle) async {
  final home = Directory('${rootfs.path}/root/.dsh');
  if (!home.existsSync()) return UiSkillInstallResult.noHome;
  final dir = Directory('${home.path}/skills/${bundle.name}');
  final skillFile = File('${dir.path}/SKILL.md');
  final existed = skillFile.existsSync();
  if (existed) {
    String current;
    try {
      current = skillFile.readAsStringSync();
    } catch (_) {
      return UiSkillInstallResult.userOwned;
    }
    if (!isManagedUiSkill(current)) return UiSkillInstallResult.userOwned;
  }
  var changed = false;
  for (final MapEntry(key: path, value: text) in bundle.writeOrder) {
    final file = File('${dir.path}/$path');
    try {
      if (file.existsSync() && file.readAsStringSync() == text) continue;
    } catch (_) {}
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.dsh-go-tmp');
    tmp.writeAsStringSync(text, flush: true);
    tmp.renameSync(file.path);
    changed = true;
  }
  if (!existed) return UiSkillInstallResult.installed;
  return changed ? UiSkillInstallResult.updated : UiSkillInstallResult.unchanged;
}

// ── On-device auto-install ──────────────────────────────────────────────────

typedef UiSkillBundleLoader = Future<UiSkillBundle> Function();

final uiSkillBundleLoaderProvider = Provider<UiSkillBundleLoader>((ref) => loadUiSkillBundle);

/// The other skills installed next to [uiSkillName] on each engine start.
final extraSkillLoadersProvider = Provider<List<UiSkillBundleLoader>>((ref) {
  final os = ref.watch(operatingSystemProvider);
  return [
    () => loadUiSkillBundle(null, pluginSkillName),
    () => loadUiSkillBundle(null, guideSkillName, os),
    () => loadUiSkillBundle(null, supportSkillName),
    () => loadUiSkillBundle(null, companionAdaptSkillName),
    () => loadUiSkillBundle(null, petThemeSkillName),
  ];
});

/// Installs the skill each time the on-device engine comes up (and at launch
/// when it is already running); the state is the last result (null before
/// the first run). The app root (`RootGate`, ui/shell/root_gate.dart) keeps it alive with
/// `ref.listen(uiSkillAutoInstallProvider, (_, _) {})`. Each run compares
/// every file's text, so an app update brings its skills at the next start.
class UiSkillAutoInstaller extends Notifier<UiSkillInstallResult?> {
  _UiSkillDrain? _drain;

  @override
  UiSkillInstallResult? build() {
    final r = ref;
    late final _UiSkillDrain drain;
    drain = _UiSkillDrain(
      r,
      bridge: r.watch(runtimeBridgeProvider),
      resolve: r.watch(uiRootfsResolverProvider),
      primary: r.watch(uiSkillBundleLoaderProvider),
      extras: List.of(r.watch(extraSkillLoadersProvider)),
      publish: (result) {
        if (r.mounted && identical(_drain, drain)) state = result;
      },
    );
    _drain = drain;
    r.onDispose(drain.dispose);
    r.listen<RuntimeStatus>(localRuntimeProvider.select((runtime) => runtime.status), (_, status) {
      drain.update(status);
    }, fireImmediately: true);
    return null;
  }

  /// The active batch and its one coalesced successor, if any (tests await it).
  Future<void>? get running => _drain?.running;
}

/// Each build owns its Ref, bridge and loaders. Retired async continuations can
/// finish but cannot acquire a new run's write permission or publish its state.
class _UiSkillDrain {
  _UiSkillDrain(
    this.ref, {
    required this.bridge,
    required this.resolve,
    required this.primary,
    required this.extras,
    required this.publish,
  });

  final Ref ref;
  final RuntimeBridge bridge;
  final Future<Directory?> Function() resolve;
  final UiSkillBundleLoader primary;
  final List<UiSkillBundleLoader> extras;
  final void Function(UiSkillInstallResult) publish;
  final String _nonce = List.generate(4, (_) => Random.secure().nextInt(1 << 32).toRadixString(16)).join('-');
  int _serial = 0;
  int _epoch = 0;
  bool _disposed = false;
  (String, String, int?)? _ready;
  _UiSkillBatch? _pending;
  _UiSkillBatch? _active;
  Completer<void>? _completion;

  Future<void>? get running => _completion?.future;

  void update(RuntimeStatus status) {
    if (_disposed) return;
    final ready = status.isRunning && status.token!.isNotEmpty
        ? (status.token!, status.baseUrl!, status.managedSkillGeneration)
        : null;
    if (ready == _ready) return;
    _ready = ready;
    _epoch++;
    _cancelActive();
    _pending = ready == null ? null : _UiSkillBatch(_epoch, ready.$1, ready.$2, ready.$3);
    if (_pending != null && _completion == null) {
      final completion = _completion = Completer<void>();
      unawaited(
        _run().whenComplete(() {
          if (identical(_completion, completion)) _completion = null;
          completion.complete();
        }),
      );
    }
  }

  bool _current(_UiSkillBatch batch) {
    if (_disposed || !ref.mounted || batch.retired || batch.epoch != _epoch || !identical(_active, batch)) return false;
    // Check the actual provider too: an async continuation may run before the
    // listened status notification has retired this batch.
    final status = ref.read(localRuntimeProvider).status;
    return status.isRunning &&
        status.token == batch.token &&
        status.baseUrl == batch.baseUrl &&
        status.managedSkillGeneration == batch.generation;
  }

  void _cancelActive() {
    final batch = _active;
    final request = batch?.requestId;
    if (request != null && !batch!.cancelRequested) {
      batch.cancelRequested = true;
      unawaited(bridge.cancelManagedSkill(request).catchError((_) {}));
    }
  }

  void dispose() {
    _disposed = true;
    _epoch++;
    _pending = null;
    _cancelActive();
  }

  Future<void> _run() async {
    while (!_disposed && ref.mounted && _pending != null) {
      final batch = _active = _pending!;
      _pending = null;
      try {
        final root = await resolve();
        if (root == null || !_current(batch)) continue;
        final bundle = await primary();
        if (!_current(batch)) continue;
        final result = await _install(batch, root, bundle);
        if (!_current(batch)) continue;
        if (result != null) publish(result);
        for (final load in extras) {
          try {
            if (!_current(batch)) break;
            final extra = await load();
            if (!_current(batch)) break;
            await _install(batch, root, extra);
          } catch (_) {}
        }
      } catch (_) {
        // Missing native bridge, rejected transaction or failed assets: next
        // engine start retries. Never write the live root from this isolate.
      } finally {
        if (identical(_active, batch)) _active = null;
      }
    }
  }

  Future<UiSkillInstallResult?> _install(_UiSkillBatch batch, Directory root, UiSkillBundle bundle) async {
    if (!_current(batch)) return null;
    final requestId = '$_nonce-${++_serial}';
    batch.requestId = requestId;
    try {
      final response = await bridge.installManagedSkill(
        requestId: requestId,
        expectedRoot: root.path,
        expectedToken: batch.token,
        expectedGeneration: batch.generation,
        name: bundle.name,
        files: bundle.files,
      );
      if (!_current(batch)) return null;
      if (!response.current) {
        batch.retired = true;
        return null;
      }
      return UiSkillInstallResult.values.where((value) => value.name == response.result).firstOrNull;
    } finally {
      if (batch.requestId == requestId) batch.requestId = null;
    }
  }
}

class _UiSkillBatch {
  _UiSkillBatch(this.epoch, this.token, this.baseUrl, this.generation);
  final int epoch;
  final String token;
  final String baseUrl;
  final int? generation;
  String? requestId;
  bool cancelRequested = false;
  bool retired = false;
}

final uiSkillAutoInstallProvider = NotifierProvider<UiSkillAutoInstaller, UiSkillInstallResult?>(
  UiSkillAutoInstaller.new,
);

// ── Remote hosts ────────────────────────────────────────────────────────────

/// Installs the skill on a remote host after the person agreed. The app's
/// wiring provides one (SSH: [uiSkillShellScript] over the host's shell;
/// relay: [uiSkillInstallPrompt] into the composer for the person to send);
/// without one, no install entry is shown.
abstract interface class UiSkillRemoteInstaller {
  /// Returns whether the skill was written (or the message handed over).
  Future<bool> install(BuildContext context, HostRef host, UiSkillBundle bundle);
}

final uiSkillRemoteInstallerProvider = Provider<UiSkillRemoteInstaller?>((ref) => null);

/// A POSIX `sh` script that writes [bundle] to
/// `${DSH_HOME:-$HOME/.dsh}/skills/dsh-go-ui/` (leaving a folder the person
/// took over alone) and prints `DSHAPP skill=installed` or
/// `DSHAPP skill=user-owned`.
String uiSkillShellScript(UiSkillBundle bundle) {
  final out = StringBuffer()
    ..writeln('set -e')
    ..writeln('d="\${DSH_HOME:-\$HOME/.dsh}/skills/${bundle.name}"')
    ..writeln(
      'if [ -f "\$d/SKILL.md" ] && ! grep -q \'^ *$uiSkillManagedMarker\' "\$d/SKILL.md"; then '
      "echo 'DSHAPP skill=user-owned'; exit 0; fi",
    );
  final dirs = {
    for (final path in bundle.files.keys)
      if (path.contains('/')) path.substring(0, path.lastIndexOf('/')),
  };
  out.writeln('mkdir -p "\$d"${dirs.map((d) => ' "\$d/$d"').join()}');
  var n = 0;
  for (final MapEntry(key: path, value: text) in bundle.writeOrder) {
    var tag = 'DSHGO_EOF_$n';
    while (text.split('\n').contains(tag)) {
      tag = '${tag}_';
    }
    n++;
    final body = text.endsWith('\n') ? text : '$text\n';
    out
      ..writeln("cat > \"\$d/$path.dsh-go-tmp\" <<'$tag'")
      ..write(body)
      ..writeln(tag)
      ..writeln('mv "\$d/$path.dsh-go-tmp" "\$d/$path"');
  }
  out.writeln("echo 'DSHAPP skill=installed'");
  return out.toString();
}

/// A message for the remote agent: the skill's working files and where to
/// put them. The person sends it themself.
String uiSkillInstallPrompt(UiSkillBundle bundle) {
  final out = StringBuffer()
    ..writeln(appL10n.shellSkillInstallPrompt(uiSkillName))
    ..writeln()
    ..writeln(appL10n.shellSkillInstallDirectory(uiSkillName))
    ..writeln(appL10n.shellSkillInstallFiles)
    ..writeln(
      appL10n.shellSkillInstallCheck('`node "\${DSH_HOME:-\$HOME/.dsh}/skills/$uiSkillName/scripts/check.mjs"`'),
    )
    ..writeln(appL10n.shellSkillInstallConfirm);
  for (final path in const ['SKILL.md', 'schema.json', 'scripts/check.mjs']) {
    final text = bundle.files[path];
    if (text == null) continue;
    final lang = switch (path.split('.').last) {
      'md' => 'markdown',
      'json' => 'json',
      _ => 'js',
    };
    out
      ..writeln()
      ..writeln(appL10n.shellSkillInstallFile(path))
      ..writeln()
      ..writeln('````$lang')
      ..write(text.endsWith('\n') ? text : '$text\n')
      ..writeln('````');
  }
  return out.toString();
}
