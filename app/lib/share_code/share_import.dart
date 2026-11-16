// Opening a share code: what would change on the chosen engine (the confirm
// sheet's diff, per-item toggles) and applying the ticked changes in order:
// restore point, plugins, settings, skills, AGENTS.md.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';

import '../l10n/l10n.dart';
import '../state/connection_state.dart';
import '../state/plugins_state.dart';
import 'guest_fs.dart';
import 'namespace_labels.dart';
import 'restore_point.dart';
import 'settings_sanitizer.dart' show isSecretFieldName;
import 'share_models.dart';
import 'share_net.dart';

enum ImportSection { plugins, presets, settings, skills, agentsMd }

enum ChangeKind {
  /// New on the target.
  add,

  /// Replaces something on the target.
  change,
  install,
  upgrade,
  enable,

  /// Already the same: shown for plugins, not applied.
  unchanged,

  /// Can't be applied on this target ([ImportChange.blocked] says why).
  unavailable,
}

/// Whether the registry still serves the package the sharer had.
enum IntegrityStatus { verified, unverifiable, mismatch }

/// The engine an import goes to.
class ImportTarget {
  const ImportTarget(this.connection, {required this.isActive, this.safeMode = false, this.installRefused = false});

  final HostConnection connection;

  /// The host the chat talks to (installs then show on the plugin pages).
  final bool isActive;

  /// The on-device engine runs its repair profile: no installs.
  final bool safeMode;

  /// The engine takes no market installs (HarmonyOS's own).
  final bool installRefused;

  bool get isLocal => connection.isLocal;
  String get label => connection.label;
  DshClient get client => connection.client;
  bool get canInstall => !safeMode && !installRefused && client.canInstallPlugins;
}

/// One row of the diff.
class ImportChange {
  const ImportChange({
    required this.id,
    required this.section,
    required this.title,
    required this.kind,
    this.detail,
    this.defaultOn = true,
    this.sensitive = false,
    this.blocked,
    this.monoTitle = false,
    this.follows,
    this.plugin,
    this.fromVersion,
    this.integrity,
    this.facts,
    this.installSpec,
    this.ops = const [],
    this.skill,
    this.text,
  });

  /// `plugin:<name>`, `preset:<id>`, `settings:<ns>`, `skill:<name>`, `agents-md`.
  final String id;
  final ImportSection section;
  final String title;
  final ChangeKind kind;

  /// `maxDepth 1 → 3`, `1.2.0 → 1.4.2`.
  final String? detail;
  final bool defaultOn;

  /// Changes where requests go or what tools may do: shown in full.
  final bool sensitive;
  final String? blocked;
  final bool monoTitle;

  /// A preset is applied with its plugin: the plugin change's id.
  final String? follows;

  // Plugins.
  final SharedPlugin? plugin;
  final String? fromVersion;
  final IntegrityStatus? integrity;
  final NpmFacts? facts;

  /// What to install: the shared spec, or an official on-demand target.
  final String? installSpec;

  // Settings.
  final List<SettingsOp> ops;

  // Skills / AGENTS.md.
  final SharedSkill? skill;
  final String? text;

  /// Has its own switch.
  bool get toggleable =>
      blocked == null && follows == null && kind != ChangeKind.unchanged && kind != ChangeKind.unavailable;

  /// Does something when applied.
  bool get actionable => blocked == null && kind != ChangeKind.unchanged && kind != ChangeKind.unavailable;
}

class ImportPlan {
  const ImportPlan({required this.payload, required this.target, required this.changes});

  final SharePayload payload;
  final ImportTarget target;
  final List<ImportChange> changes;

  Iterable<ImportChange> section(ImportSection s) => changes.where((c) => c.section == s);

  Set<String> get defaultSelection => {
    for (final c in changes)
      if (c.toggleable && c.defaultOn) c.id,
  };

  /// Changes that would run for [selected] (presets follow their plugin).
  List<ImportChange> selected(Set<String> selected) => [
    for (final c in changes)
      if (c.actionable && (c.follows == null ? selected.contains(c.id) : selected.contains(c.follows))) c,
  ];

  bool get isProfile => payload is ProfileShare;
}

String _short(Object? value) {
  final text = switch (value) {
    null => appL10n.commonNotSet,
    String s => s.isEmpty ? appL10n.pluginsEmptyValue : s,
    bool b => b ? appL10n.pluginsOnValue : appL10n.pluginsOffValue,
    num n => '$n',
    List<Object?> l => appL10n.commonItemCount(l.length),
    Map<Object?, Object?> _ => '…',
    _ => '$value',
  };
  return text.length <= 18 ? text : '${text.substring(0, 17)}…';
}

