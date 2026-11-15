import 'dart:async';

import 'package:flutter/services.dart';

/// Lifecycle of the on-device Linux runtime and the local DSH server.
enum RuntimePhase {
  notInstalled,
  installing,
  installed,
  starting,
  running,
  stopping,
  error;

  static RuntimePhase parse(Object? wire) =>
      RuntimePhase.values.firstWhere((p) => p.name == wire, orElse: () => RuntimePhase.error);

  bool get isBusy => this == installing || this == starting || this == stopping;
}

/// Which profile the local DSH boots: the user's `web`, or the rescue profile.
enum EngineMode {
  normal,
  safe;

  static EngineMode parse(Object? wire) => wire == 'safe' ? safe : normal;
}

/// Where the safe-mode state machine stands (Kotlin `SafeState`).
enum SafeModeState {
  /// Normal starts.
  off,

  /// Starts use the rescue profile until the user asks for normal mode.
  on,

  /// Back in normal mode on trial: a counted failure within two minutes returns to [on].
  probation;

  static SafeModeState parse(Object? wire) => switch (wire) {
    'on' => on,
    'probation' => probation,
    _ => off,
  };
}

/// How a run that nobody asked to stop ended (Kotlin `FailureKind`).
enum FailureKind {
  /// The shell could not execute DSH before its login line.
  launchFailed,

  /// DSH printed a fatal error before its login line.
  startupFailed,

  /// DSH printed a fatal error within two minutes of its login line.
  crashedEarly,

  /// DSH printed a fatal error after running longer than that.
  crashedLate,

  /// The process went away without a DSH fatal error (low memory, battery saver, ...).
  killed,

  /// The output mentions a full disk.
  noSpace;

  static FailureKind? parse(Object? wire) => FailureKind.values.where((k) => k.name == wire).firstOrNull;

  /// Counts toward the two consecutive failures that switch to safe mode.
  bool get counts => this == startupFailed || this == crashedEarly;

  /// A plugin or configuration problem (DSH itself reported it).
  bool get isFatal => this == startupFailed || this == crashedEarly || this == crashedLate;
}

/// The last unexpected exit of the local DSH, classified natively.
class RuntimeFailure {
  const RuntimeFailure({
    required this.kind,
    required this.at,
    this.exitCode = 0,
    this.safeMode = false,
    this.summary,
    this.requiredRows = const [],
    this.suspects = const [],
    this.recent = const [],
    this.diagnostics,
    this.upSeconds,
  });

  static RuntimeFailure? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final kind = FailureKind.parse(raw['kind']);
    if (kind == null) return null;
    List<String> strings(Object? v) => v is List
        ? [
            for (final e in v)
              if (e is String && e.isNotEmpty) e,
          ]
        : const [];
    return RuntimeFailure(
      kind: kind,
      at: DateTime.fromMillisecondsSinceEpoch((raw['at'] as num?)?.toInt() ?? 0),
      exitCode: (raw['exitCode'] as num?)?.toInt() ?? 0,
      safeMode: raw['safeMode'] == true,
      summary: raw['summary'] as String?,
      requiredRows: strings(raw['requiredRows']),
      suspects: strings(raw['suspects']),
      recent: strings(raw['recent']),
      diagnostics: raw['diagnostics'] as String?,
      upSeconds: (raw['upSeconds'] as num?)?.toInt(),
    );
  }

  final FailureKind kind;
  final DateTime at;
  final int exitCode;

  /// The failed run was itself a safe-mode run.
  final bool safeMode;

  /// First fatal line (English, from DSH).
  final String? summary;

  /// Built-in rows the startup audit names; broken, not necessarily the culprit.
  final List<String> requiredRows;

  /// Packages named by the crash output.
  final List<String> suspects;

  /// Bundles enabled or upgraded since the last good run.
  final List<String> recent;

  /// Guest path of DSH's startup diagnostics file.
  final String? diagnostics;
  final int? upSeconds;

  /// Crash-output suspects first, then recent changes.
  List<String> get culprits => {...suspects, ...recent}.toList();
}

