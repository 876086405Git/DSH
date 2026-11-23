// Dart side of the `dsh/phone` method channel and `dsh/phone/events` event
// channel (the native side is PhonePlugin.kt). The native module is
// built separately; every call here tolerates it being absent
// (MissingPluginException → "未就绪") or failing (PlatformException → a reason).

import 'dart:async';

import 'package:flutter/services.dart';

import '../l10n/l10n.dart';
import 'phone_skill.dart';
import 'phone_skill_replay.dart';

export 'phone_skill.dart';
export 'phone_skill_replay.dart';

// ── Wire helpers ─────────────────────────────────────────────────────────────

bool _flag(Object? v) => v == true;

bool? _maybeFlag(Object? v) => v is bool ? v : null;

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

int? _int(Object? v) => v is num ? v.toInt() : null;

Map<Object?, Object?> _map(Object? v) => v is Map ? v.cast<Object?, Object?>() : const {};

List<String> _strings(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is String && e.isNotEmpty) e,
      ]
    : const [];

/// Shown when the native module isn't in this build (or hasn't registered yet).
String get phoneNotReadyReason => appL10n.statePhoneNotReady;

// ── Status ───────────────────────────────────────────────────────────────────

/// Where 不打扰模式 gets its shell identity from.
enum PhoneBackgroundMode {
  off,
  shizuku,
  adb;

  static PhoneBackgroundMode parse(Object? wire) => switch (wire) {
    'shizuku' => shizuku,
    'adb' => adb,
    _ => off,
  };
}

/// Versioned privilege choices. The legacy three-way enum remains stable for existing pages.
enum PhonePrivilegedMode {
  off,
  shizuku,
  sui,
  root,
  adb;

  static PhonePrivilegedMode? tryParse(Object? wire) => switch (wire) {
    'off' => off,
    'shizuku' => shizuku,
    'sui' => sui,
    'root' => root,
    'adb' => adb,
    _ => null,
  };
}

class PhoneRootStatus {
  const PhoneRootStatus({
    this.checked = false,
    this.available,
    this.connected = false,
    this.starting = false,
    this.reasonCode,
  });

  factory PhoneRootStatus.fromMap(Map<Object?, Object?> m) => PhoneRootStatus(
    checked: _flag(m['checked']),
    available: _maybeFlag(m['available']),
    connected: _flag(m['connected']),
    starting: _flag(m['starting']),
    reasonCode: _text(m['reasonCode']),
  );

  final bool checked;
  final bool? available;
  final bool connected;
  final bool starting;
  final String? reasonCode;
}

enum PhoneKeepPhase {
  disabled,
  idle,
  restoring,
  connected,
  waiting,
  failed;

  static PhoneKeepPhase parse(Object? wire) => values.asNameMap()[wire] ?? waiting;
}

/// Persisted keep intent and its transport state; connected does not imply display/input readiness.
class PhonePrivilegedKeepStatus {
  const PhonePrivilegedKeepStatus({
    this.enabled = false,
    this.mode = PhonePrivilegedMode.off,
    this.phase = PhoneKeepPhase.disabled,
    this.reasonCode,
  });

  factory PhonePrivilegedKeepStatus.parse(Object? value) {
    final m = _map(value);
    if (m.isEmpty) return const PhonePrivilegedKeepStatus();
    return PhonePrivilegedKeepStatus(
      enabled: _flag(m['enabled']),
      mode: PhonePrivilegedMode.tryParse(m['mode']) ?? PhonePrivilegedMode.off,
      phase: PhoneKeepPhase.parse(m['phase']),
      reasonCode: _text(m['reasonCode']),
    );
  }

  final bool enabled;
  final PhonePrivilegedMode mode;
  final PhoneKeepPhase phase;
  final String? reasonCode;
}

class PhonePrivilegedStatus {
  const PhonePrivilegedStatus({
    this.mode = PhonePrivilegedMode.off,
    this.ready = false,
    this.reason,
    this.supportedModes = const [],
    this.recommendedMode = PhonePrivilegedMode.off,
    this.grantPath = 'setup',
    this.rootSelected = false,
    this.keep = const PhonePrivilegedKeepStatus(),
  });

  static PhonePrivilegedStatus? parse(Object? value) {
    final m = _map(value);
    if (m['v'] is! int || m['v'] != 1) return null;
    final parsed = PhonePrivilegedMode.tryParse(m['mode']);
    final supported = [for (final name in _strings(m['supportedModes'])) ?PhonePrivilegedMode.tryParse(name)];
    final recommended = PhonePrivilegedMode.tryParse(m['recommendedMode']);
    const grantPaths = {'granted', 'shizuku', 'shizukuPermission', 'sui', 'suiPermission', 'root', 'adb', 'setup'};
    return PhonePrivilegedStatus(
      mode: parsed ?? PhonePrivilegedMode.off,
      ready: supported.contains(parsed) && _flag(m['ready']),
      reason: _text(m['reason']),
      supportedModes: supported.toSet().toList(),
      recommendedMode: supported.contains(recommended) ? recommended! : PhonePrivilegedMode.off,
      grantPath: grantPaths.contains(m['grantPath']) ? m['grantPath'] as String : 'setup',
      rootSelected: _flag(m['rootSelected']),
      keep: PhonePrivilegedKeepStatus.parse(m['keep']),
    );
  }

  final PhonePrivilegedMode mode;
  final bool ready;
  final String? reason;
  final List<PhonePrivilegedMode> supportedModes;
  final PhonePrivilegedMode recommendedMode;
  final String grantPath;
  final bool rootSelected;
  final PhonePrivilegedKeepStatus keep;
}

class PhoneA11yStatus {
  const PhoneA11yStatus({this.enabled = false, this.serviceConnected = false});

  factory PhoneA11yStatus.fromMap(Map<Object?, Object?> m) =>
      PhoneA11yStatus(enabled: _flag(m['enabled']), serviceConnected: _flag(m['serviceConnected']));

  /// The user turned DSH on in the system accessibility settings.
  final bool enabled;

  /// The service is bound and answering (false right after a force stop).
  final bool serviceConnected;

  bool get ok => enabled && serviceConnected;
}

class ShizukuStatus {
  const ShizukuStatus({
    this.installed = false,
    this.running = false,
    this.granted = false,
    this.provider,
    this.appInstalled,
  });

  factory ShizukuStatus.fromMap(Map<Object?, Object?> m) => ShizukuStatus(
    installed: _flag(m['installed']),
    running: _flag(m['running']),
    granted: _flag(m['granted']),
    provider: const ['shizuku', 'sui'].contains(m['provider']) ? m['provider'] as String : null,
    appInstalled: _maybeFlag(m['appInstalled']),
  );

  final bool installed;
  final bool running;
  final bool granted;
  final String? provider;
  final bool? appInstalled;
}

class AdbStatus {
  const AdbStatus({this.wirelessDebugging, this.paired = false, this.connected = false});

  factory AdbStatus.fromMap(Map<Object?, Object?> m) => AdbStatus(
    wirelessDebugging: _maybeFlag(m['wirelessDebugging']),
    paired: _flag(m['paired']),
    connected: _flag(m['connected']),
  );

  /// Null when the system won't say (Android 17 hides the ADB settings from apps).
  final bool? wirelessDebugging;
  final bool paired;
  final bool connected;
}

enum PhoneBackgroundViewport {
  portrait, landscape;

  /// Native preference capability, not proof that the privileged peer can create landscape.
  static PhoneBackgroundViewport? fromMap(Map<Object?, Object?> m) {
    if (m['v'] is! int || m['v'] != 1) return null;
    return switch (m['preset']) {
      'portrait' => portrait,
      'landscape' => landscape,
      _ => null,
    };
  }
}

/// Native admission capacity, independent of the legacy global parallelLimit field.
class BackgroundParallelism {
  const BackgroundParallelism._(this.configuredLimit, this.effectiveLimit, this.heldSlots, this.reason);

  final int configuredLimit;
  final int effectiveLimit;
  final int heldSlots;
  final String? reason;

