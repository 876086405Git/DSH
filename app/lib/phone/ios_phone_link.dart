// Dart side of `dsh/phone_link` + `dsh/phone_link/events` (iOS): the setup-only channel for the
// phone's own developer connection (CoreDevice). The native side is
// app/ios/Runner/IOSPhoneLink.swift; its contract is tooling/ios/phone-control/UI-CONTRACT.md.
// Everything that asks the user (how to keep the pairing record, turning the connection on,
// downloading the disk image, restoring the clipboard) is a native dialog: nothing here answers
// for the user.

import 'package:flutter/services.dart';

/// Where the pairing record is kept.
enum PhoneLinkStorage {
  /// The Keychain on this phone only (「记住在这台手机上」).
  device,

  /// In memory until the app quits (「只用这一次」).
  session,
  none,
  unknown,
}

/// The connection's phase, as the native owner reports it.
enum PhoneLinkPhase { idle, starting, ready, stopping, failed, faulted }

final class PhoneLinkStatus {
  const PhoneLinkStatus({
    this.enabled = false,
    this.xctestEnabled = false,
    this.buildAvailable = false,
    this.pairingPresent = false,
    this.storage = PhoneLinkStorage.none,
    this.pairingCode = 'OK',
    this.legacyPairing = false,
    this.phase = PhoneLinkPhase.idle,
    this.stage,
    this.checks = const {},
    this.connectionCode = 'OK',
    this.lastCheck,
    this.lastCheckPhase,
    this.lastCheckChecks = const {},
    this.lastCheckCapabilities = const {},
    this.lastCheckCode,
    this.ddiVerified = false,
    this.ddiDownloading = false,
    this.operationPending = false,
    this.downloaded = 0,
    this.downloadTotal = 0,
    this.clipboardPending = false,
    this.pasteMayHaveHappened = false,
  });

  /// The developer connection switch. A saved record doesn't turn it on.
  final bool enabled;

  /// The XCTest enhancement, a separate switch.
  final bool xctestEnabled;

  /// This build has the native side and the phone runs iOS 17 or later. Not a connection.
  final bool buildAvailable;

  /// A record is there to use. Not that pairing has been verified.
  final bool pairingPresent;
  final PhoneLinkStorage storage;

  /// `OK` or a stable `ERR_PHONE_...` code for the record.
  final String pairingCode;

  /// An old plain-text record from an earlier build waits to be moved.
  final bool legacyPairing;
  final PhoneLinkPhase phase;

  /// The machine stage while connecting (`pairing`, `tunnel`, `services`, ...).
  final String? stage;

  /// Only the checks that actually came back: `vpnReachable`, `pairingVerified`, `lockdownReady`,
  /// `ddiMounted`.
  final Map<String, bool> checks;
  final String connectionCode;

  /// When the last check ran, and what it found. A settings check stops its connection when done,
  /// so this is what stays on the page.
  final DateTime? lastCheck;
  final PhoneLinkPhase? lastCheckPhase;
  final Map<String, bool> lastCheckChecks;
  final Map<String, bool> lastCheckCapabilities;
  final String? lastCheckCode;

  /// A downloaded disk image passed its hash check in this run. Not that it is mounted.
  final bool ddiVerified;
  final bool ddiDownloading;

  /// A setup step is under way: further taps wait, cancel stays.
  final bool operationPending;
  final int downloaded;
  final int downloadTotal;

  /// Text was typed through the clipboard and the original waits to be put back.
  final bool clipboardPending;

  /// That paste may have reached the other app.
  final bool pasteMayHaveHappened;

  bool get downloading => downloadTotal > 0;

  factory PhoneLinkStatus.fromMap(Map<Object?, Object?> map) {
    Map<Object?, Object?> sub(Object? value) => value is Map ? value : const {};
    Map<String, bool> bools(Object? value) => {
      for (final MapEntry(:key, :value) in sub(value).entries)
        if (key is String && value is bool) key: value,
    };
    PhoneLinkPhase? phaseOf(Object? value) => PhoneLinkPhase.values.asNameMap()[value];
    final pairing = sub(map['pairing']);
    final connection = sub(map['connection']);
    final last = sub(map['lastCheck']);
    final lastConnection = sub(last['connection']);
    final cache = sub(map['ddiCache']);
    final progress = sub(map['progress']);
    final clipboard = sub(map['clipboard']);
    final time = last['time'];
    return PhoneLinkStatus(
      enabled: map['enabled'] == true,
      xctestEnabled: map['xctestEnabled'] == true,
      buildAvailable: map['buildAvailable'] == true,
      pairingPresent: pairing['present'] == true,
      storage: PhoneLinkStorage.values.asNameMap()[pairing['storage']] ?? PhoneLinkStorage.unknown,
      pairingCode: pairing['code'] as String? ?? 'OK',
      legacyPairing: map['legacyPairingNeedsMigration'] == true,
      phase: phaseOf(connection['phase']) ?? PhoneLinkPhase.idle,
      stage: connection['stage'] as String?,
      checks: bools(connection['checks']),
      connectionCode: connection['code'] as String? ?? 'OK',
      lastCheck: time is num ? DateTime.fromMillisecondsSinceEpoch((time * 1000).round()) : null,
      lastCheckPhase: phaseOf(lastConnection['phase']),
      lastCheckChecks: bools(lastConnection['checks']),
      lastCheckCapabilities: bools(lastConnection['capabilities']),
      lastCheckCode: lastConnection['code'] as String?,
      ddiVerified: cache['verifiedThisProcess'] == true,
      ddiDownloading: cache['downloading'] == true,
      operationPending: map['operationPending'] == true,
      downloaded: (progress['completedBytes'] as num?)?.toInt() ?? 0,
      downloadTotal: (progress['totalBytes'] as num?)?.toInt() ?? 0,
      clipboardPending: clipboard['pendingRestore'] == true,
      pasteMayHaveHappened: clipboard['pasteMayHaveBeenDispatched'] == true,
    );
  }
}

