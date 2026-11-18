// 酒馆 › 模型渠道: where the tavern sends its requests. DeepSeek's own API
// with the app's key is built in; the person may add any OpenAI-compatible
// endpoint (a relay, OpenRouter, a model on their own computer) with its own
// key and model. The list lives in 酒馆设置 (tavern_settings.dart); each
// channel's key is kept in the Keystore-backed secure storage, never in
// preferences.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../secrets/secure_storage.dart';

/// DeepSeek's own API, the built-in channel.
const tavernDeepSeekBaseUrl = 'https://api.deepseek.com';

/// One endpoint the person added.
class TavernChannel {
  const TavernChannel({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.deepseek = false,
    this.headers = const {},
  });

  /// `c<microseconds>`, made once when it is added.
  final String id;
  final String name;

  /// As typed: a root (`https://api.example.com/v1`) or a whole
  /// `…/chat/completions` URL; the engine accepts both.
  final String baseUrl;
  final String model;

  /// Speaks DeepSeek's own API (a relay in front of it): prefix continuation
  /// on `/beta` and the 思考 switch. Off, a plain Chat Completions endpoint.
  final bool deepseek;

  /// Sent with every request (OpenRouter's `HTTP-Referer`, Azure's
  /// `api-key`). They may carry a secret, so they are kept beside the key in
  /// [TavernChannelKeys], never in preferences.
  final Map<String, String> headers;

  /// `api.example.com`, for a row's second line.
  String get host => Uri.tryParse(baseUrl)?.host ?? baseUrl;

  TavernChannel copyWith({
    String? name,
    String? baseUrl,
    String? model,
    bool? deepseek,
    Map<String, String>? headers,
  }) => TavernChannel(
    id: id,
    name: name ?? this.name,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
    deepseek: deepseek ?? this.deepseek,
    headers: headers ?? this.headers,
  );

  /// What preferences keep: everything but [headers].
  Map<String, Object?> toJson() => {'id': id, 'name': name, 'baseUrl': baseUrl, 'model': model, 'deepseek': deepseek};

  /// Null for an entry that is not a channel (preferences written by hand).
  static TavernChannel? fromJson(Object? json) => switch (json) {
    {'id': final String id, 'name': final String name, 'baseUrl': final String baseUrl, 'model': final String model} =>
      TavernChannel(id: id, name: name, baseUrl: baseUrl, model: model, deepseek: json['deepseek'] == true),
    _ => null,
  };

  static List<TavernChannel> listFromJson(String? stored) {
    if (stored == null || stored.isEmpty) return const [];
    try {
      return [for (final entry in jsonDecode(stored) as List<Object?>) ?fromJson(entry)];
    } on FormatException {
      return const [];
    } on TypeError {
      return const [];
    }
  }

  static String listToJson(List<TavernChannel> channels) => jsonEncode([for (final c in channels) c.toJson()]);

  @override
  bool operator ==(Object other) =>
      other is TavernChannel &&
      other.id == id &&
      other.name == name &&
      other.baseUrl == baseUrl &&
      other.model == model &&
      other.deepseek == deepseek &&
      mapEquals(other.headers, headers);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    baseUrl,
    model,
    deepseek,
    Object.hashAllUnordered(headers.entries.map((e) => '${e.key}:${e.value}')),
  );
}

/// `Name: value` lines (one header each, blank lines skipped) as headers;
/// null when a line is not one.
Map<String, String>? tavernParseHeaders(String text) {
  final headers = <String, String>{};
  for (final line in text.split('\n')) {
    if (line.trim().isEmpty) continue;
    final colon = line.indexOf(':');
    if (colon <= 0) return null;
    final name = line.substring(0, colon).trim();
    if (name.isEmpty || name.contains(' ')) return null;
    headers[name] = line.substring(colon + 1).trim();
  }
  return headers;
}

/// [headers] as the lines [tavernParseHeaders] reads.
String tavernHeaderLines(Map<String, String> headers) =>
    [for (final MapEntry(:key, :value) in headers.entries) '$key: $value'].join('\n');

/// Why a Base URL can't be used, or null: it must be http(s) with a host.
String? tavernBaseUrlProblem(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) return 'invalid';
  return null;
}