class _SettingChange {
  const _SettingChange(this.path, this.from, this.to, this.sensitive);
  final List<String> path;
  final Object? from;
  final Object? to;
  final bool sensitive;
}

/// Keys that say where requests go: a key sent to the wrong host is a leaked key.
final _endpointKey = RegExp(r'(url|uri|endpoint|host|proxy|registry)$', caseSensitive: false);

SchemaNode? _field(SchemaNode? node, String key) =>
    (node?.fields?[key] ?? (node?.type == 'dict' ? node?.inner : null))?.effective;

bool _secretAt(SettingsNamespaceView? view, List<String> path, SchemaNode? node) =>
    (node?.isSecret ?? false) ||
    (!(node?.isCredentialRef ?? false) && isSecretFieldName(path.last)) ||
    (view?.secrets.any((s) => jsonEquals(s.path, path)) ?? false);

bool _hasSecret(SettingsNamespaceView? view, List<String> path, SchemaNode? node, Object? value) {
  if (_secretAt(view, path, node)) return true;
  if (value is Map) {
    for (final MapEntry(:key, value: child) in value.entries) {
      if (key is String && _hasSecret(view, [...path, key], _field(node, key), child)) return true;
    }
  } else if (value is List) {
    for (final (i, item) in value.indexed) {
      if (_hasSecret(view, [...path, '$i'], node?.inner?.effective, item)) return true;
    }
  }
  return false;
}

bool _mentionsEndpoint(Object? value) => switch (value) {
  Map<Object?, Object?> m =>
    m.keys.any((k) => k is String && _endpointKey.hasMatch(k)) || m.values.any(_mentionsEndpoint),
  List<Object?> l => l.any(_mentionsEndpoint),
  _ => false,
};

/// What [values] would change on [view], leaf by leaf, credentials left out.
/// A list is written whole or not at all, never with shifted items. Model,
/// permission and sandbox namespaces, endpoints and credential references
/// are sensitive.
List<_SettingChange> _settingChanges(String ns, Map<String, Object?> values, SettingsNamespaceView? view) {
  final out = <_SettingChange>[];
  void visit(List<String> path, Object? from, Object? to, SchemaNode? node, bool sensitive) {
    if (_secretAt(view, path, node)) return;
    sensitive = sensitive || _endpointKey.hasMatch(path.last) || (node?.isCredentialRef ?? false);
    if (to is Map) {
      for (final MapEntry(:key, :value) in to.entries) {
        if (key is String) visit([...path, key], from is Map ? from[key] : null, value, _field(node, key), sensitive);
      }
    } else if (!_hasSecret(view, path, node, to) && !jsonEquals(from, to)) {
      out.add(_SettingChange(path, from, to, sensitive || _mentionsEndpoint(to)));
    }
  }

  final always = ns.startsWith('llm-') || const {'permission', 'bash-sandbox', 'pwsh-sandbox'}.contains(ns);
  for (final MapEntry(:key, :value) in values.entries) {
    visit([key], view?.value[key], value, view?.schema.fields?[key]?.effective, always);
  }
  return out;
}

/// Sensitive changes all show, in full; two others at most, shortened.
String _settingsDetail(List<_SettingChange> changes) {
  String value(Object? v, bool full) => full && v is String ? v : _short(v);
  final ordinary = changes.where((c) => !c.sensitive).toList();
  final shown = [
    for (final c in [...changes.where((c) => c.sensitive), ...ordinary.take(2)])
      '${c.path.join('.')} ${value(c.from, c.sensitive)} → ${value(c.to, c.sensitive)}',
  ];
  return ordinary.length > 2
      ? appL10n.pluginsSettingsChanges(shown.join(appL10n.pluginsListSeparator), changes.length)
      : shown.join(appL10n.pluginsListSeparator);
}

