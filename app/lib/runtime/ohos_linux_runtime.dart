import 'dart:convert';
// The plain-Dart probe (runtime/tests/ohos/linux-runtime-dart.py) swaps services.dart for a stub without Uint8List.
// ignore: unnecessary_import
import 'dart:typed_data';

import 'package:flutter/services.dart';

enum OhosLinuxState {
  disabled,
  installing,
  enabled,
  disabling,
  stopping,
  stopped,
  unavailable,
  failed,
  unknown;

  static OhosLinuxState parse(Object? value) =>
      values.firstWhere((state) => state.name == value, orElse: () => unknown);
}

Never _invalid() =>
    throw const FormatException('Invalid OHOS Linux protocol response');
Map<Object?, Object?> _map(Object? value) => value is Map ? value : _invalid();
bool _bool(Object? value) => value is bool ? value : _invalid();
String _string(Object? value) => value is String ? value : _invalid();
String? _optionalString(Object? value) => value == null ? null : _string(value);
int _integer(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991
    ? value
    : _invalid();

enum OhosLinuxProxyMode { inherit, direct, manual }

/// Current-session settings for explicit LinuxControl jobs. The App must
/// reapply them after an engine restart; this client does not persist secrets.
class OhosLinuxProxyConfiguration {
  const OhosLinuxProxyConfiguration.inherit()
    : mode = OhosLinuxProxyMode.inherit,
      httpProxy = null,
      httpsProxy = null,
      noProxy = null;
  const OhosLinuxProxyConfiguration.direct()
    : mode = OhosLinuxProxyMode.direct,
      httpProxy = null,
      httpsProxy = null,
      noProxy = null;
  const OhosLinuxProxyConfiguration.manual({
    this.httpProxy,
    this.httpsProxy,
    this.noProxy,
  }) : mode = OhosLinuxProxyMode.manual;
  final OhosLinuxProxyMode mode;
  final String? httpProxy;
  final String? httpsProxy;
  final String? noProxy;
  Map<String, String> toMap() => {
    'mode': mode.name,
    'httpProxy': ?httpProxy,
    'httpsProxy': ?httpsProxy,
    'noProxy': ?noProxy,
  };
}

/// Public facts only. URLs, user information and bypass strings are not status.
class OhosLinuxProxyStatus {
  OhosLinuxProxyStatus._(
    this.source,
    this.revision,
    this.httpConfigured,
    this.httpsConfigured,
  );
  factory OhosLinuxProxyStatus.fromMap(Object? raw) {
    final value = _map(raw);
    if (value.keys.any(
      (key) => !const {
        'source',
        'revision',
        'httpConfigured',
        'httpsConfigured',
      }.contains(key),
    )) {
      _invalid();
    }
    final source = OhosLinuxProxyMode.values.firstWhere(
      (mode) => mode.name == value['source'],
      orElse: () => _invalid(),
    );
    final http = _bool(value['httpConfigured']);
    final https = _bool(value['httpsConfigured']);
    if (source == OhosLinuxProxyMode.direct && (http || https) ||
        source == OhosLinuxProxyMode.manual && !http && !https) {
      _invalid();
    }
    return OhosLinuxProxyStatus._(
      source,
      _integer(value['revision']),
      http,
      https,
    );
  }
  final OhosLinuxProxyMode source;
  final int revision;
  final bool httpConfigured;
  final bool httpsConfigured;
}

/// Stable raw bytes already accepted by the Node collector. Reading this value
/// does not acknowledge guest output and cannot complete a running job.
class OhosLinuxOutput {
  OhosLinuxOutput._(this.bytes, this.totalBytes, this.truncated);

  factory OhosLinuxOutput.fromMap(Object? raw) {
    final value = _map(raw);
    if (value['encoding'] != 'base64') _invalid();
    final encoded = _string(value['data']);
    final bytes = base64.decode(encoded);
    final total = _integer(value['totalBytes']);
    final retained = _integer(value['retainedBytes']);
    final truncated = _bool(value['truncated']);
    if (base64.encode(bytes) != encoded ||
        bytes.length > 16384 ||
        retained != bytes.length ||
        total < retained ||
        (total > retained && !truncated)) {
      _invalid();
    }
    return OhosLinuxOutput._(bytes.asUnmodifiableView(), total, truncated);
  }

  final Uint8List bytes;
  final int totalBytes;
  final bool truncated;
  String get text => utf8.decode(bytes, allowMalformed: true);
}

class OhosLinuxOutcome {
  OhosLinuxOutcome._(
    this.exitCode,
    this.signal,
    this.cancelled,
    this.notStarted,
    this.requestedSignal,
  );

  factory OhosLinuxOutcome.fromMap(Object? raw) {
    final value = _map(raw);
    final exit = value['exitCode'] == null ? null : _integer(value['exitCode']);
    final signal = _optionalString(value['signal']);
    final cancelled = _bool(value['cancelled']);
    final notStarted = value['notStarted'] == true;
    if ((exit != null && exit > 255) ||
        (signal != null && !RegExp(r'^SIG[A-Z0-9]+$').hasMatch(signal)) ||
        (exit != null && signal != null) ||
        (exit == null && signal == null && !(cancelled && notStarted))) {
      _invalid();
    }
    return OhosLinuxOutcome._(
      exit,
      signal,
      cancelled,
      notStarted,
      _optionalString(value['requestedSignal']),
    );
  }

  final int? exitCode;
  final String? signal;
  final bool cancelled;
  final bool notStarted;
  final String? requestedSignal;
}

class OhosLinuxJobDiagnostic {
  OhosLinuxJobDiagnostic._(this.category, this.evidence, this.message);

  factory OhosLinuxJobDiagnostic.fromMap(Object? raw) {
    final value = _map(raw);
    final category = _string(value['category']);
    final evidence = _string(value['evidence']);
    final message = _string(value['message']);
    if (!const {
          'dns',
          'connection',
          'tls-interrupted',
          'tls-certificate',
          'unknown',
        }.contains(category) ||
        evidence != (category == 'unknown' ? 'none' : 'stderr') ||
        message.isEmpty ||
        message.length > 512) {
      _invalid();
    }
    return OhosLinuxJobDiagnostic._(category, evidence, message);
  }

  final String category;
  final String evidence;
  final String message;
}

class OhosLinuxJob {
  OhosLinuxJob._(
    this.id,
    this.state,
    this.started,
    this.cancelRequested,
    this.outcome,
    this.errorCode,
    this.diagnostic,
    this.stdout,
    this.stderr,
    this.proxyRevision,
  );

  factory OhosLinuxJob.fromMap(Object? raw) {
    final value = _map(raw);
    final id = _integer(value['id']);
    final state = _string(value['state']);
    if (id < 1) _invalid();
    final knownState =
        const {'queued', 'running', 'settled', 'unknown'}.contains(state)
        ? state
        : 'unknown';
    final outcome = value['outcome'] == null
        ? null
        : OhosLinuxOutcome.fromMap(value['outcome']);
    if ((knownState == 'settled') != (outcome != null)) _invalid();
    final diagnostic = value['diagnostic'] == null
        ? null
        : OhosLinuxJobDiagnostic.fromMap(value['diagnostic']);
    if (diagnostic != null &&
        (knownState != 'settled' ||
            outcome == null ||
            outcome.cancelled ||
            outcome.notStarted ||
            outcome.signal != null ||
            outcome.exitCode == null ||
            outcome.exitCode! < 1 ||
            outcome.exitCode! > 255)) {
      _invalid();
    }
    return OhosLinuxJob._(
      id,
      knownState,
      _bool(value['started']),
      _bool(value['cancelRequested']),
      outcome,
      _optionalString(value['errorCode']),
      diagnostic,
      OhosLinuxOutput.fromMap(value['stdout']),
      OhosLinuxOutput.fromMap(value['stderr']),
      value.containsKey('proxyRevision')
          ? _integer(value['proxyRevision'])
          : null,
    );
  }

  final int id;
  final String state;
  final bool started;
  final bool cancelRequested;
  final OhosLinuxOutcome? outcome;
  final String? errorCode;
  final OhosLinuxJobDiagnostic? diagnostic;
  final OhosLinuxOutput stdout;
  final OhosLinuxOutput stderr;
  final int? proxyRevision;
  bool get settled => state == 'settled';
}

class OhosLinuxProgress {
  OhosLinuxProgress._(this.stage, this.done, this.total, this.step);

  factory OhosLinuxProgress.fromMap(Object? raw) {
    final value = _map(raw);
    return OhosLinuxProgress._(
      _string(value['stage']),
      value['done'] == null ? null : _integer(value['done']),
      value['total'] == null ? null : _integer(value['total']),
      _optionalString(value['step']),
    );
  }

  final String stage;
  final int? done;
  final int? total;
  final String? step;
}

class OhosLinuxGuestClose {
  OhosLinuxGuestClose._(this.epoch);

  factory OhosLinuxGuestClose.fromMap(Object? raw) {
    final value = _map(raw);
    final epoch = _string(value['epoch']);
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(epoch) ||
        value['rootfsSync'] != true ||
        value['syncMethod'] != 'syncfs' ||
        value['syncScope'] != 'rootfs') {
      _invalid();
    }
    return OhosLinuxGuestClose._(epoch);
  }

  final String epoch;
}