/// Snapshot of the native runtime (see docs/architecture.md, "RuntimeStatus").
class RuntimeStatus {
  const RuntimeStatus({
    required this.phase,
    this.abi,
    this.bundledVersion,
    this.installedVersion,
    this.dshVersion,
    this.nodeVersion,
    this.baseUrl,
    this.token,
    this.managedSkillGeneration,
    this.error,
    this.mode = EngineMode.normal,
    this.workspaceRecovery = false,
    this.safeState = SafeModeState.off,
    this.safeReason,
    this.strikes = 0,
    this.autoSafe = true,
    this.failure,
    this.mainFailure,
    this.healthyAt,
    this.networkBlocked = false,
    this.networkBlockedAt,
    this.directEngineEnabled = false,
    this.directEngineAvailable = false,
    this.directEngineActive = false,
    this.directEngineFallbackReason,
    this.tawcEngineEnabled = false,
    this.tawcEngineAvailable = false,
    this.tawcEngineActive = false,
    this.currentExecutionMode,
    this.launchSelectedMode,
    this.launchSpawned = false,
    this.launchFailureReason,
    this.tidyingFiles = false,
    this.continuedRun = false,
  });

  const RuntimeStatus.unknown() : this(phase: RuntimePhase.notInstalled);

  final RuntimePhase phase;
  final String? abi;
  final String? bundledVersion;
  final String? installedVersion;
  final String? dshVersion;
  final String? nodeVersion;
  final String? baseUrl;
  final String? token;

  /// Native grant generation for bundled-skill writes only (runtime ready and
  /// Flutter attachment). Unknown means the
  /// native transaction must reject admission; this is not general RPC authority.
  final int? managedSkillGeneration;
  final String? error;

  /// Mode of the running process, or the mode the next start will use.
  final EngineMode mode;

  /// Uses the persistent independent workspace index on this local runtime.
  /// This is a launch setting, not evidence that workspace services are ready.
  final bool workspaceRecovery;
  final SafeModeState safeState;

  /// Why safe mode is on: `manual`, `auto` (two failures in a row) or `probation` (normal mode failed again).
  final String? safeReason;

  /// Consecutive counted failures of the main profile.
  final int strikes;

  /// Switch to safe mode by itself after two consecutive failures (default on).
  final bool autoSafe;

  /// The last unexpected exit; cleared once a later run gets going.
  final RuntimeFailure? failure;

  /// The main profile's last failure: what safe mode is there to fix.
  final RuntimeFailure? mainFailure;

  /// When the current normal run will count as healthy (two minutes after its login line).
  final DateTime? healthyAt;

  /// Android reports this app's network blocked right now (e.g. a vendor background policy).
  final bool networkBlocked;

  /// When the latest such block started; kept after it lifts.
  final DateTime? networkBlockedAt;

  /// App-local launch option. Unknown/older runtimes remain on the default path.
  final bool directEngineEnabled;
  final bool directEngineAvailable;
  final bool directEngineActive;
  final String? directEngineFallbackReason;

  /// The opt-in tawcroot launch (native `TawcrootLaunch`); one of it and Direct is on at most.
  final bool tawcEngineEnabled;
  final bool tawcEngineAvailable;
  final bool tawcEngineActive;

  /// Native process observation, never inferred from the saved direct preference.
  final String? currentExecutionMode;

  /// Latest attempt, including attempts that failed before spawning a process.
  final String? launchSelectedMode;
  final bool launchSpawned;
  final String? launchFailureReason;

  /// The start in progress has been turning PRoot's fake hard links into real
  /// files for more than a moment (once per install, before Direct launch).
  final bool tidyingFiles;

  /// iOS: the system is letting the engine keep running while the app is away.
  final bool continuedRun;

  Map<String, Object?> get launchDiagnostics => {
    'directEngineEnabled': directEngineEnabled,
    'directEngineAvailable': directEngineAvailable,
    'directEngineActive': directEngineActive,
    'directEngineFallbackReason': directEngineFallbackReason,
    'tawcEngineEnabled': tawcEngineEnabled,
    'tawcEngineAvailable': tawcEngineAvailable,
    'tawcEngineActive': tawcEngineActive,
    'currentExecutionMode': currentExecutionMode,
    'launchSelectedMode': launchSelectedMode,
    'launchSpawned': launchSpawned,
    'launchFailureReason': launchFailureReason,
  };

  bool get isRunning => phase == RuntimePhase.running && baseUrl != null && token != null;

  /// The install stopped because what a reset kept could not go back (Kotlin
  /// `KeepFailed`); `install(dropKept: true)` gives it up and carries on.
  bool get keepFailed => phase == RuntimePhase.error && (error?.startsWith('install failed: keep: ') ?? false);

  /// The engine is (or will next start) in safe mode.
  bool get inSafeMode => mode == EngineMode.safe;

  /// Normal mode on trial after leaving safe mode.
  bool get onProbation => safeState == SafeModeState.probation;