  static BackgroundParallelism? parse(Object? value) {
    if (value is! Map || value['v'] is! int || value['v'] != 1) return null;
    final configured = value['configuredLimit'];
    final effective = value['effectiveLimit'];
    final held = value['heldSlots'];
    final reason = value['reason'];
    if (configured is! int || configured < 1 || configured > 3 ||
        effective is! int || effective < 0 || effective > configured ||
        held is! int || held < 0 || held > 3) {
      return null;
    }
    if (reason != null &&
        !const {'off', 'unsupported', 'connectionRequired', 'busy', 'transportSerial'}.contains(reason)) {
      return null;
    }
    if (effective == 0 && reason == null) return null;
    return BackgroundParallelism._(configured, effective, held, reason as String?);
  }
}

class PhoneBackgroundStatus {
  const PhoneBackgroundStatus({
    this.mode = PhoneBackgroundMode.off,
    this.ready = false,
    this.reason,
    this.androidOk = false,
    this.shizuku = const ShizukuStatus(),
    this.adb = const AdbStatus(),
    this.root = const PhoneRootStatus(),
    this.privileged,
    this.viewport,
    this.previewVersion,
    this.previewEnabled = false,
    this.parallelism,
  });

  factory PhoneBackgroundStatus.fromMap(Map<Object?, Object?> m) => PhoneBackgroundStatus(
    mode: PhoneBackgroundMode.parse(m['mode']),
    ready: _flag(m['ready']),
    reason: _text(m['reason']),
    androidOk: _flag(m['androidOk']),
    shizuku: ShizukuStatus.fromMap(_map(m['shizuku'])),
    adb: AdbStatus.fromMap(_map(m['adb'])),
    root: PhoneRootStatus.fromMap(_map(m['root'])),
    privileged: PhonePrivilegedStatus.parse(m['privileged']),
    viewport: PhoneBackgroundViewport.fromMap(_map(m['viewport'])),
    previewVersion: _int(_map(m['preview'])['v']),
    previewEnabled: _flag(_map(m['preview'])['enabled']),
    parallelism: BackgroundParallelism.parse(m['parallelism']),
  );

  final PhoneBackgroundMode mode;

  /// The chosen mode can drive a virtual display right now.
  final bool ready;

  /// Why not, one Chinese sentence from the native side.
  final String? reason;

  /// Android 14 or later (the practical floor).
  final bool androidOk;
  final ShizukuStatus shizuku;
  final AdbStatus adb;
  final PhoneRootStatus root;
  final PhonePrivilegedStatus? privileged;
  final PhoneBackgroundViewport? viewport;
  final int? previewVersion;
  final bool previewEnabled;
  final BackgroundParallelism? parallelism;

  PhonePrivilegedMode get effectiveMode =>
      privileged?.mode ??
      switch (mode) {
        PhoneBackgroundMode.off => PhonePrivilegedMode.off,
        PhoneBackgroundMode.shizuku => PhonePrivilegedMode.shizuku,
        PhoneBackgroundMode.adb => PhonePrivilegedMode.adb,
      };

  bool get effectiveReady => privileged?.ready ?? ready;
  String? get effectiveReason => privileged == null ? reason : privileged!.reason;

  PhonePrivilegedKeepStatus get keep => privileged?.keep ?? const PhonePrivilegedKeepStatus();

  List<PhonePrivilegedMode> get supportedModes =>
      privileged?.supportedModes ??
      const [PhonePrivilegedMode.off, PhonePrivilegedMode.shizuku, PhonePrivilegedMode.adb];
}

/// Only the caller's target is published; no holder/session/UID is retained here.
class PhoneAppWait {
  const PhoneAppWait._(this.packageName);

  /// Null means that the current interface has no confirmed app identity.
  final String? packageName;

  static PhoneAppWait? fromValue(Object? value) {
    if (value is! Map) return null;
    if (value['kind'] == 'unknown' && !value.containsKey('packageName')) return const PhoneAppWait._(null);
    if (value['kind'] != 'known') return null;
    final packageName = _text(value['packageName']);
    return packageName == null ? null : PhoneAppWait._(packageName);
  }
}

class PhoneTaskStatus {
  const PhoneTaskStatus({
    this.sessionId,
    this.runId,
    this.generation,
    this.waitingForScreen,
    this.backgroundSlot,
    this.waitingForApp,
    this.waitingForMs = 0,
    this.pendingCalls = 0,
    this.finishing = false,
    this.draining = false,
    this.endedRunId,
    this.endedGeneration,
    this.completion = 'unknown',
    this.retiring = false,
    this.cleanupFailed = false,
    this.settling = false,
    this.id,
    this.active = false,
    this.app,
    this.paused = false,
    this.stopped = false,
    this.interrupted,
    this.stopSource,
    this.waived = false,
    this.ownerSessionId,
  });

  factory PhoneTaskStatus.fromMap(Map<Object?, Object?> m) => PhoneTaskStatus(
    sessionId: _text(m['sessionId']),
    runId: _text(m['runId']),
    generation: _int(m['generation']),
    waitingForScreen: _text(m['waitingForScreen']),
    backgroundSlot: m.containsKey('backgroundSlot') ? m['backgroundSlot'] is bool && m['backgroundSlot'] == true : null,
    waitingForApp: PhoneAppWait.fromValue(m['waitingForApp']),
    waitingForMs: m['waitingForMs'] is int && (m['waitingForMs'] as int) >= 0 ? m['waitingForMs'] as int : 0,
    pendingCalls: _int(m['pendingCalls']) ?? 0,
    finishing: _flag(m['finishing']),
    draining: _flag(m['draining']),
    endedRunId: _text(m['endedRunId']),
    endedGeneration: _int(m['endedGeneration']),
    retiring: _flag(m['retiring']),
    cleanupFailed: _flag(m['cleanupFailed']),
    settling: _flag(m['settling']),
    completion: const {'completed', 'other', 'unknown'}.contains(m['completion']) ? m['completion'] as String : 'unknown',
    id: _int(m['id']),
    active: _flag(m['active']),
    app: _text(m['app']),
    paused: _flag(m['paused']),
    stopped: _flag(m['stopped']),
    interrupted: m.containsKey('interrupted') ? _flag(m['interrupted']) : null,
    stopSource: m.containsKey('stopSource') ? (_text(m['stopSource']) ?? 'UNKNOWN') : null,
    waived: _flag(m['waived']),
    ownerSessionId: _text(m['ownerSessionId']),
  );

  final String? sessionId;
  final String? runId;
  final int? generation;
  final String? waitingForScreen;
  /// Null only for absent legacy metadata; malformed present values never grant a slot.
  final bool? backgroundSlot;
  final PhoneAppWait? waitingForApp;
  final int waitingForMs;
  bool get waitingForResources => waitingForApp != null || const {'main', 'background'}.contains(waitingForScreen);
  final int pendingCalls;
  final bool finishing;
  final bool draining;
  final String? endedRunId;
  final int? endedGeneration;
  final String completion;
  final bool retiring;
  final bool cleanupFailed;
  final bool settling;

  /// The current (or last) task's number; a new one means a new task even
  /// when no inactive status came in between. Null from older builds.
  final int? id;

  final bool active;

  /// Label of the app being driven, when known.
  final String? app;
  final bool paused;

  /// Native refuses phone actions after a user stop or an ambient interruption.
  final bool stopped;

  /// Whether this stop cut off a phone task that was running, recorded by native at the
  /// moment it stopped. Null only from an older native that doesn't report it; a present
  /// value of the wrong type is false, never a reason to guess.
  final bool? interrupted;

  /// USER, SCREEN_OFF or ENVIRONMENT; null only when absent on older native.
  final String? stopSource;

  /// 本任务免确认 was granted: the rest of this task asks nothing.
  final bool waived;

  /// Explicit owner supplied by the authenticated iOS engine bridge.
  final String? ownerSessionId;
}

