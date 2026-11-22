part of '../spreset.dart';

/// Stream-decoded HTTP text capped in UTF-16 code units, as TextDecoder plus
/// String.slice in SPreset. A byte cap would truncate CJK responses too early.
class SPresetResponseLogCapture {
  final _text = StringBuffer();
  bool _truncated = false;
  late final ByteConversionSink _decoder = const Utf8Decoder(
    allowMalformed: true,
  ).startChunkedConversion(_SPresetLogTextSink(_append));

  void add(List<int> bytes) => _decoder.add(bytes);

  void _append(String text) {
    final remaining = 1024 * 1024 - _text.length;
    if (text.length > remaining) _truncated = true;
    if (remaining > 0) _text.write(text.length > remaining ? text.substring(0, remaining) : text);
  }

  ({String text, bool truncated}) finish() {
    _decoder.close();
    return (text: _text.toString(), truncated: _truncated);
  }
}

class _SPresetLogTextSink implements Sink<String> {
  _SPresetLogTextSink(this.append);
  final void Function(String text) append;
  @override
  void add(String data) => append(data);
  @override
  void close() {}
}

/// Upstream-shaped bounded reports. Collection and upload require the App's
/// separate opt-in; a preset's LogUpload.enabled cannot enable collection.
class SPresetLogBuffer {
  final _records = <Map<String, Object?>>[];
  List<Map<String, Object?>> get records => _records.map(_spObjectCopy).toList();
  void restore(List<Map<String, Object?>> records) {
    _records.clear();
    _records.addAll(
      records.map((record) => _spObjectCopy({...record, if (record['status'] == 'pending') 'status': 'interrupted'})),
    );
    _trim();
  }

  void add(Map<String, Object?> record) {
    final clean = redactSPresetLogValue(record)! as Map<String, Object?>;
    for (final key in const ['request', 'response', 'apiConfig', 'scriptLogs']) {
      if (!clean.containsKey(key)) continue;
      final serialized = jsonEncode(clean[key]);
      if (serialized.length > 2 * 1024 * 1024) {
        clean[key] = {
          'truncated': true,
          'originalChars': serialized.length,
          'preview': serialized.substring(0, 2 * 1024 * 1024),
        };
      }
    }
    final index = _records.indexWhere((value) => value['id'] == clean['id']);
    if (index >= 0) {
      _records[index] = clean;
    } else {
      _records.add(clean);
    }
    _trim();
  }

  void _trim() {
    var size = _records.fold<int>(0, (sum, record) => sum + jsonEncode(record).length);
    while (_records.length > 20 || (size > 10 * 1024 * 1024 && _records.length > 1)) {
      size -= jsonEncode(_records.removeAt(0)).length;
    }
  }

  Map<String, Object?> report({
    required String presetName,
    required DateTime at,
    Map<String, Object?>? tavernHelper,
    Map<String, Object?>? browserConsole,
  }) => {
    'schemaVersion': 1,
    'exportedAt': at.toUtc().toIso8601String(),
    'client': {'name': 'SPreset', 'version': 'dshgo-native-1', 'presetName': presetName},
    'tavernHelper': redactSPresetLogValue(
      tavernHelper ?? const {'available': false, 'reason': 'App snapshot not supplied'},
    ),
    'browserConsole': redactSPresetLogValue(
      browserConsole ?? const {'available': false, 'reason': 'App snapshot not supplied'},
    ),
    'records': [
      for (final record in _records)
        if (record['presetName'] == presetName) _spObjectCopy(record),
    ],
  };
}

Object? redactSPresetLogValue(Object? value, [String key = '']) {
  final sensitive = RegExp(
    r'^(?:apikey|authorization|proxyauthorization|proxypassword|password|passwd|secret|secretid|accesstoken|refreshtoken|uploadtoken|xapikey|xauthtoken|xcsrftoken|cookie|setcookie|privatekey|userhash)$',
    caseSensitive: false,
  );
  if (sensitive.hasMatch(key.replaceAll(RegExp(r'[-_\s]'), ''))) return '[REDACTED]';
  if (value is List<Object?>) return value.map((item) => redactSPresetLogValue(item)).toList();
  if (value is Map<String, Object?>) {
    return value.map((name, item) => MapEntry(name, redactSPresetLogValue(item, name)));
  }
  if (value is! String) return value;
  var text = value.replaceAllMapped(
    RegExp(r'([?&](?:key|api[_-]?key|token|access_token|secret|password)=)[^&#\s]*', caseSensitive: false),
    (match) => '${match[1]!}[REDACTED]',
  );
  text = text.replaceAllMapped(
    RegExp(r'(https?://)[^\s/]*@', caseSensitive: false),
    (match) => '${match[1]!}[REDACTED]@',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'''^(\s*(?:["']?)(?:authorization|proxy-authorization|x-api-key|api-key|cookie|x-csrf-token)["']?\s*:\s*).*$''',
      caseSensitive: false,
      multiLine: true,
    ),
    (match) => '${match[1]!}[REDACTED]',
  );
  text = text.replaceAllMapped(
    RegExp(
      r'("(?:api[_-]?key|proxy_password|authorization|access_token|refresh_token|secret)"\s*:\s*")[^"\r\n]*"',
      caseSensitive: false,
    ),
    (match) => '${match[1]!}[REDACTED]"',
  );
  return text.length > 1024 * 1024 ? '${text.substring(0, 1024 * 1024)}\n[TRUNCATED]' : text;
}

Future<Map<String, Object?>> uploadSPresetLogReport(
  Uri address,
  Map<String, Object?> report, {
  required bool enabled,
  String? bearerToken,
  http.Client? client,
}) async {
  if (!enabled) {
    throw const SPresetException('LogUpload', 'Log upload is disabled; enable it explicitly in App settings.');
  }
  if (!const {'http', 'https'}.contains(address.scheme) || address.host.isEmpty || address.userInfo.isNotEmpty) {
    throw const SPresetException('LogUpload', 'Upload address must be HTTP(S) without URL credentials.');
  }
  final transport = client ?? http.Client();
  try {
    final response = await transport
        .post(
          address,
          headers: {
            'Content-Type': 'application/json',
            if (bearerToken != null && bearerToken.isNotEmpty) 'Authorization': 'Bearer $bearerToken',
          },
          body: jsonEncode(redactSPresetLogValue(report)),
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SPresetException('LogUpload', 'Upload failed with HTTP ${response.statusCode}');
    }
    Object? result;
    try {
      result = jsonDecode(response.body);
    } on FormatException {
      result = const <String, Object?>{};
    }
    return {'id': _spMap(result)['id'] ?? '', 'count': _spRows(report['records']).length};
  } finally {
    if (client == null) transport.close();
  }
}