  factory RuntimeStatus.fromMap(Map<Object?, Object?> map) => RuntimeStatus(
    phase: RuntimePhase.parse(map['phase']),
    abi: map['abi'] as String?,
    bundledVersion: map['bundledVersion'] as String?,
    installedVersion: map['installedVersion'] as String?,
    dshVersion: map['dshVersion'] as String?,
    nodeVersion: map['nodeVersion'] as String?,
    baseUrl: map['baseUrl'] as String?,
    token: map['token'] as String?,
    managedSkillGeneration: switch (map['managedSkillGeneration']) {
      final int value when value > 0 => value,
      _ => null,
    },
    error: map['error'] as String?,
    mode: EngineMode.parse(map['mode']),
    workspaceRecovery: map['workspaceRecovery'] == true,
    safeState: SafeModeState.parse(map['safeState']),
    safeReason: map['safeReason'] as String?,
    strikes: (map['strikes'] as num?)?.toInt() ?? 0,
    autoSafe: map['autoSafe'] != false,
    failure: RuntimeFailure.fromMap(map['failure']),
    mainFailure: RuntimeFailure.fromMap(map['mainFailure']),
    healthyAt: switch (map['healthyAt']) {
      final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
      _ => null,
    },
    networkBlocked: map['networkBlocked'] == true,
    networkBlockedAt: switch (map['networkBlockedAt']) {
      final num ms => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
      _ => null,
    },
    directEngineEnabled: map['directEngineEnabled'] == true,
    directEngineAvailable: map['directEngineAvailable'] == true,
    directEngineActive: map['directEngineActive'] == true,
    directEngineFallbackReason: map['directEngineFallbackReason'] as String?,
    tawcEngineEnabled: map['tawcEngineEnabled'] == true,
    tawcEngineAvailable: map['tawcEngineAvailable'] == true,
    tawcEngineActive: map['tawcEngineActive'] == true,
    currentExecutionMode: map['currentExecutionMode'] as String?,
    launchSelectedMode: map['launchSelectedMode'] as String?,
    launchSpawned: map['launchSpawned'] == true,
    launchFailureReason: map['launchFailureReason'] as String?,
    tidyingFiles: map['tidyingFiles'] == true,
    continuedRun: map['continuedRun'] == true,
  );
}

/// What "恢复上次正常的配置" would change in the main profile.
class LastKnownGood {
  const LastKnownGood({
    required this.available,
    this.at,
    this.disable = const [],
    this.enable = const [],
    this.changed = const [],
    this.patchChanged = false,
    this.empty = true,
  });

  const LastKnownGood.none() : this(available: false);

  factory LastKnownGood.fromMap(Map<Object?, Object?> map) {
    List<String> strings(Object? v) => v is List
        ? [
            for (final e in v)
              if (e is String) e,
          ]
        : const [];
    return LastKnownGood(
      available: map['available'] == true,
      at: switch (map['at']) {
        final num ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms.toInt()),
        _ => null,
      },
      disable: strings(map['disable']),
      enable: strings(map['enable']),
      changed: strings(map['changed']),
      patchChanged: map['patchChanged'] == true,
      empty: map['empty'] != false,
    );
  }

  /// A snapshot exists and the main profile exists.
  final bool available;
  final DateTime? at;

  /// Bundles that would be turned off (added or upgraded since).
  final List<String> disable;

  /// Bundles that would be turned back on.
  final List<String> enable;

  /// Of [disable]: upgraded in place since (can only be turned off, not downgraded).
  final List<String> changed;

  /// The settings layer (`cordis.patch.yml`) would go back to the snapshot's.
  final bool patchChanged;

  /// Restoring would change nothing.
  final bool empty;

  /// Restoring is possible and would change something.
  bool get useful => available && !empty;
}

/// A home-level file that applies to every profile, the safe one included.
class SafeHazard {
  const SafeHazard({required this.path, required this.kind, required this.detail});

  factory SafeHazard.fromMap(Map<Object?, Object?> map) => SafeHazard(
    path: map['path'] as String? ?? '',
    kind: map['kind'] as String? ?? '',
    detail: map['detail'] as String? ?? '',
  );

  /// Guest path, e.g. `/root/.dsh/.env`.
  final String path;

  /// `homePatch`, `homeEnv` or `cwdEnv`.
  final String kind;

  /// One Chinese sentence.
  final String detail;
}

/// Whether the Linux environment can see the phone's shared storage.
class StorageAccess {
  const StorageAccess({
    required this.granted,
    required this.permission,
    required this.legacy,
    this.guestPath = '/sdcard',
  });