List<PhoneTaskStatus> _phoneTasks(Map<Object?, Object?> m) => m['taskProtocol'] == 1 && m['tasks'] is List
    ? [for (final item in m['tasks'] as List) if (item is Map) PhoneTaskStatus.fromMap(item.cast<Object?, Object?>())]
    : const [];

PhoneTaskStatus _selectedPhoneTask(Map<Object?, Object?> m) {
  final selected = _int(m['selectedTaskId']);
  if (selected != null) {
    for (final task in _phoneTasks(m)) {
      if (task.id == selected) return task;
    }
  }
  return PhoneTaskStatus.fromMap(_map(m['task']));
}

/// Where Android 13+'s 「受限制的设置」 stands for this app (native
/// `RestrictedSettings.kt`).
enum RestrictedSettingsState {
  /// The accessibility switch is greyed out, and App info's ⋮ has nothing yet:
  /// a tap on the switch comes first (it shows the 「受限制的设置」 dialog).
  guarded,

  /// The dialog was seen: App info's ⋮ offers 「允许受限制的设置」.
  acknowledged,

  /// Not restricted (a store install, an older Android, or allowed already).
  clear;

  static RestrictedSettingsState? parse(Object? wire) => values.asNameMap()[wire is String ? wire : null];
}

/// Device facts for the guidance pages. Not in the channel contract yet: read
/// from an optional `device` entry of `status` and null when absent.
class PhoneDevice {
  const PhoneDevice({this.manufacturer, this.sdkInt, this.sideloaded, this.restricted});

  factory PhoneDevice.fromMap(Map<Object?, Object?> m) => PhoneDevice(
    manufacturer: _text(m['manufacturer']),
    sdkInt: _int(m['sdkInt']),
    sideloaded: _maybeFlag(m['sideloaded']),
    restricted: RestrictedSettingsState.parse(m['restricted']),
  );

  /// `Build.MANUFACTURER`, e.g. `vivo`, `Xiaomi`, `HONOR`.
  final String? manufacturer;
  final int? sdkInt;

  /// Installed from a browser or file manager (restricted settings apply on 13+).
  final bool? sideloaded;

  /// The restriction as the system holds it; null when it can't be told.
  final RestrictedSettingsState? restricted;

  /// Whether Android's "restricted settings" can block the accessibility switch.
  /// Unknown facts count as "maybe": the guide is a hint, not a gate.
  bool get mayNeedRestrictedSettings => switch (restricted) {
    RestrictedSettingsState.guarded || RestrictedSettingsState.acknowledged => true,
    RestrictedSettingsState.clear => false,
    null => (sdkInt == null || sdkInt! >= 33) && sideloaded != false,
  };
}

class A11yKeeperStatus {
  const A11yKeeperStatus({this.granted = false, this.path = 'setup', this.command = ''});

  factory A11yKeeperStatus.fromMap(Map<Object?, Object?> m) => A11yKeeperStatus(
    granted: _flag(m['granted']),
    path: _text(m['path']) ?? 'setup',
    command: _text(m['command']) ?? '',
  );

  final bool granted;
  final String path;
  final String command;
}

/// Snapshot of the native phone-control module (`status` / status events).
/// Logical interruption only; never an active task or a physical cleanup receipt.
class PhoneTaskInterruption {
  const PhoneTaskInterruption({this.state = 'ready', this.count = 0, this.batchToken, this.error});
  final String state;
  final int count;
  final String? batchToken;
  final String? error;
  bool get visible => state != 'ready' || count > 0;
  bool get canAcknowledge => state == 'ready' && count > 0 && batchToken != null;

  static PhoneTaskInterruption parse(Object? raw) {
    if (raw == null) return const PhoneTaskInterruption(); // Older native modules.
    const invalid = PhoneTaskInterruption(state: 'error', error: 'loadFailed');
    if (raw is! Map || raw['version'] is! int || raw['version'] != 1) return invalid;
    final state = raw['state'];
    final count = raw['count'];
    final token = raw['batchToken'];
    final error = raw['error'];
    if (state is! String || !const ['loading', 'ready', 'error'].contains(state) ||
        count is! int || count < 0 || count > 256) {
      return invalid;
    }
    if (state == 'ready') {
      if (error != null || (count == 0 && token != null)) return invalid;
      if (count > 0 && (token is! String ||
          !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$').hasMatch(token))) {
        return invalid;
      }
    } else if (token != null || (state == 'loading' && (error != null || count != 0)) ||
        (state == 'error' && error != 'loadFailed' && error != 'writeFailed')) {
      return invalid;
    }
    return PhoneTaskInterruption(state: state, count: count, batchToken: token as String?, error: error as String?);
  }
}

/// Native launch history; this counter is not an execution token.
class PhoneCallerCapability {
  const PhoneCallerCapability(this.launch, this.modernSeen);
  final int launch;
  final bool modernSeen;

  static PhoneCallerCapability? parse(Object? value) {
    if (value is! Map) return null;
    final launch = value['launch'];
    final modern = value['modernSeen'];
    return launch is int && launch >= 0 && modern is bool ? PhoneCallerCapability(launch, modern) : null;
  }
}

class PhoneStatus {
  static const _keepError = Object();
  const PhoneStatus({
    this.ready = true,
    this.statusRevision,
    this.statusRevisionPresent = false,
    this.error,
    this.enabled = false,
    this.bridgeListening = false,
    this.a11y = const PhoneA11yStatus(),
    this.a11yKeeper = const A11yKeeperStatus(),
    this.overlay = false,
    this.notifications = false,
    this.confirmationNotifications,
    this.background = const PhoneBackgroundStatus(),
    this.task = const PhoneTaskStatus(),
    this.taskProtocol = 0,
    this.callerCapability,
    this.tasks = const [],
    this.parallelLimit = 1,
    this.device = const PhoneDevice(),
    this.taskInterruption = const PhoneTaskInterruption(),
  });

  /// The native module isn't there (or failed to answer): "未就绪".
  const PhoneStatus.notReady([this.error])
    : ready = false,
      statusRevision = null,
      statusRevisionPresent = false,
      enabled = false,
      bridgeListening = false,
      a11y = const PhoneA11yStatus(),
      a11yKeeper = const A11yKeeperStatus(),
      overlay = false,
      notifications = false,
      confirmationNotifications = null,
      background = const PhoneBackgroundStatus(),
      task = const PhoneTaskStatus(),
      taskProtocol = 0,
      callerCapability = null,
      tasks = const [],
      parallelLimit = 1,
      device = const PhoneDevice(),
      taskInterruption = const PhoneTaskInterruption();

  factory PhoneStatus.fromMap(Map<Object?, Object?> m) => PhoneStatus(
    statusRevision: m['statusRevision'] is int && (m['statusRevision'] as int) > 0
        ? m['statusRevision'] as int : null,
    statusRevisionPresent: m.containsKey('statusRevision'),
    enabled: _flag(m['enabled']),
    bridgeListening: _flag(m['bridgeListening']),
    a11y: PhoneA11yStatus.fromMap(_map(m['a11y'])),
    a11yKeeper: A11yKeeperStatus.fromMap(_map(m['a11yKeeper'])),
    overlay: _flag(m['overlay']),
    notifications: _flag(m['notifications']),
    confirmationNotifications: _maybeFlag(m['confirmationNotifications']),
    background: PhoneBackgroundStatus.fromMap(_map(m['background'])),
    task: _selectedPhoneTask(m),
    taskProtocol: m['taskProtocol'] == 1 ? 1 : 0,
    callerCapability: PhoneCallerCapability.parse(m['callerCapability']),
    tasks: _phoneTasks(m),
    parallelLimit: _int(m['parallelLimit']) ?? 1,
    device: PhoneDevice.fromMap(_map(m['device'])),
    taskInterruption: PhoneTaskInterruption.parse(m['taskInterruption']),
  );

  /// Whether native status is currently available. On transport failure the
  /// other fields may retain the last trusted snapshot.
  final bool ready;

  /// Process-lifetime native snapshot order; absent only on older native modules.
  final int? statusRevision;
  final bool statusRevisionPresent;

