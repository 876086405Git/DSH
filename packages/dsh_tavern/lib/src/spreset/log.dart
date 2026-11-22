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

  ({String text, bool truncated}) finish({Iterable<String> secrets = const []}) {
    _decoder.close();
    return (text: _spresetRedactKnownText(_text.toString(), secrets), truncated: _truncated);
  }

  void discard() {
    _decoder.close();
    _text.clear();
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

String _spresetRedactKnownText(String text, Iterable<String> secrets) {
  for (final secret in secrets) {
    if (secret.isNotEmpty) text = text.replaceAll(secret, '[REDACTED]');
  }
  return text;
}

Object? _spresetRedactKnownValue(Object? value, Iterable<String> secrets) {
  if (secrets.isEmpty) return value;
  if (value is String) {
    final plain = _spresetRedactKnownText(value, secrets);
    if (plain != value) return plain;
    final trimmed = value.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[') || trimmed.startsWith('"')) {
      try {
        return jsonEncode(_spresetRedactKnownValue(jsonDecode(value), secrets));
      } on FormatException {
        // Plain diagnostic text is still filtered by the literal pass above.
      }
    }
    return value;
  }
  if (value is List<Object?>) return value.map((item) => _spresetRedactKnownValue(item, secrets)).toList();
  if (value is Map<String, Object?>) {
    return value.map(
      (key, item) => MapEntry(_spresetRedactKnownText(key, secrets), _spresetRedactKnownValue(item, secrets)),
    );
  }
  return value;
}

/// Raw transport text is retained only after a complete JSON/SSE parse. A
/// truncated or malformed body cannot be safely redacted by field name.
/// Known secrets are also removed from values decoded from JSON escapes.
Object? redactSPresetResponseBody(String text, {bool truncated = false, Iterable<String> secrets = const []}) {
  Map<String, Object?> omitted(String reason) => {'omitted': true, 'reason': reason};
  if (truncated) return omitted('truncated response body');
  if (text.isEmpty) return '';
  try {
    return _spresetRedactKnownValue(redactSPresetLogValue(jsonDecode(text)), secrets);
  } on FormatException {
    // SSE data may itself span several lines; parse complete events rather
    // than independently attempting JSON.parse on each data line.
  }
  final events = <String>[];
  final data = <String>[];
  bool finishEvent() {
    if (data.isEmpty) return true;
    final payload = data.join('\n');
    data.clear();
    if (payload == '[DONE]') {
      events.add('data: [DONE]');
      return true;
    }
    try {
      events.add('data: ${jsonEncode(_spresetRedactKnownValue(redactSPresetLogValue(jsonDecode(payload)), secrets))}');
      return true;
    } on FormatException {
      return false;
    }
  }

  for (final line in const LineSplitter().convert(text.replaceFirst(RegExp(r'^\uFEFF'), ''))) {
    if (line.isEmpty) {
      if (!finishEvent()) return omitted('unparseable SSE data');
    } else if (line == 'data' || line.startsWith('data:')) {
      var value = line == 'data' ? '' : line.substring(5);
      if (value.startsWith(' ')) value = value.substring(1);
      data.add(value);
    } else if (!line.startsWith(':') && !RegExp(r'^(?:event|id|retry)(?::|$)').hasMatch(line)) {
      return omitted('unparseable response body');
    }
  }
  if (!finishEvent() || events.isEmpty) return omitted('unparseable response body');
  // Comments and event/id metadata are not response JSON and are omitted.
  return '${events.join('\n\n')}\n\n';
}

/// Generation-local diagnostics are bounded while collecting them, before a
/// response/report is persisted. Limits follow the fixed SPreset trace limits;
/// this implementation retains the most recent complete evaluation records.
class SPresetScriptLogBuffer {
  static const maxEntries = 500, maxChars = 512 * 1024, maxEntryChars = 65536;
  final _records = <Map<String, Object?>>[];
  int _chars = 0, dropped = 0, truncatedValues = 0, consoleDropped = 0;
  List<Map<String, Object?>> get records => _records.map(_spObjectCopy).toList();

  void add(
    Map<String, Object?> record, {
    Iterable<String> secrets = const [],
    int upstreamDropped = 0,
    int upstreamTruncatedValues = 0,
  }) {
    consoleDropped += upstreamDropped;
    final budget = _SPresetLogValueBudget();
    final bounded = budget.copy(record);
    truncatedValues += budget.truncated + upstreamTruncatedValues;
    var clean =
        _spresetRedactKnownValue(redactSPresetLogValue(_spresetRedactKnownValue(bounded, secrets)), secrets)!
            as Map<String, Object?>;
    var encoded = jsonEncode(clean);
    if (encoded.length > maxEntryChars) {
      truncatedValues++;
      clean = {'truncated': true, 'preview': encoded.substring(0, maxEntryChars ~/ 4)};
      encoded = jsonEncode(clean);
    }
    while (_records.isNotEmpty && (_records.length >= maxEntries || _chars + encoded.length > maxChars)) {
      _chars -= jsonEncode(_records.removeAt(0)).length;
      dropped++;
    }
    _records.add(clean);
    _chars += encoded.length;
  }
}

class _SPresetLogValueBudget {
  int nodes = 0, truncated = 0;
  Object? copy(Object? value, [int depth = 0]) {
    if (++nodes > 500 || depth > 6) {
      truncated++;
      return '[TRUNCATED]';
    }
    if (value is String) {
      if (value.length <= 8192) return value;
      truncated++;
      // A prefix could cut through an authToken value or a known credential.
      // Do not retain fragments that can no longer be structurally redacted.
      return '[OMITTED string: ${value.length} chars]';
    }
    if (value is List<Object?>) {
      truncated += value.length > 50 ? value.length - 50 : 0;
      return value.take(50).map((item) => copy(item, depth + 1)).toList();
    }
    if (value is Map<String, Object?>) {
      truncated += value.length > 50 ? value.length - 50 : 0;
      return {for (final entry in value.entries.take(50)) entry.key: copy(entry.value, depth + 1)};
    }
    return value;
  }
}

/// Upstream-shaped bounded reports. Collection and upload require the App's
/// separate opt-in; a preset's LogUpload.enabled cannot enable collection.
class SPresetLogBuffer {
  final _records = <Map<String, Object?>>[];
  List<Map<String, Object?>> get records => _records.map(_spObjectCopy).toList();
  void restore(List<Map<String, Object?>> records) {
    _records.clear();
    for (final record in records) {
      add({...record, if (record['status'] == 'pending') 'status': 'interrupted'});
    }
  }

  void add(Map<String, Object?> record, {Iterable<String> secrets = const []}) {
    final clean =
        _spresetRedactKnownValue(redactSPresetLogValue(_spresetRedactKnownValue(record, secrets)), secrets)!
            as Map<String, Object?>;
    for (final transport in _spRows(_spMap(clean['response'])['transport'])) {
      if (transport['body'] case final String text) {
        transport['body'] = redactSPresetResponseBody(
          text,
          truncated: transport['truncated'] == true,
          secrets: secrets,
        );
      }
    }
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
    r'^(?:apikey|authorization|proxyauthorization|proxypassword|password|passwd|secret|secretid|authtoken|accesstoken|refreshtoken|uploadtoken|xapikey|xauthtoken|xcsrftoken|cookie|setcookie|privatekey|userhash)$',
    caseSensitive: false,
  );
  if (sensitive.hasMatch(key.replaceAll(RegExp(r'[-_\s]'), ''))) return '[REDACTED]';
  if (value is List<Object?>) return value.map((item) => redactSPresetLogValue(item)).toList();
  if (value is Map<String, Object?>) {
    return value.map((name, item) => MapEntry(name, redactSPresetLogValue(item, name)));
  }
  if (value is! String) return value;
  final trimmed = value.trimLeft();
  if (trimmed.startsWith('{') || trimmed.startsWith('[') || trimmed.startsWith('"')) {
    try {
      return jsonEncode(redactSPresetLogValue(jsonDecode(value)));
    } on FormatException {
      // Embedded diagnostic text is handled below; raw transport bodies use
      // redactSPresetResponseBody and are omitted unless fully parseable.
    }
  }
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
      r'("(?:api[_-]?key|proxy_password|password|passwd|auth[_-]?token|authorization|access_token|refresh_token|secret)"\s*:\s*)"(?:\\.|[^"\\])*"',
      caseSensitive: false,
    ),
    (match) => '${match[1]!}"[REDACTED]"',
  );
  text = text.replaceAllMapped(
    RegExp(r'\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    (match) => '${match[1]!} [REDACTED]',
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
  if (address.scheme != 'https' || address.host.isEmpty || address.userInfo.isNotEmpty) {
    throw const SPresetException('LogUpload', 'Upload address must be HTTPS without URL credentials.');
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