  factory StorageAccess.fromMap(Map<Object?, Object?> map) => StorageAccess(
    granted: map['granted'] == true,
    permission: map['permission'] == true,
    legacy: map['legacy'] == true,
    guestPath: map['guestPath'] as String? ?? '/sdcard',
  );

  final bool granted;

  /// The runtime permission is granted (may still need "All files access" when not [legacy]).
  final bool permission;
  final bool legacy;
  final String guestPath;
}

sealed class RuntimeEvent {
  const RuntimeEvent();
}

class RuntimeStatusEvent extends RuntimeEvent {
  const RuntimeStatusEvent(this.status);
  final RuntimeStatus status;
}

class RuntimeProgressEvent extends RuntimeEvent {
  const RuntimeProgressEvent({required this.step, required this.done, required this.total});
  final String step;
  final int done;
  final int total;

  double get fraction => total <= 0 ? 0 : (done / total).clamp(0, 1).toDouble();
}

class RuntimeLogEntry {
  const RuntimeLogEntry(this.seq, this.line, this.stream);

  factory RuntimeLogEntry.fromMap(Map<Object?, Object?> raw) =>
      RuntimeLogEntry(raw['seq'] as int, raw['line'] as String, raw['stream'] as String);

  final int seq;
  final String line;
  final String stream;
}

class RuntimeLogsEvent extends RuntimeEvent {
  const RuntimeLogsEvent(this.entries);
  final List<RuntimeLogEntry> entries;
}

class RuntimeLogSnapshot {
  const RuntimeLogSnapshot(this.entries, this.throughSeq);
  final List<RuntimeLogEntry> entries;
  final int throughSeq;
}

List<RuntimeLogEntry> _logEntries(Object? raw) => [
  for (final entry in raw as List) RuntimeLogEntry.fromMap(entry as Map<Object?, Object?>),
];

/// One-off message from the native side, e.g. "已用安全模式启动".
class RuntimeNoticeEvent extends RuntimeEvent {
  const RuntimeNoticeEvent(this.text);
  final String text;
}

/// See [RuntimeBridge.backgroundSettings].
class BackgroundSettingsInfo {
  const BackgroundSettingsInfo({this.vendor, this.label});
  final String? vendor;
  final String? label;
}

/// What 「重置运行环境」 keeps of the old /root (Kotlin `ResetKeep`); the next
/// install puts it back.
class ResetKeep {
  const ResetKeep({this.uiAndSkills = false, this.pluginsAndSettings = false});

  /// `$DSH_HOME/dsh-go` (ui.json) and the user's skills.
  final bool uiAndSkills;

  /// Installed plugins with their settings, `cordis.patch.yml` and `.env`.
  final bool pluginsAndSettings;

  /// The reset dialog's starting choice.
  static const suggested = ResetKeep(uiAndSkills: true);

  List<String> get wire => [if (uiAndSkills) 'uiAndSkills', if (pluginsAndSettings) 'pluginsAndSettings'];

  ResetKeep copyWith({bool? uiAndSkills, bool? pluginsAndSettings}) => ResetKeep(
    uiAndSkills: uiAndSkills ?? this.uiAndSkills,
    pluginsAndSettings: pluginsAndSettings ?? this.pluginsAndSettings,
  );

  @override
  bool operator ==(Object other) =>
      other is ResetKeep && other.uiAndSkills == uiAndSkills && other.pluginsAndSettings == pluginsAndSettings;

  @override
  int get hashCode => Object.hash(uiAndSkills, pluginsAndSettings);

  @override
  String toString() => 'ResetKeep(${wire.join(', ')})';
}

/// Transaction outcome plus whether its native runtime scope is still current.
class ManagedSkillInstallResponse {
  const ManagedSkillInstallResponse({this.result, this.current = false, this.reason});
  final String? result;
  final bool current;
  final String? reason;
}