  /// Why it didn't, when it said.
  final String? error;

  /// The master switch 「手机操控」.
  final bool enabled;
  final bool bridgeListening;
  final PhoneA11yStatus a11y;
  final A11yKeeperStatus a11yKeeper;
  final bool overlay;

  /// The app may post notifications (confirmations, 停止, ADB pairing code).
  final bool notifications;

  /// Dedicated phone-confirmation channel is available at high importance.
  /// Null on older native modules; it does not replace the global switch.
  final bool? confirmationNotifications;
  final PhoneBackgroundStatus background;
  final PhoneTaskStatus task;
  final int taskProtocol;
  final PhoneCallerCapability? callerCapability;
  final List<PhoneTaskStatus> tasks;
  final int parallelLimit;
  final PhoneDevice device;
  final PhoneTaskInterruption taskInterruption;

  /// Some task may still act, the selected one or any other conversation's: active, a call
  /// waiting to start, or one still draining. Mirrors the native refusal of 解除限制.
  bool get anyTaskBusy => task.active || tasks.any((t) => t.active || t.pendingCalls > 0 || t.draining);

  PhoneStatus copyWith({bool? enabled, bool? ready, Object? error = _keepError}) => PhoneStatus(
    ready: ready ?? this.ready,
    error: identical(error, _keepError) ? this.error : error as String?,
    statusRevision: statusRevision,
    statusRevisionPresent: statusRevisionPresent,
    enabled: enabled ?? this.enabled,
    bridgeListening: bridgeListening,
    a11y: a11y,
    a11yKeeper: a11yKeeper,
    overlay: overlay,
    notifications: notifications,
    confirmationNotifications: confirmationNotifications,
    background: background,
    task: task,
    taskProtocol: taskProtocol,
    callerCapability: callerCapability,
    tasks: tasks,
    parallelLimit: parallelLimit,
    device: device,
    taskInterruption: taskInterruption,
  );
}

// ── 悬浮条 ───────────────────────────────────────────────────────────────────

/// 设置 → 手机操控 → 悬浮条 (`overlayPrefs` / `setOverlayPrefs`): how opaque the
/// ball is when idle, whether the island gets out of the way by itself (off
/// unless the person turns it on), whether the screen's edge glows while DSH
/// works and whether the phone's own island shows the task instead of the
/// floating bar (both on unless turned off), as OverlayPrefs.kt. A showing
/// overlay follows changes at once.
class PhoneOverlayPrefs {
  const PhoneOverlayPrefs({
    this.idleOpacity = defaultOpacity,
    this.autoCollapse = defaultAutoCollapse,
    this.edgeGlow = defaultEdgeGlow,
    this.systemIsland = defaultSystemIsland,
  });

  factory PhoneOverlayPrefs.fromMap(Map<Object?, Object?> m) => PhoneOverlayPrefs(
    idleOpacity: clampOpacity(m['idleOpacity'] is num ? (m['idleOpacity'] as num).toDouble() : defaultOpacity),
    autoCollapse: _maybeFlag(m['autoCollapse']) ?? defaultAutoCollapse,
    edgeGlow: _maybeFlag(m['edgeGlow']) ?? defaultEdgeGlow,
    systemIsland: _maybeFlag(m['systemIsland']) ?? defaultSystemIsland,
  );

  /// Off: the island stays as the person left it and folds into the ball only by hand.
  static const defaultAutoCollapse = false;

  /// On: the screen's edge glows while DSH operates the phone.
  static const defaultEdgeGlow = true;

  /// On: where the phone has its own island (HyperOS, ColorOS, MagicOS), the task shows there.
  static const defaultSystemIsland = true;

  /// 70 %: the line reads over light and dark pages alike (see OverlayPrefs.kt).
  static const defaultOpacity = 0.7;
  static const minOpacity = 0.3;
  static const maxOpacity = 1.0;

  /// Within 30–100 %, on whole percents.
  static double clampOpacity(double v) =>
      v.isNaN ? defaultOpacity : (v.clamp(minOpacity, maxOpacity) * 100).round() / 100;

  /// 闲置时不透明度, 0.3–1 (1: never fades).
  final double idleOpacity;

  /// 闲置时自动收起.
  final bool autoCollapse;

  /// 屏幕边缘光效.
  final bool edgeGlow;

  /// 用系统灵动岛显示.
  final bool systemIsland;

  int get percent => (idleOpacity * 100).round();

  PhoneOverlayPrefs copyWith({double? idleOpacity, bool? autoCollapse, bool? edgeGlow, bool? systemIsland}) =>
      PhoneOverlayPrefs(
        idleOpacity: idleOpacity == null ? this.idleOpacity : clampOpacity(idleOpacity),
        autoCollapse: autoCollapse ?? this.autoCollapse,
        edgeGlow: edgeGlow ?? this.edgeGlow,
        systemIsland: systemIsland ?? this.systemIsland,
      );

  @override
  bool operator ==(Object other) =>
      other is PhoneOverlayPrefs &&
      other.idleOpacity == idleOpacity &&
      other.autoCollapse == autoCollapse &&
      other.edgeGlow == edgeGlow &&
      other.systemIsland == systemIsland;

  @override
  int get hashCode => Object.hash(idleOpacity, autoCollapse, edgeGlow, systemIsland);
}

// ── Results ──────────────────────────────────────────────────────────────────

/// Only explicit one-shot native choices may answer an engine approval.
enum PhonePromptDecision { allowOnce, reject, open, dismissed, timeout, stopped, unavailable }

class PhonePromptResult {
  const PhonePromptResult({this.decision = PhonePromptDecision.unavailable, this.presented = 'none'});

  factory PhonePromptResult.fromMap(Map<Object?, Object?> map) => PhonePromptResult(
    decision: switch (map['decision']) {
      'allowed-once' => PhonePromptDecision.allowOnce,
      'rejected' => PhonePromptDecision.reject,
      'open' => PhonePromptDecision.open,
      'dismissed' => PhonePromptDecision.dismissed,
      'timeout' => PhonePromptDecision.timeout,
      'stopped' => PhonePromptDecision.stopped,
      _ => PhonePromptDecision.unavailable,
    },
    presented: switch (map['presented']) {
      'overlay' => 'overlay',
      'notification' => 'notification',
      'app' => 'app',
      _ => 'none',
    },
  );

  final PhonePromptDecision decision;
  final String presented;
}

/// Reply of `finishTask`.
class PhoneFinish {
  const PhoneFinish({
    this.closed = false,
    this.busy = false,
    this.opened = false,
    this.launched = false,
    this.notified = false,
    this.current = true,
  });

  factory PhoneFinish.fromMap(Map<Object?, Object?> m) => PhoneFinish(
    closed: _flag(m['closed']),
    busy: _flag(m['busy']),
    opened: _flag(m['opened']),
    launched: _flag(m['launched']),
    notified: _flag(m['notified']),
    current: m['current'] != false,
  );

  /// A task (or a stop's note) was open and is closed now, overlay included.
  final bool closed;

  /// Not closed: a phone call still runs. This is not proof of another owner.
  final bool busy;

  /// The app is on screen now.
  final bool opened;

  /// The app was asked to come forward (it may still have been blocked).
  final bool launched;

  /// A result notification was posted when automatic return did not succeed.
  final bool notified;

  /// The same task still owns this completion; false retires later UI actions.
  final bool current;

  PhoneFinish withNotice() =>
      PhoneFinish(closed: closed, busy: busy, opened: opened, launched: launched, notified: true, current: current);

  PhoneFinish retired() =>
      PhoneFinish(closed: closed, busy: busy, opened: opened, launched: launched, notified: notified, current: false);
}

/// `{ok, reason?}` replies.
class PhoneResult {
  const PhoneResult(this.ok, [this.reason, this.pending = false]);

  factory PhoneResult.fromMap(Map<Object?, Object?> m) =>
      PhoneResult(_flag(m['ok']), _text(m['reason']), _flag(m['pending']));