/// Compares [payload] with [target] (and, on the device, its files).
Future<ImportPlan> planImport(SharePayload payload, ImportTarget target, {required ShareNet net, GuestFs? fs}) async {
  final client = target.client;
  final changes = <ImportChange>[];
  final plugins = switch (payload) {
    PluginShare(:final plugin) => [plugin],
    ProfileShare(:final plugins) => plugins,
  };

  // Plugins.
  List<PluginBundle> bundles = const [];
  try {
    bundles = await client.listBundles();
  } on DshException {
    // Unknown: everything shows as an install.
  }
  final facts = <String, NpmFacts?>{};
  await Future.wait([
    for (final p in plugins)
      if (p.source == PluginSourceKind.npm && p.version != null)
        net
            .npmFacts(p.name, p.version!)
            .timeout(const Duration(seconds: 8), onTimeout: () => null)
            .then((f) => facts[p.name] = f, onError: (Object _) => facts[p.name] = null),
  ]);
  final installedAny = <String>{};
  for (final p in plugins) {
    final have = bundles.where((b) => b.name == p.name).firstOrNull;
    final id = 'plugin:${p.name}';
    if (p.source == PluginSourceKind.official) {
      if (have == null) {
        changes.add(
          ImportChange(
            id: id,
            section: ImportSection.plugins,
            title: p.displayTitle,
            kind: ChangeKind.unavailable,
            plugin: p,
            blocked: appL10n.pluginsOfficialUnavailable,
          ),
        );
      } else if (have.isOnDemand) {
        changes.add(
          ImportChange(
            id: id,
            section: ImportSection.plugins,
            title: p.displayTitle,
            kind: ChangeKind.install,
            plugin: p,
            installSpec: have.installTargetSpec,
            blocked: target.canInstall ? null : _cantInstall(target),
          ),
        );
      } else if (have.enabled) {
        changes.add(
          ImportChange(
            id: id,
            section: ImportSection.plugins,
            title: p.displayTitle,
            kind: ChangeKind.unchanged,
            plugin: p,
            detail: appL10n.pluginsEnabled,
          ),
        );
      } else {
        changes.add(
          ImportChange(
            id: id,
            section: ImportSection.plugins,
            title: p.displayTitle,
            kind: ChangeKind.enable,
            plugin: p,
            blocked: target.safeMode ? _cantInstall(target) : null,
          ),
        );
      }
      continue;
    }
    final f = facts[p.name];
    final integrity = switch ((p.integrity, f?.integrity)) {
      (final want?, final got?) => want == got ? IntegrityStatus.verified : IntegrityStatus.mismatch,
      _ => IntegrityStatus.unverifiable,
    };
    final installed = have != null && have.installed;
    final sameVersion = installed && p.version != null && have.version == p.version;
    final kind = sameVersion ? ChangeKind.unchanged : (installed ? ChangeKind.upgrade : ChangeKind.install);
    String? blocked;
    if (kind != ChangeKind.unchanged) {
      if (integrity == IntegrityStatus.mismatch) {
        blocked = appL10n.pluginsVersionMismatch;
      } else if (!target.canInstall) {
        blocked = _cantInstall(target);
      }
    }
    if (kind != ChangeKind.unchanged && blocked == null) installedAny.add(p.name);
    changes.add(
      ImportChange(
        id: id,
        section: ImportSection.plugins,
        title: p.displayTitle,
        kind: kind,
        plugin: p,
        fromVersion: installed ? have.version : null,
        integrity: integrity,
        facts: f,
        installSpec: p.spec,
        detail: switch (kind) {
          ChangeKind.unchanged => appL10n.commonInstalled,
          ChangeKind.upgrade =>
            '${have?.version ?? appL10n.pluginsCurrentVersion} → ${p.version ?? p.gitRef ?? appL10n.pluginsNewVersion}',
          _ => p.version ?? p.gitRef,
        },
        blocked: blocked,
      ),
    );
  }

  if (payload is ProfileShare) {
    // Presets ride with their plugin.
    List<AgentPresetInfo> existing = const [];
    try {
      existing = await client.listAgentPresets();
    } on DshException {
      // Treated as none.
    }
    for (final preset in payload.presets) {
      if (existing.any((e) => e.id == preset.id)) continue;
      final owner = preset.bundle == null ? null : 'plugin:${preset.bundle}';
      final ownerChange = changes.where((c) => c.id == owner).firstOrNull;
      if (ownerChange == null || !ownerChange.actionable) continue;
      changes.add(
        ImportChange(
          id: 'preset:${preset.id}',
          section: ImportSection.presets,
          title: preset.displayName,
          kind: ChangeKind.add,
          detail: appL10n.pluginsAddedWith(ownerChange.title),
          follows: owner,
        ),
      );
    }

    // Settings.
    Map<String, SettingsNamespaceView> views = const {};
    var settingsWritable = true;
    var settingsUnread = false;
    try {
      final description = await client.describeSettings();
      views = description.namespaces;
      settingsWritable = description.writable;
    } on DshException {
      settingsWritable = false;
      settingsUnread = true;
    }
    for (final MapEntry(key: ns, value: values) in payload.settings.entries) {
      final id = 'settings:$ns';
      final title = namespaceLabel(ns);
      final mono = !hasNamespaceLabel(ns);
      final view = views[ns];
      final diffs = _settingChanges(ns, values, view);
      if (diffs.isEmpty) continue;
      // Shown in full and left for the person to tick.
      final sensitive = diffs.any((d) => d.sensitive);
      if (view == null) {
        final later = installedAny.isNotEmpty;
        changes.add(
          ImportChange(
            id: id,
            section: ImportSection.settings,
            title: title,
            monoTitle: mono,
            kind: later ? ChangeKind.add : ChangeKind.unavailable,
            detail: later ? appL10n.pluginsApplyAfterInstall(_settingsDetail(diffs)) : null,
            defaultOn: !sensitive,
            sensitive: sensitive,
            blocked: settingsUnread
                ? appL10n.pluginsSettingsReadFailed
                : (later ? null : appL10n.pluginsSettingUnavailable),
            ops: [for (final d in diffs) SettingsOp.set(d.path, d.to)],
          ),
        );
        continue;
      }
      // New when nothing was set there before; a change otherwise.
      final adds = diffs.every((d) => d.from == null);
      changes.add(
        ImportChange(
          id: id,
          section: ImportSection.settings,
          title: title,
          monoTitle: mono,
          kind: adds ? ChangeKind.add : ChangeKind.change,
          detail: _settingsDetail(diffs),
          defaultOn: !sensitive,
          sensitive: sensitive,
          blocked: settingsWritable && view.writable ? null : appL10n.pluginsSettingsReadOnly,
          ops: [for (final d in diffs) SettingsOp.set(d.path, d.to)],
        ),
      );
    }

    // Skills and AGENTS.md: only the on-device engine's files can be written.
    final files = target.isLocal ? fs : null;
    for (final skill in payload.skills) {
      final id = 'skill:${skill.name}';
      if (files == null) {
        changes.add(
          ImportChange(
            id: id,
            section: ImportSection.skills,
            title: skill.name,
            kind: ChangeKind.unavailable,
            blocked: appL10n.pluginsImportLocalOnly,
            skill: skill,
          ),
        );
        continue;
      }
      Map<String, String>? current;
      try {
        final bytes = files.readSkillForImport(skill.name);
        current = bytes?.map((path, value) => MapEntry(path, utf8.decode(value)));
      } on Object catch (error) {
        if (error is! FileSystemException && error is! FormatException) rethrow;
        changes.add(
          ImportChange(
            id: id,
            section: ImportSection.skills,
            title: skill.name,
            kind: ChangeKind.unavailable,
            blocked: appL10n.pluginsFileWriteFailed,
            defaultOn: false,
            skill: skill,
          ),
        );
        continue;
      }
      if (current != null && _sameFiles(current, skill.files)) continue;
      changes.add(
        ImportChange(
          id: id,
          section: ImportSection.skills,
          title: skill.name,
          kind: current == null ? ChangeKind.add : ChangeKind.change,
          detail: current == null ? null : appL10n.pluginsReplaceSkill,
          defaultOn: false,
          skill: skill,
        ),
      );
    }
    if (payload.agentsMd case final text?) {
      if (files == null) {
        changes.add(
          ImportChange(
            id: 'agents-md',
            section: ImportSection.agentsMd,
            title: 'AGENTS.md',
            kind: ChangeKind.unavailable,
            blocked: appL10n.pluginsImportLocalOnly,
            text: text,
          ),
        );
      } else {
        final current = await files.readImportedAgentsMd();
        if (current?.trim() != text.trim()) {
          changes.add(
            ImportChange(
              id: 'agents-md',
              section: ImportSection.agentsMd,
              title: 'AGENTS.md',
              kind: current == null ? ChangeKind.add : ChangeKind.change,
              detail: current == null
                  ? appL10n.pluginsLineCount(text.split('\n').length)
                  : appL10n.pluginsReplaceContent,
              defaultOn: false,
              text: text,
            ),
          );
        }
      }
    }
  }
  return ImportPlan(payload: payload, target: target, changes: changes);
}

