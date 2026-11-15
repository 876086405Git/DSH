// The Android side of the diagnostics bundle
// (`diagnostics/DiagnosticsPlugin.kt`).

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart';
import 'system_ime_evidence.dart';

/// A second content boundary for the native voice observation. Unexpected
/// transcript/audio fields never enter an export, even from an older plugin.
Map<String, Object?> voiceDiagnosticsFacts(Object? raw) {
  if (raw is! Map) return const {};
  Map<String, Object?> fields(Map row) {
    const numbers = {'sdk', 'serviceVersion', 'serviceUpdatedAt', 'at', 'code'};
    const booleans = {
      'recognizerAvailable',
      'onDeviceFactoryApiAvailable',
      'onDeviceAvailable',
      'onDeviceFactoryProbed',
      'systemUnreliable',
    };
    const strings = {'defaultService', 'servicePackage', 'environmentId', 'name', 'stage', 'exceptionType'};
    return {
      for (final key in numbers)
        if (row[key] is num) key: row[key],
      for (final key in booleans)
        if (row[key] is bool) key: row[key],
      for (final key in strings)
        if (row[key] case final String value) key: value.length > 256 ? value.substring(0, 256) : value,
    };
  }

  final failures = raw['recentFailures'];
  final services = raw['visibleServices'];
  return {
    ...fields(raw),
    if (failures is List)
      'recentFailures': failures.whereType<Map>().toList().reversed.take(20).toList().reversed.map(fields).toList(),
    if (services is List)
      'visibleServices': services
          .whereType<String>()
          .take(16)
          .map((s) => s.length > 256 ? s.substring(0, 256) : s)
          .toList(),
  };
}

const diagnosticVoiceStages = {
  'preparing',
  'listening',
  'stopping',
  'transcribing',
  'completed',
  'cancelled',
  'error',
  'call_started',
  'capture_started',
  'utterance_ready',
  'recognizing',
  'recognized',
  'reply_received',
  'synthesis_requested',
  'playback_opening',
  'playback_started',
  'interrupted',
  'call_ended',
  'failed',
};
const diagnosticVoiceBackends = {'deepseek', 'cloud', 'system', 'local', 'unknown'};
const diagnosticErrorTypes = {
  'StateError',
  'ArgumentError',
  'RangeError',
  'TypeError',
  'FormatException',
  'TimeoutException',
  'PlatformException',
  'MissingPluginException',
  'FlutterError',
  'AssertionError',
  'SocketException',
  'HttpException',
  'FileSystemException',
  'UnsupportedError',
  'OtherError',
};
final _evidenceLocation = RegExp(r'^package:(?:dsh_app|flutter)/[A-Za-z0-9_/.-]{1,120}\.dart:[0-9]{1,7}:[0-9]{1,7}$');

/// Never accept exception bodies, audio, traces or arbitrary native strings.
Map<String, Object?> diagnosticEvidenceFacts(Object? raw) {
  const kinds = ['appErrors', 'voiceStages', 'processExits'];
  final input = raw is Map ? raw : const {};
  final states = input['availability'];
  final availability = <String, Object?>{
    for (final kind in kinds)
      kind: states is Map && const {'available', 'unavailable', 'unsupported'}.contains(states[kind])
          ? states[kind]
          : 'unavailable',
  };
  var remaining = 60 * 1024;
  List<Map<String, Object?>> rows(String kind) {
    final source = input[kind];
    if (source is! List) return const [];
    final result = <Map<String, Object?>>[];
    final count = kind == 'processExits' ? 8 : 40;
    for (final row in source.skip(source.length > count ? source.length - count : 0)) {
      if (row is! Map || row['at'] is! int || (row['at'] as int) < 0) continue;
      final fields = <String, Object?>{'at': row['at']};
      if (kind == 'appErrors') {
        if (!const {'flutter', 'platform', 'session'}.contains(row['source'])) continue;
        fields['source'] = row['source'];
        fields['errorType'] = diagnosticErrorTypes.contains(row['errorType']) ? row['errorType'] : 'OtherError';
        final stack = row['stack'];
        fields['stack'] = stack is String && stack.length <= 2048
            ? stack.split('\n').where((s) => s.length <= 160 && _evidenceLocation.hasMatch(s)).take(6).join('\n')
            : '';
      } else if (kind == 'voiceStages') {
        if (!diagnosticVoiceStages.contains(row['stage']) || !diagnosticVoiceBackends.contains(row['backend'])) {
          continue;
        }
        fields['stage'] = row['stage'];
        fields['backend'] = row['backend'];
        if (row['code'] is int) fields['code'] = row['code'];
      } else {
        if (row['source'] == 'hiAppEvent') {
          if (!const {'APP_CRASH', 'APP_FREEZE'}.contains(row['event'])) continue;
          fields['source'] = 'hiAppEvent';
          fields['event'] = row['event'];
          if (row['event'] == 'APP_CRASH' && const {'NativeCrash', 'JsError'}.contains(row['crashType'])) {
            fields['crashType'] = row['crashType'];
          }
        } else {
          for (final key in const ['reason', 'status', 'importance', 'pssKb', 'rssKb']) {
            if (row[key] is int) fields[key] = row[key];
          }
        }
      }
      final size = utf8.encode(jsonEncode(fields)).length + 1;
      if (size > remaining) break;
      remaining -= size;
      result.add(fields);
    }
    return result;
  }

  return {
    for (final kind in kinds) kind: rows(kind),
    'availability': availability,
    'limits': const {'maxEntries': 40, 'maxBytes': 64 * 1024},
  };
}