  final bool ok;
  final String? reason;
  final bool pending;
}

/// Reply of `testScreen`: the main screen read once.
class ScreenTestResult {
  const ScreenTestResult({required this.ok, this.text, this.reason});

  factory ScreenTestResult.fromMap(Map<Object?, Object?> m) => ScreenTestResult(
    ok: _flag(m['ok']),
    text: m['text'] is String ? m['text'] as String : null,
    reason: _text(m['reason']),
  );

  final bool ok;
  final String? text;
  final String? reason;
}

// ── Policies ─────────────────────────────────────────────────────────────────

/// What DSH may do in one app.
enum AppRule {
  /// Neither read nor act (banks, payment by default).
  deny,

  /// Read freely; every write action asks first (WeChat by default).
  confirmEachStep,

  /// The general rules only (sensitive actions still ask).
  normal,
}

/// Labels for well-known packages, used when the native side sends none:
/// the apps' own names in the app language.
Map<String, String> get knownAppLabels => AppLocale.isEnglish ? _knownAppLabelsEn : _knownAppLabelsZh;

// l10n:keep-begin the apps' Chinese names (what Chinese systems show)
const _knownAppLabelsZh = <String, String>{
  'com.eg.android.AlipayGphone': '支付宝',
  'com.unionpay': '云闪付',
  'com.tencent.mm': '微信',
  'com.tencent.mobileqq': 'QQ',
  'com.icbc': '中国工商银行',
  'com.chinamworld.main': '中国建设银行',
  'com.android.bankabc': '中国农业银行',
  'com.chinamworld.bocmbci': '中国银行',
  'cmb.pb': '招商银行',
  'com.bankcomm.Bankcomm': '交通银行',
  'com.yitong.mbank.psbc': '中国邮政储蓄银行',
  'com.jd.jrapp': '京东金融',
  'com.taobao.taobao': '淘宝',
  'com.jingdong.app.mall': '京东',
  'com.xunmeng.pinduoduo': '拼多多',
  'com.sankuai.meituan': '美团',
  'com.autonavi.minimap': '高德地图',
  'com.ss.android.ugc.aweme': '抖音',
  'com.xingin.xhs': '小红书',
  'com.MobileTicket': '铁路12306',
}; // l10n:keep-end

const _knownAppLabelsEn = <String, String>{
  'com.eg.android.AlipayGphone': 'Alipay',
  'com.unionpay': 'UnionPay',
  'com.tencent.mm': 'WeChat',
  'com.tencent.mobileqq': 'QQ',
  'com.icbc': 'ICBC',
  'com.chinamworld.main': 'China Construction Bank',
  'com.android.bankabc': 'Agricultural Bank of China',
  'com.chinamworld.bocmbci': 'Bank of China',
  'cmb.pb': 'China Merchants Bank',
  'com.bankcomm.Bankcomm': 'Bank of Communications',
  'com.yitong.mbank.psbc': 'Postal Savings Bank of China',
  'com.jd.jrapp': 'JD Finance',
  'com.taobao.taobao': 'Taobao',
  'com.jingdong.app.mall': 'JD',
  'com.xunmeng.pinduoduo': 'Pinduoduo',
  'com.sankuai.meituan': 'Meituan',
  'com.autonavi.minimap': 'Amap',
  'com.ss.android.ugc.aweme': 'Douyin',
  'com.xingin.xhs': 'Xiaohongshu',
  'com.MobileTicket': 'China Railway 12306',
};

/// A hard rule the person may lift (解除限制, `unlocks` in the policies; the
/// wire key is the name). All are off until turned on behind the
/// confirmation page; the native side reads anything else as off.
enum PhoneUnlock {
  /// System settings, permission pages, installers, security centres, the
  /// notification shade.
  systemPages,

  /// Password, verification-code and payment-code inputs.
  secretFields,

  /// DSH Go's own screens.
  ownApp,
}

/// How much the person is asked before DSH acts (`confirmMode`; the wire
/// value is the name). The hard rules refuse in every mode, unless lifted
/// ([PhoneUnlock]).
enum PhoneConfirmMode {
  /// 每次都询问: a new app, sending, deleting, paying… ask first.
  ask,

  /// 本任务免确认 (本轮允许): the first question of a round can waive the
  /// rest of it.
  task,

  /// 始终免确认: nothing is asked.
  always;

  /// Unknown or missing values read as [ask], the strictest.
  static PhoneConfirmMode parse(Object? wire) => values.firstWhere((m) => m.name == wire, orElse: () => ask);
}

/// `getPolicies` / `setPolicies`. Only the two lists, 始终允许 and
/// [confirmMode] go back over the wire; [labels] and the defaults are optional
/// extras the native side may send. [unlocks] never rides along: it changes
/// only through [PhoneChannel.setUnlock], so a stale copy can't lift or
/// restore a rule.
class PhonePolicies {
  const PhonePolicies({
    this.denyPackages = const [],
    this.confirmEveryWritePackages = const [],
    this.alwaysAllowEnabled = false,
    this.alwaysAllowPackages = const [],
    this.labels = const {},
    this.defaultDeny = const [],
    this.defaultConfirm = const [],
    this.confirmMode = PhoneConfirmMode.ask,
    this.unlocks = const {},
    this.localOcrEnabled,
  });