bool _sameFiles(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key]?.trim() == e.value.trim());

String _cantInstall(ImportTarget target) => target.safeMode
    ? appL10n.pluginsSafeModeInstallBlocked
    : target.installRefused
    ? appL10n.marketInstallRefused
    : appL10n.pluginsHostInstallBlocked;

// ── Applying ─────────────────────────────────────────────────────────────────

enum ImportStepState { pending, running, done, failed, skipped }

class StepStatus {
  const StepStatus(this.state, [this.message]);

  static const pending = StepStatus(ImportStepState.pending);
  static const running = StepStatus(ImportStepState.running);
  static const done = StepStatus(ImportStepState.done);

  final ImportStepState state;

  /// Why it failed, or a short note (`重启后生效`).
  final String? message;
}

/// One plugin step's outcome.
class PluginStepOutcome {
  const PluginStepOutcome.ok({this.needsRestart = false}) : ok = true, error = null;
  const PluginStepOutcome.failed(String this.error) : ok = false, needsRestart = false;

  final bool ok;
  final bool needsRestart;
  final String? error;
}

/// How plugin changes reach the target (the active host's install queue, or
/// the target's client directly). A seam for tests.
abstract class ImportPluginRunner {
  Future<PluginStepOutcome> install(PluginInstallRequest request);
  Future<PluginStepOutcome> enable(String name);
}