/// App, device and bundled-runtime facts only Android knows.
class NativeDiagnostics {
  const NativeDiagnostics({
    this.app = const {},
    this.device = const {},
    this.manifest = const {},
    this.voice = const {},
    this.evidence = const {},
  });

  factory NativeDiagnostics.fromMap(Map<Object?, Object?> map) {
    Map<String, Object?> section(Object? raw) =>
        raw is Map ? {for (final e in raw.entries) '${e.key}': e.value} : const {};
    return NativeDiagnostics(
      app: section(map['app']),
      device: section(map['device']),
      manifest: section(map['manifest']),
      voice: voiceDiagnosticsFacts(map['voice']),
      evidence: diagnosticEvidenceFacts(map['evidence']),
    );
  }

  /// `versionName`, `versionCode`, `abi`.
  final Map<String, Object?> app;

  /// `manufacturer`, `brand`, `model`, `android`, `sdkInt`, `abis`,
  /// `memoryMb`, `freeStorageMb`, and `display` (`widthPx`, `heightPx`,
  /// `density`, `densityDpi`, `fontScale`).
  final Map<String, Object?> device;

  /// Summary of `assets/runtime/manifest.json`: versions, sizes, file count.
  final Map<String, Object?> manifest;

  /// Content-free recognition service facts and at most 20 failure observations.
  final Map<String, Object?> voice;

  /// Bounded persisted failure metadata, with explicit per-source availability.
  final Map<String, Object?> evidence;
}

/// MethodChannel `dsh/diagnostics`. Without the native side (tests, other
/// platforms) it answers empty.
class DiagnosticsChannel {
  const DiagnosticsChannel([this.channel = const MethodChannel('dsh/diagnostics')]) : _imeSource = 'privilegedIme';
  const DiagnosticsChannel.ohos([this.channel = const MethodChannel('dsh/diagnostics')]) : _imeSource = 'ohosWindowGeometry';

  final MethodChannel channel;
  final String _imeSource;

  Future<void> recordVoiceStage(String stage, {String backend = 'unknown', int? code}) async {
    if (!diagnosticVoiceStages.contains(stage) || !diagnosticVoiceBackends.contains(backend)) return;
    await _record('recordVoiceStage', {'stage': stage, 'backend': backend, 'code': ?code});
  }

  Future<void> recordAppError({required String source, required String errorType, required String stack}) =>
      _record('recordAppError', {'source': source, 'errorType': errorType, 'stack': stack});

  Future<void> _record(String method, Map<String, Object?> fields) async {
    try {
      await channel.invokeMethod<void>(method, fields);
    } on MissingPluginException {
      // Older apps have no persistent evidence API.
    } on PlatformException {
      // Native availability reports a failed write; the original error/voice chain stays intact.
    }
  }

  /// Explicit user export. Android prompts for privileged capture; OH reads
  /// only its own bounded window geometry, with no system log permission.
  Future<SystemImeEvidence> collectSystemIme() async {
    try {
      final raw = await channel.invokeMethod<Object?>('collectSystemIme');
      final at = DateTime.now();
      final evidence = SystemImeEvidence.fromNative(raw, now: at);
      return evidence.source == _imeSource
          ? evidence
          : SystemImeEvidence.failure('failed', at, source: _imeSource);
    } on MissingPluginException {
      return SystemImeEvidence.failure('unsupported', DateTime.now(), source: _imeSource);
    } on PlatformException {
      return SystemImeEvidence.failure('failed', DateTime.now(), source: _imeSource);
    }
  }

  Future<void> cancelSystemIme() async {
    try {
      await channel.invokeMethod<void>('cancelSystemIme');
    } on MissingPluginException {
      // Older apps have no pending system capture.
    } on PlatformException {
      // The Dart generation is revoked even when native cancellation fails.
    }
  }

  Future<NativeDiagnostics> info() async {
    try {
      final map = await channel.invokeMapMethod<Object?, Object?>('info');
      return map == null ? const NativeDiagnostics() : NativeDiagnostics.fromMap(map);
    } on MissingPluginException {
      return const NativeDiagnostics();
    }
  }

  /// The last lines of the engine's log file, up to [maxBytes]: unlike the
  /// in-memory log it survives the app being closed.
  Future<List<String>> engineLog({int maxBytes = 512 * 1024}) async {
    try {
      return await channel.invokeListMethod<String>('engineLog', {'maxBytes': maxBytes}) ?? const [];
    } on MissingPluginException {
      return const [];
    }
  }
}

final diagnosticsChannelProvider = Provider<DiagnosticsChannel>((ref) =>
    ref.watch(operatingSystemProvider) == 'ohos' ? const DiagnosticsChannel.ohos() : const DiagnosticsChannel());