class OhosLinuxRetirement {
  OhosLinuxRetirement._(
    this.resourcesRetired,
    this.filesRemoved,
    this.dataRetained,
    this.ownerQuarantined,
    this.nativeJoined,
    this.nativeRetirementError,
    this.nativeApiResult,
    this.releaseErrorCode,
    this.guestClose,
    this.cleanCheckpoint,
  );

  factory OhosLinuxRetirement.fromMap(Object? raw) {
    final value = _map(raw);
    final native = value['native'] == null ? null : _map(value['native']);
    final result = native?['apiResult'];
    if (result != null && result is! int) _invalid();
    final retirement = OhosLinuxRetirement._(
      _bool(value['resourcesRetired']),
      _bool(value['filesRemoved']),
      _bool(value['dataRetained']),
      _bool(value['ownerQuarantined']),
      native == null ? null : _bool(native['joined']),
      native?['retirementError'] == null
          ? null
          : _bool(native!['retirementError']),
      result as int?,
      _optionalString(value['releaseErrorCode']),
      value['guestClose'] == null
          ? null
          : OhosLinuxGuestClose.fromMap(value['guestClose']),
      value.containsKey('cleanCheckpoint')
          ? _bool(value['cleanCheckpoint'])
          : false,
    );
    if (retirement.cleanCheckpoint &&
        (!retirement.resourcesRetired ||
            !retirement.dataRetained ||
            retirement.filesRemoved ||
            retirement.guestClose == null ||
            retirement.nativeJoined != true ||
            retirement.nativeRetirementError != false ||
            (retirement.nativeApiResult != -3 &&
                retirement.nativeApiResult != -4))) {
      _invalid();
    }
    return retirement;
  }