  factory PhonePolicies.fromMap(Map<Object?, Object?> m) {
    final defaults = _map(m['defaults']);
    final unlocks = _map(m['unlocks']);
    return PhonePolicies(
      denyPackages: _strings(m['denyPackages']),
      confirmEveryWritePackages: _strings(m['confirmEveryWritePackages']),
      // Only an explicit true turns it on; a missing or malformed value is off.
      alwaysAllowEnabled: m['alwaysAllowEnabled'] == true,
      alwaysAllowPackages: _strings(m['alwaysAllowPackages']),
      labels: {
        for (final e in _map(m['labels']).entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      },
      defaultDeny: _strings(defaults['denyPackages']),
      defaultConfirm: _strings(defaults['confirmEveryWritePackages']),
      confirmMode: PhoneConfirmMode.parse(m['confirmMode']),
      localOcrEnabled: _maybeFlag(m['localOcrEnabled']),
      // Only an explicit true lifts a rule.
      unlocks: {
        for (final u in PhoneUnlock.values)
          if (unlocks[u.name] == true) u,
      },
    );
  }

  final List<String> denyPackages;
  final List<String> confirmEveryWritePackages;

  /// 始终允许: send content to these apps without asking.
  final bool alwaysAllowEnabled;
  final List<String> alwaysAllowPackages;

  /// Package → app label, from the native side.
  final Map<String, String> labels;

  /// The lists as shipped with this APK, when the native side says.
  final List<String> defaultDeny;
  final List<String> defaultConfirm;

  final PhoneConfirmMode confirmMode;

  /// The hard rules the person lifted; empty by default.
  final Set<PhoneUnlock> unlocks;

  /// Missing, malformed or unread native settings remain unknown.
  final bool? localOcrEnabled;

  Map<String, Object?> toWire() => {
    'denyPackages': denyPackages,
    'confirmEveryWritePackages': confirmEveryWritePackages,
    'alwaysAllowEnabled': alwaysAllowEnabled,
    'alwaysAllowPackages': alwaysAllowPackages,
    'confirmMode': confirmMode.name,
  };

  PhonePolicies withConfirmMode(PhoneConfirmMode mode) => PhonePolicies(
    denyPackages: denyPackages,
    confirmEveryWritePackages: confirmEveryWritePackages,
    alwaysAllowEnabled: alwaysAllowEnabled,
    alwaysAllowPackages: alwaysAllowPackages,
    labels: labels,
    defaultDeny: defaultDeny,
    defaultConfirm: defaultConfirm,
    confirmMode: mode,
    unlocks: unlocks,
    localOcrEnabled: localOcrEnabled,
  );

  PhonePolicies withUnlock(PhoneUnlock unlock, bool on) => PhonePolicies(
    denyPackages: denyPackages,
    confirmEveryWritePackages: confirmEveryWritePackages,
    alwaysAllowEnabled: alwaysAllowEnabled,
    alwaysAllowPackages: alwaysAllowPackages,
    labels: labels,
    defaultDeny: defaultDeny,
    defaultConfirm: defaultConfirm,
    confirmMode: confirmMode,
    unlocks: on ? {...unlocks, unlock} : ({...unlocks}..remove(unlock)),
    localOcrEnabled: localOcrEnabled,
  );

  PhonePolicies withLocalOcrEnabled(bool? enabled) => PhonePolicies(
    denyPackages: denyPackages,
    confirmEveryWritePackages: confirmEveryWritePackages,
    alwaysAllowEnabled: alwaysAllowEnabled,
    alwaysAllowPackages: alwaysAllowPackages,
    labels: labels,
    defaultDeny: defaultDeny,
    defaultConfirm: defaultConfirm,
    confirmMode: confirmMode,
    unlocks: unlocks,
    localOcrEnabled: enabled,
  );

  AppRule ruleFor(String package) {
    if (denyPackages.contains(package)) return AppRule.deny;
    if (confirmEveryWritePackages.contains(package)) {
      return AppRule.confirmEachStep;
    }
    return AppRule.normal;
  }

  /// What the shipped defaults say about [package] (null when unknown).
  AppRule? defaultRuleFor(String package) {
    if (defaultDeny.contains(package)) return AppRule.deny;
    if (defaultConfirm.contains(package)) return AppRule.confirmEachStep;
    if (defaultDeny.isEmpty && defaultConfirm.isEmpty) return null;
    return AppRule.normal;
  }

  String labelFor(String package) => labels[package] ?? knownAppLabels[package] ?? package;

  PhonePolicies withRule(String package, AppRule rule) {
    final deny = [...denyPackages]..remove(package);
    final confirm = [...confirmEveryWritePackages]..remove(package);
    switch (rule) {
      case AppRule.deny:
        deny.add(package);
      case AppRule.confirmEachStep:
        confirm.add(package);
      case AppRule.normal:
        break;
    }
    return PhonePolicies(
      denyPackages: deny,
      confirmEveryWritePackages: confirm,
      alwaysAllowEnabled: alwaysAllowEnabled,
      alwaysAllowPackages: alwaysAllowPackages,
      labels: labels,
      defaultDeny: defaultDeny,
      defaultConfirm: defaultConfirm,
      confirmMode: confirmMode,
      unlocks: unlocks,
      localOcrEnabled: localOcrEnabled,
    );
  }

  /// 始终允许: the switch and the app list, written together.
  PhonePolicies withAlwaysAllow({required bool enabled, required List<String> packages}) => PhonePolicies(
    denyPackages: denyPackages,
    confirmEveryWritePackages: confirmEveryWritePackages,
    alwaysAllowEnabled: enabled,
    alwaysAllowPackages: packages,
    labels: labels,
    defaultDeny: defaultDeny,
    defaultConfirm: defaultConfirm,
    confirmMode: confirmMode,
    unlocks: unlocks,
    localOcrEnabled: localOcrEnabled,
  );
}

// ── Action log ───────────────────────────────────────────────────────────────

/// How a logged action was decided.
enum PhoneDecision {
  /// Ran without asking (not sensitive), or went on after a handoff.
  done,

  /// The person allowed it.
  allowed,

  /// The person said no, or didn't choose within 30 s.
  denied,

  /// The person stopped the task.
  stopped,

  /// A hard rule or the app list refused it (or handed it back).
  blocked,

  failed,
  unknown;

  /// Native vocabulary (PhoneCore / SafetyGate): `ok`, `allowed` (no question
  /// needed), `continue` (handoff resumed), `confirmed`, `confirmed-app`,
  /// `denied` (said no or 30 s without a choice), `stopped`, `paused`,
  /// `refused:<rule>`, `unavailable`, `stale`, `timeout` (the tool ran out of
  /// time), `error`. Older or future words fall back to [unknown].
  static PhoneDecision parse(Object? wire) {
    final v = (wire is String ? wire : '').toLowerCase().replaceAll('-', '_');
    if (v.startsWith('refused')) return blocked;
    return switch (v) {
      'ok' || 'allowed' || 'continue' || 'auto' || 'done' => done,
      'confirmed' ||
      'confirmed_app' ||
      'confirmed_task' ||
      'confirmed_visual' ||
      'allow_once' ||
      'allow_app_for_task' ||
      'allow_all_for_task' => allowed,
      'denied' || 'deny' => denied,
      'stopped' || 'stop' || 'paused' => stopped,
      'blocked' || 'handoff' => blocked,
      'error' || 'failed' || 'timeout' || 'unavailable' || 'stale' => failed,
      _ => unknown,
    };
  }
}

/// One line of the native action log. Never holds screen contents.
class PhoneLogEntry {
  const PhoneLogEntry({
    required this.time,
    required this.tool,
    this.app,
    this.summary = '',
    this.decision = PhoneDecision.unknown,
    this.rawDecision,
  });

  factory PhoneLogEntry.fromMap(Map<Object?, Object?> m) => PhoneLogEntry(
    time: _time(m['time']),
    tool: _text(m['tool']) ?? '',
    app: _text(m['app']),
    summary: _text(m['summary']) ?? '',
    decision: PhoneDecision.parse(m['decision']),
    rawDecision: _text(m['decision']),
  );

  /// Epoch milliseconds (seconds tolerated) or an ISO string; null if neither.
  static DateTime? _time(Object? v) {
    if (v is num) {
      final n = v.toInt();
      return DateTime.fromMillisecondsSinceEpoch(n < 100000000000 ? n * 1000 : n);
    }
    if (v is String) return DateTime.tryParse(v)?.toLocal();
    return null;
  }

  final DateTime? time;

  /// Tool name, e.g. `tap` (an `mcp__phone__` prefix is tolerated).
  final String tool;
  final String? app;
  final String summary;
  final PhoneDecision decision;
  final String? rawDecision;
}

// ── Channel ──────────────────────────────────────────────────────────────────

/// A bounded local-only preview message; it never joins ordinary phone status.
class PhonePreviewFrame {
  const PhonePreviewFrame({
    required this.taskId,
    required this.generation,
    required this.sequence,
    required this.state,
    this.width = 0,
    this.height = 0,
    this.imageBytes,
  });

  static PhonePreviewFrame? parse(Object? raw) {
    if (raw is! Map) return null;
    final taskId = raw['taskId'];
    final generation = raw['generation'];
    final sequence = raw['sequence'];
    final state = raw['state'];
    if (taskId is! int || taskId <= 0 || generation is! int || generation < 0 ||
        sequence is! int || sequence < 0 ||
        !const {'off', 'waiting', 'frame', 'unavailable', 'protected', 'inUse'}.contains(state)) {
      return null;
    }
    if (state != 'frame') {
      return PhonePreviewFrame(taskId: taskId, generation: generation, sequence: sequence, state: state as String);
    }
    final bytes = raw['imageBytes'];
    final width = raw['width'];
    final height = raw['height'];
    if (bytes is! Uint8List || bytes.isEmpty || bytes.lengthInBytes > 128 * 1024 ||
        width is! int || width < 1 || width > 800 || height is! int || height < 1 || height > 800) {
      return null;
    }
    return PhonePreviewFrame(taskId: taskId, generation: generation, sequence: sequence,
        state: 'frame', width: width, height: height, imageBytes: bytes);
  }

  final int taskId;
  final int generation;
  final int sequence;
  final String state;
  final int width;
  final int height;
  final Uint8List? imageBytes;
}

/// Typed wrapper over the private phone method, status, and preview channels.
class PhoneChannel {
  PhoneChannel({MethodChannel? methods, EventChannel? events, EventChannel? preview})
    : _methods = methods ?? const MethodChannel('dsh/phone'),
      _pushes = events == null ? _defaultPushes : _eventStream(events),
      _preview = preview ?? const EventChannel('dsh/phone/preview');

