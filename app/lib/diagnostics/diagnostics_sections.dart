import 'dart:convert';

import 'diagnostics_bundle.dart';
import 'diagnostics_channel.dart';
import 'redact.dart';

/// Only these content-free facts may be sent by automatic analysis. Manual
/// exports retain their existing, broader collection and consent boundary.
Map<String, Object?> diagnosticsAnalysisFacts(DiagnosticsSnapshot s) {
  Object? fact(Object? value) => value is num || value is bool
      ? value
      : value is String && value.length <= 128 && RegExp(r'^[A-Za-z0-9 ._+()-]+$').hasMatch(value)
      ? value
      : null;
  Map<String, Object?> fields(Map<String, Object?> source, List<String> keys) => {
    for (final key in keys) key: ?fact(source[key]),
  };
  final failure = s.status.failure;
  return {
    'generatedAt': s.at.toUtc().toIso8601String(),
    'app': fields(s.native.app, ['versionName', 'versionCode', 'abi']),
    'device': fields(s.native.device, [
      'manufacturer',
      'model',
      'android',
      'sdkInt',
      'platform',
      'osVersion',
      'apiVersion',
    ]),
    'runtime': {
      'phase': s.status.phase.name,
      'mode': s.status.mode.name,
      if (failure != null)
        'failure': {
          'at': failure.at.toUtc().toIso8601String(),
          'kind': failure.kind.name,
          'exitCode': failure.exitCode,
        },
    },
    'evidence': diagnosticEvidenceFacts(s.native.evidence),
  };
}

const diagnosticsSectionBytes = 16 * 1024;

/// Each MCP section is independently bounded. JSON stays parseable even when
/// old observations must be dropped; a long log cannot hide crash evidence.
Map<String, String> diagnosticsSections(DiagnosticsSnapshot s) {
  final at = s.at.toUtc().toIso8601String();
  final evidence = diagnosticEvidenceFacts(s.native.evidence);
  String section(Map<String, Object?> value) => _boundedJson({'generatedAt': at, ...value});
  return {
    'summary': section({'summary': DiagnosticsBundle.summary(s)}),
    'evidence': section({'evidence': evidence}),
    'appErrors': section({
      'availability': (evidence['availability'] as Map?)?['appErrors'] ?? 'unavailable',
      'appErrors': evidence['appErrors'] ?? const [],
    }),
    'voice': section({
      'recognizer': voiceDiagnosticsFacts(s.native.voice),
      'availability': (evidence['availability'] as Map?)?['voiceStages'] ?? 'unavailable',
      'voiceStages': evidence['voiceStages'] ?? const [],
    }),
    'engine': _boundedLog(s.engineLog, at),
    'failure': _boundedLog(s.failureLog, at),
  };
}

String _boundedJson(Map<String, Object?> value) {
  final mutable = jsonDecode(jsonEncode(redactJson(value))) as Map<String, dynamic>;
  var encoded = jsonEncode(mutable);
  while (utf8.encode(encoded).length > diagnosticsSectionBytes) {
    mutable['truncated'] = true;
    if (!_dropOldest(mutable)) {
      return jsonEncode({'generatedAt': value['generatedAt'], 'truncated': true, 'code': 'diagnostics_limit'});
    }
    encoded = jsonEncode(mutable);
  }
  return encoded;
}

bool _dropOldest(Object? value) {
  if (value is Map) {
    for (final child in value.values) {
      if (_dropOldest(child)) return true;
    }
  } else if (value is List && value.isNotEmpty) {
    value.removeAt(0);
    return true;
  }
  return false;
}

String _boundedLog(List<String> lines, String at) {
  final retained = <String>[];
  var bytes = 0;
  var truncated = false;
  // A fixed line count also bounds redaction work on old engine output.
  for (final line in lines.reversed.take(200)) {
    final redacted = redactDiagnostics(line);
    final size = utf8.encode(redacted).length + 1;
    if (bytes + size > diagnosticsSectionBytes - 1024) {
      truncated = true;
      break;
    }
    retained.add(redacted);
    bytes += size;
  }
  return _boundedJson({
    'generatedAt': at,
    'truncated': truncated || retained.length < lines.length,
    'lines': retained.reversed.toList(),
  });
}