/// Straight to a host's plugin manager (a target that isn't the active host).
class DirectPluginRunner implements ImportPluginRunner {
  DirectPluginRunner(this.client, {required this.isLocal});

  final DshClient client;
  final bool isLocal;
  static var _seq = 0;

  @override
  Future<PluginStepOutcome> install(PluginInstallRequest request) async {
    try {
      if (request.replaceInstalled) {
        final removed = await client.removeBundle(request.name);
        if (!removed.succeeded) {
          return PluginStepOutcome.failed(describeOperationFailure(removed, isLocal: isLocal).title);
        }
      }
      final result = await client.installBundle(
        request.spec,
        requestId: 'dsh-app-share-${DateTime.now().microsecondsSinceEpoch}-${_seq++}',
        enabled: true,
        saveExact: true,
        registry: request.registry,
      );
      if (result.succeeded) return PluginStepOutcome.ok(needsRestart: request.needsRestartAfter(result));
      return PluginStepOutcome.failed(describeOperationFailure(result, isLocal: isLocal).title);
    } on Object catch (error) {
      return PluginStepOutcome.failed(describePluginError(error).title);
    }
  }

  @override
  Future<PluginStepOutcome> enable(String name) async {
    try {
      final result = await client.setBundleEnabled(name, true);
      if (result.succeeded) return PluginStepOutcome.ok(needsRestart: result.needsRestart);
      return PluginStepOutcome.failed(describeOperationFailure(result, isLocal: isLocal).title);
    } on Object catch (error) {
      return PluginStepOutcome.failed(describePluginError(error).title);
    }
  }
}

/// The active host's install queue (progress also shows on the plugin pages).
class QueuedPluginRunner implements ImportPluginRunner {
  QueuedPluginRunner(this.installs, this.client, {required this.isLocal});

  final PluginInstallsController installs;
  final DshClient client;
  final bool isLocal;

  @override
  Future<PluginStepOutcome> install(PluginInstallRequest request) async {
    final job = await installs.install(request);
    return switch (job.phase) {
      PluginInstallPhase.succeeded => PluginStepOutcome.ok(needsRestart: job.needsRestart),
      PluginInstallPhase.cancelled => PluginStepOutcome.failed(appL10n.commonCancelled),
      _ => PluginStepOutcome.failed(job.failure?.title ?? appL10n.pluginsInstallFailed),
    };
  }

  @override
  Future<PluginStepOutcome> enable(String name) => DirectPluginRunner(client, isLocal: isLocal).enable(name);
}

class ImportResult {
  const ImportResult({required this.statuses, required this.needsRestart, required this.restorePoint});

  final Map<String, StepStatus> statuses;
  final bool needsRestart;

  /// A restore point was recorded before anything changed.
  final bool restorePoint;

  int get failed => statuses.values.where((s) => s.state == ImportStepState.failed).length;
  int get done => statuses.values.where((s) => s.state == ImportStepState.done).length;
}