  final MethodChannel _methods;
  final EventChannel _preview;
  // A named native channel has one listen/cancel pair, including when callers construct separate wrappers.
  static final _defaultPushes = _eventStream(const EventChannel('dsh/phone/events'));
  static Stream<SkillWireMap> _eventStream(EventChannel events) =>
      events.receiveBroadcastStream().where((raw) => raw is SkillWireMap).cast<SkillWireMap>();
  final Stream<SkillWireMap> _pushes;

  /// Status snapshots from all supported platforms are untagged.
  late final Stream<PhoneStatus> statusChanges = _pushes
      .where((map) => map['type'] == null || map['type'] == 'status')
      .map(PhoneStatus.fromMap);

  late final Stream<PhoneSkillEvent> skillEvents = _pushes
      .where((map) => map['type'] == 'skillDraft' || map['type'] == 'skillOutcome')
      .map((map) => map['type'] == 'skillDraft' ? PhoneSkillDraftEvent.fromMap(map) : PhoneSkillOutcomeEvent.fromMap(map));

  Future<PhoneStatus> status() async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>('status');
      return map == null ? const PhoneStatus.notReady() : PhoneStatus.fromMap(map);
    } on MissingPluginException {
      return const PhoneStatus.notReady();
    } on PlatformException catch (e) {
      return PhoneStatus.notReady(e.message);
    }
  }

  Future<bool> setEnabled(bool enabled) => _bool('setEnabled', {'enabled': enabled});

  /// Explicit preference only; native snapshots it when a new background driver is created.
  Future<PhoneResult> setBackgroundViewport(PhoneBackgroundViewport preset) =>
      _result('setBackgroundViewport', {'preset': preset.name});

  Future<PhoneResult> setBackgroundParallelLimit(int limit) =>
      _result('setBackgroundParallelLimit', {'limit': limit});

  Future<bool> setBackgroundPreview(bool enabled) => _bool('setBackgroundPreview', {'enabled': enabled});