/// What a setup step came back with.
final class PhoneLinkResult {
  const PhoneLinkResult(this.ok, this.code, this.status);
  final bool ok;

  /// `OK` or `ERR_PHONE_...`. `ERR_PHONE_CANCELLED` is the user saying no (or leaving the app
  /// while a dialog was up), not a failure to show.
  final String code;
  final PhoneLinkStatus? status;

  bool get cancelled => code == 'ERR_PHONE_CANCELLED';
}

/// The channel (a fake one in tests).
abstract interface class PhoneLinkApi {
  Stream<PhoneLinkStatus> get events;
  Future<PhoneLinkStatus> status();
  Future<PhoneLinkResult> importPairing();
  Future<PhoneLinkResult> migrateLegacyPairing();
  Future<PhoneLinkResult> clearPairing();
  Future<PhoneLinkResult> setEnabled(bool enabled);
  Future<PhoneLinkResult> setXCTestEnabled(bool enabled);
  Future<PhoneLinkResult> checkConnection();
  Future<PhoneLinkResult> mountDDI();
  Future<PhoneLinkResult> cancelPreparation();
  Future<PhoneLinkResult> restoreClipboard({bool overwriteChanged = false});
  Future<PhoneLinkResult> discardSavedClipboard();
}

final class PhoneLinkChannel implements PhoneLinkApi {
  static const _methods = MethodChannel('dsh/phone_link');
  static const _events = EventChannel('dsh/phone_link/events');
  Stream<PhoneLinkStatus>? _stream;

  @override
  Stream<PhoneLinkStatus> get events => _stream ??= _events.receiveBroadcastStream().map(
    (event) => PhoneLinkStatus.fromMap(Map<Object?, Object?>.from(event as Map)),
  );

  @override
  Future<PhoneLinkStatus> status() async {
    final value = await _methods.invokeMapMethod<Object?, Object?>('status');
    if (value == null) throw StateError('Missing phone link status.');
    return PhoneLinkStatus.fromMap(value);
  }

  Future<PhoneLinkResult> _call(String method, [Map<String, Object?>? arguments]) async {
    final value = await _methods.invokeMapMethod<Object?, Object?>(method, arguments);
    if (value == null) return const PhoneLinkResult(false, 'ERR_PHONE_NATIVE_UNAVAILABLE', null);
    final status = value['status'];
    return PhoneLinkResult(
      value['ok'] == true,
      value['code'] as String? ?? 'ERR_PHONE_CONFIGURATION',
      status is Map ? PhoneLinkStatus.fromMap(status) : null,
    );
  }

  @override
  Future<PhoneLinkResult> importPairing() => _call('importPairing');
  @override
  Future<PhoneLinkResult> migrateLegacyPairing() => _call('migrateLegacyPairing');
  @override
  Future<PhoneLinkResult> clearPairing() => _call('clearPairing');
  @override
  Future<PhoneLinkResult> setEnabled(bool enabled) => _call('setEnabled', {'enabled': enabled});
  @override
  Future<PhoneLinkResult> setXCTestEnabled(bool enabled) => _call('setXCTestEnabled', {'enabled': enabled});
  @override
  Future<PhoneLinkResult> checkConnection() => _call('checkConnection');
  @override
  Future<PhoneLinkResult> mountDDI() => _call('mountDDI');
  @override
  Future<PhoneLinkResult> cancelPreparation() => _call('cancelPreparation');
  @override
  Future<PhoneLinkResult> restoreClipboard({bool overwriteChanged = false}) =>
      _call('restoreClipboard', {'overwriteChanged': overwriteChanged});
  @override
  Future<PhoneLinkResult> discardSavedClipboard() => _call('discardSavedClipboard');
}