  final bool resourcesRetired;
  final bool filesRemoved;
  final bool dataRetained;
  final bool ownerQuarantined;
  final bool? nativeJoined;
  final bool? nativeRetirementError;
  final int? nativeApiResult;
  final String? releaseErrorCode;
  final OhosLinuxGuestClose? guestClose;
  final bool cleanCheckpoint;
  bool get confirmed =>
      resourcesRetired &&
      (nativeJoined == null
          ? !ownerQuarantined
          : nativeJoined == true && nativeRetirementError == false);
}

/// A read-only observation of the one Node service. It does not grant a host
/// workspace or enable the generic shell/child_process routing.
class OhosLinuxSnapshot {
  OhosLinuxSnapshot._(
    this.instanceId,
    this.attemptId,
    this.persistentInstanceId,
    this.bootMode,
    this.nativeMemoryRelease,
    this.state,
    this.enabled,
    this.admission,
    this.guestOpened,
    this.ownerRetained,
    this.restartRequired,
    this.shutdownComplete,
    this.nextRequestId,
    this.ownerState,
    this.backendState,
    this.progress,
    this.lastErrorCode,
    this.job,
    this.retirement,
    this.proxy,
  );

  factory OhosLinuxSnapshot.fromWire(String wire) {
    final value = _map(jsonDecode(wire));
    if (value['v'] != 1 || value['workspaceLease'] != false) _invalid();
    final instance = _string(value['instanceId']);
    final persistentInstance = _optionalString(value['persistentInstanceId']);
    final bootMode = _optionalString(value['bootMode']);
    final memoryRelease = _optionalString(value['nativeMemoryRelease']);
    if (memoryRelease != null && memoryRelease != 'process-exit') _invalid();
    if ((persistentInstance != null &&
            !RegExp(
              r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
            ).hasMatch(persistentInstance)) ||
        (bootMode != null && bootMode != 'install' && bootMode != 'resume') ||
        (persistentInstance == null) != (bootMode == null)) {
      _invalid();
    }
    final next = _integer(value['nextRequestId']);
    final state = OhosLinuxState.parse(value['state']);
    final opened = _bool(value['guestOpened']);
    final requestedAdmission = _bool(value['admission']);
    final shutdown = _bool(value['shutdownComplete']);
    final retirement = value['retirement'] == null
        ? null
        : OhosLinuxRetirement.fromMap(value['retirement']);
    if (instance.isEmpty ||
        next < 1 ||
        (retirement?.cleanCheckpoint == true && persistentInstance == null) ||
        (shutdown && retirement?.confirmed != true)) {
      _invalid();
    }
    return OhosLinuxSnapshot._(
      instance,
      _optionalString(value['attemptId']),
      persistentInstance,
      bootMode,
      memoryRelease,
      state,
      _bool(value['enabled']),
      state == OhosLinuxState.enabled &&
          opened &&
          requestedAdmission &&
          !shutdown,
      opened,
      _bool(value['ownerRetained']),
      _bool(value['restartRequired']),
      shutdown,
      next,
      _optionalString(value['ownerState']),
      _optionalString(value['backendState']),
      value['progress'] == null
          ? null
          : OhosLinuxProgress.fromMap(value['progress']),
      _optionalString(value['lastErrorCode']),
      value['job'] == null ? null : OhosLinuxJob.fromMap(value['job']),
      retirement,
      value.containsKey('proxy')
          ? OhosLinuxProxyStatus.fromMap(value['proxy'])
          : null,
    );
  }