/// Dart side of the `dsh/runtime` platform channels implemented in Kotlin.
class RuntimeBridge {
  RuntimeBridge({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('dsh/runtime'),
      _events = events ?? const EventChannel('dsh/runtime/events');

  final MethodChannel _methods;
  final EventChannel _events;
  Stream<RuntimeEvent>? _stream;

  Stream<RuntimeEvent> get events => _stream ??= _events
      .receiveBroadcastStream()
      .map((raw) => _parse(raw as Map<Object?, Object?>))
      .where((e) => e != null)
      .cast<RuntimeEvent>();

  Future<RuntimeStatus> status() async {
    final map = await _methods.invokeMapMethod<Object?, Object?>('getStatus');
    return map == null ? const RuntimeStatus.unknown() : RuntimeStatus.fromMap(map);
  }

  /// Serializes local bundled-skill IO with native rootfs activation/reset. A
  /// retired request can have completed an earlier file commit: no rollback is
  /// implied by [ManagedSkillInstallResponse.current] being false. Tokens stay
  /// private to this channel and must never be logged.
  Future<ManagedSkillInstallResponse> installManagedSkill({
    required String requestId,
    required String expectedRoot,
    required String expectedToken,
    required int? expectedGeneration,
    required String name,
    required Map<String, String> files,
  }) async {
    final map = await _methods.invokeMapMethod<Object?, Object?>('installManagedSkill', {
      'requestId': requestId,
      'expectedRoot': expectedRoot,
      'expectedToken': expectedToken,
      'expectedGeneration': expectedGeneration,
      'name': name,
      'files': files,
    });
    return ManagedSkillInstallResponse(
      result: map?['result'] as String?,
      current: map?['current'] == true,
      reason: map?['reason'] as String?,
    );
  }

  /// Exact cancellation; the worker retains its slot until physical IO exits.
  Future<void> cancelManagedSkill(String requestId) =>
      _methods.invokeMethod<void>('cancelManagedSkill', {'requestId': requestId});

  /// [dropKept]: give up what a reset kept but cannot be put back.
  Future<void> install({bool dropKept = false}) =>
      _methods.invokeMethod<void>('install', dropKept ? const {'dropKept': true} : null);

  /// [phoneStorage] mounts the phone's shared storage at /sdcard (needs [requestStorage] first).
  /// [mode] null keeps the current mode; [EngineMode.normal] while in safe mode starts the
  /// two-minute trial back in normal mode. [visualReplies] writes the dsh-ui section
  /// into the managed AGENTS.md.
  Future<void> start({
    Map<String, String> env = const {},
    bool phoneStorage = false,
    EngineMode? mode,
    bool visualReplies = true,
  }) => _methods.invokeMethod<void>('start', {
    'env': env,
    'phoneStorage': phoneStorage,
    'mode': mode?.name,
    'visualReplies': visualReplies,
  });

  Future<LastKnownGood> lastKnownGood() async {
    final map = await _methods.invokeMapMethod<Object?, Object?>('lastKnownGood');
    return map == null ? const LastKnownGood.none() : LastKnownGood.fromMap(map);
  }

  /// Puts the main profile's plugin list and settings layer back to the last good run's;
  /// resolves with what changed. Needs the engine stopped (or in safe mode).
  Future<LastKnownGood> restoreLastKnownGood() async {
    final map = await _methods.invokeMapMethod<Object?, Object?>('restoreLastKnownGood');
    return map == null ? const LastKnownGood.none() : LastKnownGood.fromMap({...map, 'available': true});
  }

  Future<List<SafeHazard>> safePreflight() async {
    final list = await _methods.invokeListMethod<Object?>('safePreflight') ?? const [];
    return [
      for (final e in list)
        if (e is Map) SafeHazard.fromMap(e.cast<Object?, Object?>()),
    ];
  }

  /// Renames the given preflight files to `<name>.off-<time>`; returns the new guest paths.
  Future<List<String>> moveAside(List<String> paths) async {
    final list = await _methods.invokeListMethod<Object?>('moveAside', {'paths': paths}) ?? const [];
    return [
      for (final e in list)
        if (e is Map && e['to'] is String) e['to'] as String,
    ];
  }

  Future<void> clearFailure() => _methods.invokeMethod<void>('clearFailure');

  Future<void> setAutoSafe(bool enabled) => _methods.invokeMethod<void>('setAutoSafe', {'enabled': enabled});

  /// Selects the local workspace index for subsequent starts. Native code
  /// verifies the engine is stopped; this call does not start or stop it.
  Future<void> setWorkspaceRecovery(bool enabled) =>
      _methods.invokeMethod<void>('setWorkspaceRecovery', {'enabled': enabled});

  /// Takes effect on the next start; native code rejects changes while active.
  Future<void> setDirectEngine(bool enabled) => _methods.invokeMethod<void>('setDirectEngine', {'enabled': enabled});
  Future<void> setTawcEngine(bool enabled) => _methods.invokeMethod<void>('setTawcEngine', {'enabled': enabled});

  /// Output around the last failure, tokens masked.
  Future<List<String>> failureLog() async => (await _methods.invokeListMethod<String>('failureLog')) ?? const [];

  Future<StorageAccess> storageStatus() async =>
      StorageAccess.fromMap(await _methods.invokeMapMethod<Object?, Object?>('storageStatus') ?? const {});

  /// Shows the system storage permission prompt; resolves with the resulting access.
  Future<StorageAccess> requestStorage() async =>
      StorageAccess.fromMap(await _methods.invokeMapMethod<Object?, Object?>('requestStorage') ?? const {});

  /// Opens Android's "All files access" page for this app (fallback when legacy access is off).
  Future<bool> openAllFilesAccess() async => await _methods.invokeMethod<bool>('openAllFilesAccess') ?? false;

  /// Whether Android leaves DSH out of battery optimization; null without the native side.
  Future<bool?> batteryExempt() async {
    try {
      return await _methods.invokeMethod<bool>('batteryExempt');
    } on MissingPluginException {
      return null;
    }
  }

  /// Asks for the exemption (the system dialog, else the closest settings page); false if none opened.
  Future<bool?> requestBatteryExempt() async {
    try {
      return await _methods.invokeMethod<bool>('requestBatteryExempt');
    } on MissingPluginException {
      return null;
    }
  }

  /// The phone maker (`vivo`, `xiaomi`, `huawei`, `honor`, `oppo`, `samsung`, null for the
  /// rest) and the app's name as the system settings list it; null without the native side.
  Future<BackgroundSettingsInfo?> backgroundSettings() async {
    try {
      final map = await _methods.invokeMapMethod<Object?, Object?>('backgroundSettings');
      if (map == null) return null;
      return BackgroundSettingsInfo(vendor: map['vendor'] as String?, label: map['label'] as String?);
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens the maker's background-running page, else the app's system details page:
  /// `vendor`, `details`, or null when nothing opened.
  Future<String?> openBackgroundSettings() async {
    try {
      return await _methods.invokeMethod<String>('openBackgroundSettings');
    } on MissingPluginException {
      return null;
    }
  }

  /// Opens the maker's page for one of its own switches ([vendorSwitch]: `background`,
  /// `autostart`, `popup`), else the app's system details page: `vendor`, `details`, or null
  /// when nothing opened (also without the native side).
  Future<String?> openVendorSettings(String vendorSwitch) async {
    try {
      return await _methods.invokeMethod<String>('openVendorSettings', {'switch': vendorSwitch});
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Whether the active network is metered (mobile data); null when unknown or without the
  /// native side.
  Future<bool?> networkMetered() async {
    try {
      return await _methods.invokeMethod<bool>('networkMetered');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> stop() => _methods.invokeMethod<void>('stop');

  /// HarmonyOS: closes the app and opens it again, the only way to another engine start.
  Future<void> reopenApp() => _methods.invokeMethod<void>('reopenApp');

  /// iOS: whether a local turn is running, which is what asks the system to let it go on.
  Future<void> setTurnRunning(bool running) => _methods.invokeMethod<void>('turnRunning', {'running': running});

  /// Deletes the runtime with everything in /root except [keep].
  Future<void> reset({ResetKeep keep = const ResetKeep()}) => _methods.invokeMethod<void>('reset', {'keep': keep.wire});

  Future<List<String>> logs({int lines = 500}) async =>
      (await _methods.invokeListMethod<String>('getLogs', {'lines': lines})) ?? const [];

  Future<RuntimeLogSnapshot> logSnapshot({int lines = 300}) async {
    final raw = await _methods.invokeMapMethod<Object?, Object?>('getLogSnapshot', {'lines': lines});
    return RuntimeLogSnapshot(_logEntries(raw!['entries']), raw['throughSeq'] as int);
  }

  static RuntimeEvent? _parse(Map<Object?, Object?> raw) {
    switch (raw['type']) {
      case 'status':
        return RuntimeStatusEvent(RuntimeStatus.fromMap(raw['status'] as Map<Object?, Object?>));
      case 'progress':
        return RuntimeProgressEvent(
          step: raw['step'] as String? ?? 'extract',
          done: (raw['done'] as num?)?.toInt() ?? 0,
          total: (raw['total'] as num?)?.toInt() ?? 0,
        );
      case 'logs':
        return RuntimeLogsEvent(_logEntries(raw['entries']));
      case 'notice':
        final text = raw['text'] as String?;
        return text == null || text.isEmpty ? null : RuntimeNoticeEvent(text);
    }
    return null;
  }
}