/// Applies [plan]'s ticked changes; [onStep] reports each row as it moves.
Future<ImportResult> applyImport(
  ImportPlan plan,
  Set<String> selected, {
  required ImportPluginRunner runner,
  GuestFs? fs,
  void Function(String id, StepStatus status)? onStep,
  bool Function()? cancelled,
  DateTime Function() now = DateTime.now,
}) async {
  final steps = plan.selected(selected);
  final statuses = {for (final s in steps) s.id: StepStatus.pending};
  void set(String id, StepStatus status) {
    statuses[id] = status;
    onStep?.call(id, status);
  }

  final target = plan.target;
  final files = target.isLocal ? fs : null;
  var restorePoint = false;
  if (plan.isProfile && target.isLocal && files != null) {
    restorePoint = await RestorePoint(files).pinCurrentProfile(now: now());
  }
  final backup = files == null ? null : RestorePoint(files).backupDir(now());
  var needsRestart = false;
  final pluginOk = <String, bool>{};

  for (final step in steps.where((s) => s.section == ImportSection.plugins)) {
    if (cancelled?.call() ?? false) break;
    set(step.id, StepStatus.running);
    final plugin = step.plugin!;
    final PluginStepOutcome outcome;
    if (step.kind == ChangeKind.enable) {
      outcome = await runner.enable(plugin.name);
    } else {
      outcome = await runner.install(
        PluginInstallRequest(
          name: plugin.name,
          spec: step.installSpec ?? plugin.spec!,
          title: plugin.displayTitle,
          replaceInstalled: step.kind == ChangeKind.upgrade,
        ),
      );
    }
    pluginOk[step.id] = outcome.ok;
    needsRestart = needsRestart || outcome.needsRestart;
    set(
      step.id,
      outcome.ok
          ? StepStatus(ImportStepState.done, outcome.needsRestart ? appL10n.pluginsAfterRestart : null)
          : StepStatus(ImportStepState.failed, outcome.error),
    );
  }
  for (final step in steps.where((s) => s.section == ImportSection.presets)) {
    final ok = pluginOk[step.follows];
    set(step.id, ok == true ? StepStatus.done : const StepStatus(ImportStepState.skipped));
  }

  final settingsSteps = steps.where((s) => s.section == ImportSection.settings).toList();
  if (settingsSteps.isNotEmpty && !(cancelled?.call() ?? false)) {
    // Fresh revisions (and namespaces the plugins just added).
    Map<String, SettingsNamespaceView> views = const {};
    try {
      views = (await target.client.describeSettings()).namespaces;
    } on DshException {
      // Each write below reports its own failure.
    }
    for (final step in settingsSteps) {
      if (cancelled?.call() ?? false) break;
      final ns = step.id.substring('settings:'.length);
      set(step.id, StepStatus.running);
      final view = views[ns];
      if (view == null) {
        set(step.id, StepStatus(ImportStepState.skipped, appL10n.pluginsSettingUnavailable));
        continue;
      }
      try {
        await target.client.mutateSettingsView(ns, step.ops, expectedRevision: view.revision);
        set(step.id, StepStatus.done);
      } on DshRemoteException catch (e) {
        set(
          step.id,
          StepStatus(
            ImportStepState.failed,
            e.code == 'settings/conflict' ? appL10n.pluginsSettingsChanged : appL10n.pluginsWriteFailed,
          ),
        );
      } on DshException {
        set(step.id, StepStatus(ImportStepState.failed, appL10n.pluginsHostUnreachable));
      }
    }
  }

  for (final step in steps.where((s) => s.section == ImportSection.skills || s.section == ImportSection.agentsMd)) {
    if (cancelled?.call() ?? false) break;
    if (files == null || backup == null) {
      set(step.id, const StepStatus(ImportStepState.skipped));
      continue;
    }
    set(step.id, StepStatus.running);
    try {
      final point = RestorePoint(files);
      if (step.section == ImportSection.skills) {
        point.replaceSkill(backup, step.skill!);
      } else {
        await point.backupAgentsMd(backup);
        await files.writeImportedAgentsMd(step.text!);
      }
      set(step.id, StepStatus.done);
    } catch (_) {
      set(step.id, StepStatus(ImportStepState.failed, appL10n.pluginsFileWriteFailed));
    }
  }
  for (final s in steps) {
    if (statuses[s.id]?.state == ImportStepState.pending) set(s.id, const StepStatus(ImportStepState.skipped));
  }
  return ImportResult(statuses: statuses, needsRestart: needsRestart, restorePoint: restorePoint);
}