  final String instanceId;
  final String? attemptId;
  final String? persistentInstanceId;
  final String? bootMode;

  /// Null is an absent ownership fact, never a claim that native memory is free.
  final String? nativeMemoryRelease;
  String? get nativeMemoryNotice => nativeMemoryRelease == null
      ? null
      : 'Linux 原生内存仍保留在当前 App 进程；线程退役不表示内存释放，需退出整个 App 进程后由系统回收。';
  final OhosLinuxState state;
  final bool enabled;
  final bool admission;
  final bool guestOpened;
  final bool ownerRetained;
  final bool restartRequired;
  final bool shutdownComplete;
  final int nextRequestId;
  final String? ownerState;
  final String? backendState;
  final OhosLinuxProgress? progress;
  final String? lastErrorCode;
  final OhosLinuxJob? job;
  final OhosLinuxRetirement? retirement;
  final OhosLinuxProxyStatus? proxy;
  bool get workspaceLease => false;
}

/// OHOS-only data/MethodChannel client. A 202 acceptance is a snapshot, not a
/// completed installation or command. The caller may poll [getStatus].
class OhosLinuxRuntime {
  const OhosLinuxRuntime({
    this._channel = const MethodChannel('dsh/runtime'),
  });
  final MethodChannel _channel;

  Future<OhosLinuxSnapshot> _call(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    final wire = await _channel.invokeMethod<String>(method, arguments);
    if (wire == null) _invalid();
    return OhosLinuxSnapshot.fromWire(wire);
  }

  Future<OhosLinuxSnapshot> getStatus() => _call('getLinuxStatus');
  Future<OhosLinuxSnapshot> setEnabled(bool enabled) =>
      _call('setLinuxEnabled', {'enabled': enabled});
  Future<OhosLinuxSnapshot> setProxy(OhosLinuxProxyConfiguration proxy) =>
      _call('setLinuxProxy', {'proxy': proxy.toMap()});

  /// 重新安装 Linux: deletes everything inside Linux. Only while it is off (or
  /// its install has failed) and idle; it never switches Linux on. The next
  /// switch-on installs afresh. Unlike [setEnabled] the snapshot comes back
  /// after the deletion has finished.
  Future<OhosLinuxSnapshot> discardRetained() => _call('discardLinuxRetained');

  /// Keep [scope] when retrying an uncertain transport result. Its fixed request
  /// identity prevents a retry from executing the command a second time.
  Future<OhosLinuxSnapshot> runPrivateGuest({
    required OhosLinuxSnapshot scope,
    required List<String> argv,
    required String cwd,
    Map<String, String> environment = const {},
    String stdin = '',
  }) {
    if (scope.attemptId == null) {
      throw StateError('Linux has no installation attempt');
    }
    return _call('runLinuxPrivateGuest', {
      'instanceId': scope.instanceId,
      'attemptId': scope.attemptId,
      'requestId': scope.nextRequestId,
      'argv': List<String>.of(argv),
      'cwd': cwd,
      'env': Map<String, String>.of(environment),
      'stdin': stdin,
    });
  }
}