/// The channels' keys, by channel id.
/// The channels' secrets by channel id: the key, and the request headers.
abstract class TavernChannelKeys {
  Future<String?> read(String id);
  Future<void> write(String id, String key);

  Future<Map<String, String>> readHeaders(String id);

  /// Empty removes them.
  Future<void> writeHeaders(String id, Map<String, String> headers);

  /// Both the key and the headers.
  Future<void> delete(String id);
}

class SecureTavernChannelKeys implements TavernChannelKeys {
  const SecureTavernChannelKeys([this._injected]);

  static const prefix = 'tavern_channel_key_';
  static const headersPrefix = 'tavern_channel_headers_';
  final FlutterSecureStorage? _injected;
  AppSecureStorage get _storage => AppSecureStorage(_injected);

  @override
  Future<String?> read(String id) => _storage.read(key: '$prefix$id');

  @override
  Future<void> write(String id, String key) => _storage.write(key: '$prefix$id', value: key);

  @override
  Future<Map<String, String>> readHeaders(String id) async =>
      switch (_decode(await _storage.read(key: '$headersPrefix$id'))) {
        final Map<String, Object?> headers => {
          for (final MapEntry(:key, :value) in headers.entries)
            if (value is String) key: value,
        },
        _ => const {},
      };

  @override
  Future<void> writeHeaders(String id, Map<String, String> headers) => headers.isEmpty
      ? _storage.delete(key: '$headersPrefix$id')
      : _storage.write(key: '$headersPrefix$id', value: jsonEncode(headers));

  @override
  Future<void> delete(String id) async {
    await _storage.delete(key: '$prefix$id');
    await _storage.delete(key: '$headersPrefix$id');
  }

  static Object? _decode(String? stored) {
    if (stored == null) return null;
    try {
      return jsonDecode(stored);
    } on FormatException {
      return null;
    }
  }
}

final tavernChannelKeysProvider = Provider<TavernChannelKeys>((ref) => const SecureTavernChannelKeys());

/// `GET <root>/models`, the root found the way the engine finds
/// `/chat/completions` from the same Base URL.
Uri tavernModelsUrl(String baseUrl) {
  final uri = Uri.parse(baseUrl.trim()).removeFragment();
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (path.endsWith('/chat/completions')) path = path.substring(0, path.length - '/chat/completions'.length);
  return uri.replace(path: '$path/models', query: uri.query.isEmpty ? null : uri.query);
}

/// What `/models` failed with: the status, or the transport's message.
class TavernModelsException implements Exception {
  const TavernModelsException(this.detail);
  final String detail;

  @override
  String toString() => detail;
}

/// The model ids the endpoint lists, sorted; an endpoint without `/models`
/// (some relays) fails, and the person types the model instead.
/// [headers] go with it, as with every request; the key is the Authorization.
Future<List<String>> fetchTavernModels(
  String baseUrl,
  String? key, {
  Map<String, String> headers = const {},
  http.Client? client,
}) async {
  final own = client == null;
  final hasKey = key != null && key.isNotEmpty;
  final http.Client c = client ?? http.Client();
  try {
    final response = await c
        .get(
          tavernModelsUrl(baseUrl),
          headers: {
            // The key is the Authorization when there is one; a keyless
            // channel may bring its own (Basic, say).
            for (final MapEntry(:key, :value) in headers.entries)
              if (!hasKey || key.toLowerCase() != 'authorization') key: value,
            if (hasKey) 'Authorization': 'Bearer $key',
          },
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw TavernModelsException('HTTP ${response.statusCode}');
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final data = switch (body) {
      {'data': final List<Object?> data} => data,
      final List<Object?> data => data,
      _ => throw const TavernModelsException('no model list'),
    };
    final ids = {
      for (final entry in data)
        if (entry case {'id': final String id} when id.isNotEmpty) id,
    }.toList()..sort();
    return ids;
  } on TimeoutException {
    throw const TavernModelsException('timeout');
  } on FormatException {
    throw const TavernModelsException('not JSON');
  } on http.ClientException catch (e) {
    throw TavernModelsException(e.message);
  } finally {
    if (own) c.close();
  }
}