  /// One App viewer at a time. Cancellation completes after the native ACK.
  Stream<PhonePreviewFrame?> previewFrames(int taskId) {
    final messenger = _preview.binaryMessenger;
    final control = MethodChannel(_preview.name, _preview.codec, messenger);
    final arguments = <String, Object>{'taskId': taskId};
    late final StreamController<Object?> controller;
    var cancelled = false;

    Future<void> start() async {
      try {
        await control.invokeMethod<void>('listen', arguments);
      } catch (error, stack) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(error, stack);
        }
      }
    }

    controller = StreamController<Object?>(
      onListen: () {
        messenger.setMessageHandler(_preview.name, (reply) async {
          if (cancelled || controller.isClosed) {
            return null;
          }
          if (reply == null) {
            unawaited(controller.close());
          } else {
            try {
              controller.add(_preview.codec.decodeEnvelope(reply));
            } on PlatformException catch (error, stack) {
              controller.addError(error, stack);
            }
          }
          return null;
        });
        unawaited(start());
      },
      onCancel: () async {
        cancelled = true;
        messenger.setMessageHandler(_preview.name, null);
        await control.invokeMethod<void>('cancel', arguments);
      },
    );
    return controller.stream.map(PhonePreviewFrame.parse);
  }

  Future<PhoneSkillListing> listSkills() => _skill('skills.list', PhoneSkillListing.fromMap);

  Future<PhoneSkill> getSkill(String name) => _skill('skills.get', PhoneSkill.fromMap, {'name': name});

  Future<bool> setSkillLearning(bool on) => _skill('skills.setLearn', (reply) => reply['learn'] as bool, {'on': on});

  Future<PhoneSkill> acceptSkill(String draftId, {PhoneSkillSections? edited}) =>
      _skill('skills.accept', PhoneSkill.fromMap, {'draftId': draftId, 'edited': ?edited?.toMap()});

  Future<void> discardSkill(String draftId) => _skill<void>('skills.discard', (_) {}, {'draftId': draftId});

  Future<PhoneSkill> saveSkill(String name, {String? display, String? description, String? whenToUse,
      PhoneSkillSections? sections}) => _skill('skills.save', PhoneSkill.fromMap, {
    'name': name, 'display': ?display, 'description': ?description, 'whenToUse': ?whenToUse, 'sections': ?sections?.toMap(),
  });

  Future<PhoneSkill> setSkillEnabled(String name, bool on) =>
      _skill('skills.setEnabled', PhoneSkill.fromMap, {'name': name, 'on': on});

  Future<PhoneSkill> restoreSkill(String name) => _skill('skills.restore', PhoneSkill.fromMap, {'name': name});

  Future<void> deleteSkill(String name) => _skill<void>('skills.delete', (_) {}, {'name': name});

  Future<T> _skill<T>(String method, T Function(SkillWireMap) parse, [Map<String, Object?>? args]) async {
    try {
      final reply = await _methods.invokeMapMethod<Object?, Object?>(method, args);
      if (reply == null) throw const PhoneSkillException('unavailable', 'Empty native response.');
      if (reply['error'] case final String code) throw PhoneSkillException(code, reply['detail'] as String? ?? '');
      return parse(reply);
    } on MissingPluginException {
      throw const PhoneSkillException('unavailable', 'Phone skills are unavailable.');
    } on PlatformException {
      throw const PhoneSkillException('unavailable', 'Phone skills are unavailable.');
    } on FormatException {
      throw const PhoneSkillException('invalid', 'Invalid native skill response.');
    } on TypeError {
      throw const PhoneSkillException('invalid', 'Invalid native skill response.');
    }
  }

  Future<PhoneSkillReplayInspection> inspectSkillReplay(String skillId) async {
    try {
      return PhoneSkillReplayInspection.parse(await _methods.invokeMapMethod<Object?, Object?>(
        'inspectSkillReplay', {'skillId': skillId}));
    } on MissingPluginException {
      return const PhoneSkillReplayInspection.unavailable();
    } on PlatformException {
      return const PhoneSkillReplayInspection.unavailable();
    }
  }

  Future<PhoneSkillReplayReady?> prepareSkillReplay({required String skillId, required String revision,
    required String sessionId, required PhoneSkillReplayApp app}) async {
    try {
      return PhoneSkillReplayReady.parse(await _methods.invokeMapMethod<Object?, Object?>(
        'prepareSkillReplay', {'skillId': skillId, 'revision': revision, 'sessionId': sessionId,
          'parameters': {'appSlots': {'app1': {'packageName': app.packageName, 'uid': app.uid}}, 'values': <String, Object?>{}}}));
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> discardSkillReplay(String invocation) async {
    try {
      final reply = await _methods.invokeMapMethod<Object?, Object?>('discardSkillReplay', {'invocation': invocation});
      return reply?['kind'] == 'discarded';
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<bool> openAccessibilitySettings() => _bool('openAccessibilitySettings');

  Future<PhoneResult> grantSecureSettings() => _result('grantSecureSettings');

  /// This app's system "App info" page (restricted settings, notifications).
  Future<bool> openAppDetails() => _bool('openAppDetails');

  Future<ScreenTestResult> testScreen() async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>('testScreen');
      return map == null ? ScreenTestResult(ok: false, reason: phoneNotReadyReason) : ScreenTestResult.fromMap(map);
    } on MissingPluginException {
      return ScreenTestResult(ok: false, reason: phoneNotReadyReason);
    } on PlatformException catch (e) {
      return ScreenTestResult(ok: false, reason: e.message ?? e.code);
    }
  }

  Future<PhoneResult> setBackgroundMode(PhoneBackgroundMode mode) => _result('setBackgroundMode', {'mode': mode.name});

  /// The caller gates these actions on the advertised versioned capabilities.
  Future<PhoneResult> setPrivilegedMode(PhonePrivilegedMode mode) => _result('setBackgroundMode', {'mode': mode.name});

  /// An explicit keep choice. Success means saved; status reports actual recovery.
  Future<PhoneResult> setBackgroundKeep(PhonePrivilegedMode mode, bool enabled) =>
      _result('setBackgroundKeep', {'mode': mode.name, 'enabled': enabled});

  Future<PhoneResult> prepareRoot() => _result('prepareRoot');

  Future<bool> requestPrivilegedPermission(String provider) =>
      _bool('requestShizukuPermission', {'provider': provider});

  Future<bool> requestShizukuPermission() => _bool('requestShizukuPermission');

  /// Posts the notification with a code field for 「使用配对码配对设备」.
  Future<PhoneResult> adbStartPairing() => _result('adbStartPairing');

  /// The in-app fallback: the six-digit code (and port) typed here.
  Future<PhoneResult> adbPair(String code, {int? port}) => _result('adbPair', {'code': code, 'port': port});

  Future<PhoneResult> adbConnect({int? port}) => _result('adbConnect', port == null ? null : {'port': port});

  Future<PhonePolicies?> getPolicies() async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>('getPolicies');
      return map == null ? null : PhonePolicies.fromMap(map);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<bool> setPolicies(PhonePolicies policies) => _bool('setPolicies', policies.toWire());

  Future<bool> setLocalOcrEnabled(bool enabled) =>
      _bool('setPolicies', {'localOcrEnabled': enabled});

  /// Lifts or restores one hard rule, and nothing else (`setPolicies` keeps
  /// what it isn't sent).
  Future<bool> setUnlock(PhoneUnlock unlock, bool on) => _bool('setPolicies', {
    'unlocks': {unlock.name: on},
  });

  Future<List<PhoneLogEntry>> actionLog({int limit = 100}) async {
    try {
      final list = await _methods.invokeListMethod<Object?>('actionLog', {'limit': limit});
      return [
        for (final e in list ?? const [])
          if (e is Map) PhoneLogEntry.fromMap(e.cast<Object?, Object?>()),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  Future<bool> stopTask({int? taskId}) => _bool('stopTask', taskId == null ? null : {'taskId': taskId});

  Future<bool> retryTaskCleanup(int taskId) => _bool('retryTaskCleanup', {'taskId': taskId});

  Future<bool> acknowledgeTaskInterruption(String batchToken) =>
      _bool('acknowledgeTaskInterruption', {'batchToken': batchToken});

  Future<bool> retryTaskInterruptionStorage() => _bool('retryTaskInterruptionStorage');

  Future<bool> resumeTask(int taskId) => _bool('resumeTask', {'taskId': taskId});

  Future<bool> pauseTask(int taskId, bool paused) => _bool('pauseTask', {'taskId': taskId, 'paused': paused});

  /// Private, structured engine request. Native owns the UI identity, nonce,
  /// one-active-card policy and 30-second deadline; text is never an action.
  Future<PhonePromptResult> presentPrompt({
    required String requestId,
    required String sessionId,
    required String host,
    required String text,
    required bool canApprove,
    int? taskId,
  }) async {
    if (requestId.isEmpty ||
        requestId.length > 200 ||
        sessionId.isEmpty ||
        sessionId.length > 200 ||
        host.isEmpty ||
        host.length > 2048 ||
        text.isEmpty ||
        text.length > 4096 ||
        (taskId != null && taskId <= 0)) {
      return const PhonePromptResult();
    }
    try {
      final map = await _methods
          .invokeMapMethod<Object?, Object?>('presentPrompt', {
            'requestId': requestId,
            'taskId': ?taskId,
            'sessionId': sessionId,
            'host': host,
            'kind': canApprove ? 'approval' : 'review',
            'text': text,
          })
          .timeout(const Duration(seconds: 35));
      return map == null ? const PhonePromptResult() : PhonePromptResult.fromMap(map);
    } on TimeoutException {
      unawaited(cancelPrompt(requestId));
      return const PhonePromptResult(decision: PhonePromptDecision.timeout);
    } on MissingPluginException {
      return const PhonePromptResult();
    } on PlatformException {
      return const PhonePromptResult();
    }
  }

  Future<void> cancelPrompt(String requestId) async {
    try {
      await _methods.invokeMethod<void>('cancelPrompt', {'requestId': requestId}).timeout(const Duration(seconds: 2));
    } on MissingPluginException {
      // An older native module has no prompt to cancel.
    } on PlatformException {
      // Native also retires prompts with its task and engine lifecycle.
    } on TimeoutException {
      // The native 30-second deadline remains the final bound.
    }
  }

  /// The 悬浮条 settings; null without the native side.
  Future<PhoneOverlayPrefs?> overlayPrefs() => _overlay('overlayPrefs');

  /// Writes what is given (the rest stays); the stored result, null without the native side.
  Future<PhoneOverlayPrefs?> setOverlayPrefs({
    double? idleOpacity,
    bool? autoCollapse,
    bool? edgeGlow,
    bool? systemIsland,
  }) => _overlay('setOverlayPrefs', {
    'idleOpacity': ?idleOpacity,
    'autoCollapse': ?autoCollapse,
    'edgeGlow': ?edgeGlow,
    'systemIsland': ?systemIsland,
  });

  /// Whether this phone has its own island the task can show in (HyperOS 超级岛,
  /// ColorOS 流体云, MagicOS): `vendor`; and whether it does now (`shows`: the
  /// live activity is on and the system promotes it). False without the native side.
  /// Installed apps' names and icons (PNG) by package; apps not installed are left out.
  Future<Map<String, ({String label, Uint8List icon})>> appInfo(List<String> packages) async {
    if (packages.isEmpty) return const {};
    try {
      final map = await _methods.invokeMapMethod<String, Object?>('appInfo', {'packages': packages});
      return {
        for (final MapEntry(:key, :value) in (map ?? const {}).entries)
          if (value case {'label': final String label, 'icon': final Uint8List icon}) key: (label: label, icon: icon),
      };
    } on MissingPluginException {
      return const {};
    } on PlatformException {
      return const {};
    }
  }

  Future<({bool vendor, bool shows})> systemIsland() async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>('systemIsland');
      return (vendor: map?['vendor'] == true, shows: map?['shows'] == true);
    } on MissingPluginException {
      return (vendor: false, shows: false);
    } on PlatformException {
      return (vendor: false, shows: false);
    }
  }

  /// What DSH last said in [sessionId], the conversation driving the phone, for
  /// the island's card (null forgets it). Best effort: an older native side ignores it.
  Future<void> setPhoneThought(String sessionId, String? text) async {
    try {
      await _methods.invokeMethod<bool>('setPhoneThought', {'sessionId': sessionId, 'text': text});
    } on MissingPluginException {
      // An older native module shows no thoughts.
    } on PlatformException {
      // Nothing to show then.
    }
  }

  Future<PhoneOverlayPrefs?> _overlay(String method, [Object? args]) async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>(method, args);
      return map == null ? null : PhoneOverlayPrefs.fromMap(map);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// The turn that drove the phone ended: closes the overlay and ends the
  /// task; with [reopen], brings the app forward on [sessionId] (just the app
  /// when null) if it is in the background, and says whether it came up.
  Future<PhoneFinish> finishTask({required int taskId, String? sessionId, String? host, bool reopen = false, String? runId, int? generation, bool appOnly = false}) async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>('finishTask', {
        'taskId': taskId,
        'sessionId': sessionId,
        'host': host,
        'reopen': reopen,
        'runId': ?runId,
        'generation': ?generation,
        if (appOnly) 'appOnly': true,
      });
      return map == null ? const PhoneFinish() : PhoneFinish.fromMap(map);
    } on MissingPluginException {
      return const PhoneFinish();
    } on PlatformException {
      return const PhoneFinish();
    }
  }

  Future<bool> _bool(String method, [Object? args]) async {
    try {
      return await _methods.invokeMethod<bool>(method, args) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<PhoneResult> _result(String method, [Object? args]) async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>(method, args);
      return map == null ? PhoneResult(false, phoneNotReadyReason) : PhoneResult.fromMap(map);
    } on MissingPluginException {
      return PhoneResult(false, phoneNotReadyReason);
    } on PlatformException catch (e) {
      return PhoneResult(false, e.message ?? e.code);
    }
  }
}
