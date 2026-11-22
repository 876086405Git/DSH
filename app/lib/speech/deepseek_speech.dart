// DeepSeek's speech API (api-docs.deepseek.com/zh-cn/guides/tts, …/asr):
// text to 24 kHz PCM16 mono, and a recording (WAV, ≤120 s, ≤8 MiB) to text.
//
// Who pays decides the way there. The signed-in DeepSeek account's token never
// leaves the engine, so those requests go through the bridge
// (`/dsh-go/v1/speech`, runtime/bridge/dsh-go-bridge/lib/speech.js), which
// sends them with it. Without an account, the API key in 设置 goes straight to
// api.deepseek.com from the phone. Account first: it is what 默认免配置 means.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data' show BytesBuilder;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../state/account_state.dart';
import '../state/connection_state.dart';
import '../state/settings_state.dart';

part 'ohos_deepseek_speech.dart';

/// PCM from DeepSeek's TTS: 24 kHz, 16-bit little-endian, mono.
const deepSeekTtsRate = 24000;

/// The voices DeepSeek offers (海星 female, the default; 暗潮 male).
const deepSeekVoices = ['stella', 'tide'];

/// The longest recording the recognizer takes, less a margin.
const deepSeekAsrMaxSeconds = 118;
const deepSeekAsrMaxBytes = 8 * 1024 * 1024;

const _api = 'https://api.deepseek.com';
const _bridge = '/dsh-go/v1/speech';

enum DeepSeekSpeechFailure {
  /// No account and no key: nothing to pay with.
  noCredential,

  /// Signed in, but the account cannot pay for speech here: the DSH connected
  /// to predates speech (its bridge has no speech route), or it is reached
  /// through DSH Remote.
  accountUnusable,

  /// The account was signed out or its sign-in expired.
  signIn,

  /// The API key was refused.
  unauthorized,
  insufficientBalance,
  rateLimited,

  /// Nothing readable, refused by moderation, or audio it can't read.
  rejected,
  tooLarge,
  busy,
  network,

  /// An answer that isn't what the API promises.
  protocol,

  /// A key would have gone over the network unencrypted (an http address).
  insecure,
}

class DeepSeekSpeechError implements Exception {
  const DeepSeekSpeechError(this.failure, [this.detail = '']);

  final DeepSeekSpeechFailure failure;

  /// The service's own words, for the settings page; never a credential.
  final String detail;

  @override
  String toString() => 'DeepSeekSpeechError(${failure.name}${detail.isEmpty ? '' : ': $detail'})';
}

/// How a request is paid for: the account through the engine, or a key.
enum DeepSeekSpeechRoute { account, apiKey, hostKey }

abstract class DeepSeekSpeech {
  DeepSeekSpeechRoute get route;

  /// [text] read aloud in [voice]: PCM as it is synthesized. A stream that
  /// ends early (the service failed midway) throws [DeepSeekSpeechError].
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'});

  /// What was said in [wav].
  Future<String> transcribe(Uint8List wav);

  /// Stops what is under way; the streams end with nothing more.
  void close();
}

DeepSeekSpeechFailure _failureOf(int status, {required bool account}) => switch (status) {
  401 => account ? DeepSeekSpeechFailure.signIn : DeepSeekSpeechFailure.unauthorized,
  402 => DeepSeekSpeechFailure.insufficientBalance,
  400 || 415 => DeepSeekSpeechFailure.rejected,
  413 => DeepSeekSpeechFailure.tooLarge,
  429 => DeepSeekSpeechFailure.rateLimited,
  502 => DeepSeekSpeechFailure.network,
  >= 500 => DeepSeekSpeechFailure.busy,
  _ => DeepSeekSpeechFailure.protocol,
};

/// The bridge's own code first (`speech/no-credential` is a 401 too), then the status.
DeepSeekSpeechFailure _bridgeFailure(int status, List<int> body, {required bool account}) {
  try {
    final json = jsonDecode(utf8.decode(body, allowMalformed: true));
    final code = json is Map && json['error'] is Map ? (json['error'] as Map)['code'] : null;
    switch (code) {
      case 'speech/no-credential':
        return DeepSeekSpeechFailure.noCredential;
      case 'speech/sign-in-required':
        return DeepSeekSpeechFailure.signIn;
      case 'speech/unauthorized':
        return DeepSeekSpeechFailure.unauthorized;
      case 'speech/upstream-unreachable':
        return DeepSeekSpeechFailure.network;
    }
  } on FormatException {
    // Not the bridge's JSON (an older engine's 404 page): by status.
  }
  return _failureOf(status, account: account);
}

/// The message in an error body (`{"error":{"message"}}` or plain text), short.
String _detail(List<int> body) {
  final text = utf8.decode(body.take(400).toList(), allowMalformed: true).trim();
  try {
    final json = jsonDecode(text);
    if (json is Map && json['error'] is Map) {
      final error = json['error'] as Map;
      if (error['code'] == 'speech/no-credential') return 'no-credential';
      if (error['message'] is String) return error['message'] as String;
    }
  } on FormatException {
    // Plain text.
  }
  return text.replaceAll('\n', ' ');
}

String _textOf(List<int> body) {
  Object? json;
  try {
    json = jsonDecode(utf8.decode(body));
  } on FormatException {
    throw const DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'not JSON');
  }
  if (json is Map && json['text'] is String) return (json['text'] as String).trim();
  throw const DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, 'no text');
}

String _ttsBody(String text, String voice) => jsonEncode({
  'text': text,
  'voice_id': deepSeekVoices.contains(voice) ? voice : deepSeekVoices.first,
  'format': 'pcm',
  'filter_markdown': true,
});

/// Straight to api.deepseek.com with the key from 设置. TTS audio streams in
/// as it is made.
class DirectDeepSeekSpeech implements DeepSeekSpeech {
  DirectDeepSeekSpeech(this._key, {http.Client Function()? client, this.base = _api})
    : _client = (client ?? http.Client.new)();

  final String _key;
  final http.Client _client;
  final String base;
  bool _closed = false;

  @override
  DeepSeekSpeechRoute get route => DeepSeekSpeechRoute.apiKey;

  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    final request = http.Request('POST', Uri.parse('$base/v1/tools/tts'))
      ..headers['authorization'] = 'Bearer $_key'
      ..headers['content-type'] = 'application/json'
      ..body = _ttsBody(text, voice);
    final http.StreamedResponse response;
    try {
      response = await _client.send(request).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const DeepSeekSpeechError(DeepSeekSpeechFailure.busy, 'timeout');
    } on Object catch (error) {
      if (_closed) return;
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.network, error.toString().split('\n').first);
    }
    if (response.statusCode != 200) {
      final body = await response.stream.toBytes().catchError((Object _) => Uint8List(0));
      throw DeepSeekSpeechError(_failureOf(response.statusCode, account: false), _detail(body));
    }
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
        if (_closed) return;
        yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      }
    } on TimeoutException {
      throw const DeepSeekSpeechError(DeepSeekSpeechFailure.busy, 'stalled');
    } on Object catch (error) {
      if (_closed) return;
      // Cut off midway: the docs say to treat it as failed.
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.busy, error.toString().split('\n').first);
    }
  }

  @override
  Future<String> transcribe(Uint8List wav) async {
    if (wav.length > deepSeekAsrMaxBytes) throw const DeepSeekSpeechError(DeepSeekSpeechFailure.tooLarge);
    final request = http.MultipartRequest('POST', Uri.parse('$base/v1/tools/asr'))
      ..headers['authorization'] = 'Bearer $_key'
      ..files.add(http.MultipartFile.fromBytes('file', wav, filename: 'speech.wav'));
    final http.Response response;
    try {
      response = await http.Response.fromStream(await _client.send(request).timeout(const Duration(seconds: 60)))
          .timeout(const Duration(seconds: 60));
    } on TimeoutException {
      throw const DeepSeekSpeechError(DeepSeekSpeechFailure.busy, 'timeout');
    } on Object catch (error) {
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.network, error.toString().split('\n').first);
    }
    if (response.statusCode != 200) {
      throw DeepSeekSpeechError(_failureOf(response.statusCode, account: false), _detail(response.bodyBytes));
    }
    return _textOf(response.bodyBytes);
  }

  @override
  void close() {
    _closed = true;
    _client.close();
  }
}

/// Through the engine's bridge, which pays with the signed-in account (or the
/// host's own key). Each TTS request comes back whole, so callers keep them
/// short (a sentence or two) and ask for the next while one plays.
class BridgeDeepSeekSpeech implements DeepSeekSpeech {
  BridgeDeepSeekSpeech(this._connection, this.route);

  final DshConnection _connection;
  @override
  final DeepSeekSpeechRoute route;
  bool _closed = false;

  bool get _account => route == DeepSeekSpeechRoute.account;

  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    final DshHttpResponse response;
    try {
      response = await _connection.postJson('$_bridge/tts', {
        'text': text,
        'voice': deepSeekVoices.contains(voice) ? voice : deepSeekVoices.first,
      }, timeout: const Duration(seconds: 60));
    } on DshTransportException catch (error) {
      if (_closed) return;
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.network, error.message);
    }
    if (_closed) return;
    if (response.statusCode != 200) {
      throw DeepSeekSpeechError(
        _bridgeFailure(response.statusCode, response.body, account: _account),
        _detail(response.body),
      );
    }
    if (response.body.isNotEmpty) yield Uint8List.fromList(response.body);
  }

  @override
  Future<String> transcribe(Uint8List wav) async {
    if (wav.length > deepSeekAsrMaxBytes) throw const DeepSeekSpeechError(DeepSeekSpeechFailure.tooLarge);
    final DshHttpResponse response;
    try {
      response = await _connection.postBytes(
        '$_bridge/asr',
        wav,
        contentType: 'audio/wav',
        timeout: const Duration(seconds: 90),
        maxResponseBytes: 256 * 1024,
      );
    } on DshTransportException catch (error) {
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.network, error.message);
    }
    if (response.statusCode != 200) {
      throw DeepSeekSpeechError(
        _bridgeFailure(response.statusCode, response.body, account: _account),
        _detail(response.body),
      );
    }
    return _textOf(response.body);
  }

  @override
  void close() => _closed = true;
}

/// What the bridge says it can pay with, read once per engine connection
/// (a sign-in or sign-out reads it again: [invalidateDeepSeekSpeech]).
class _BridgeProbe {
  _BridgeProbe(this.client, this.route, this.at);
  final DshClient client;
  final DeepSeekSpeechRoute? route;
  final DateTime at;
}

_BridgeProbe? _probe;

/// Forget what the bridge said (after signing in or out).
void invalidateDeepSeekSpeech() => _probe = null;

Future<DeepSeekSpeechRoute?> _bridgeRoute(DshClient client) async {
  final cached = _probe;
  if (cached != null &&
      identical(cached.client, client) &&
      DateTime.now().difference(cached.at) < const Duration(minutes: 2)) {
    return cached.route;
  }
  final carrier = client.carrier;
  DeepSeekSpeechRoute? route;
  if (carrier is DshHttpCarrier) {
    try {
      final response = await carrier.connection.getBounded(
        _bridge,
        maxBytes: 4096,
        timeout: const Duration(seconds: 4),
      );
      if (response.statusCode == 200) {
        final json = jsonDecode(utf8.decode(response.body));
        route = switch (json is Map ? json['credential'] : null) {
          'account' => DeepSeekSpeechRoute.account,
          'api-key' => DeepSeekSpeechRoute.hostKey,
          _ => null,
        };
      }
    } on Object {
      // An engine without the speech routes (older bridge), or not reachable now.
    }
  }
  _probe = _BridgeProbe(client, route, DateTime.now());
  return route;
}

/// Who pays for speech now, or null when nobody can: the signed-in account
/// (through the engine), else the API key in 设置, else the host's own key.
typedef DeepSeekSpeechResolver = Future<DeepSeekSpeech?> Function();

/// The account was turned away by the speech endpoints (signed out, or they
/// take only a platform API key): from then on, while the app runs, speech
/// goes straight to the API key in 设置.
bool _accountRefused = false;

@visibleForTesting
void resetDeepSeekAccountRefusal() => _accountRefused = false;

/// The signed-in account first; if it is turned away (401) before any audio
/// came, the API key in 设置 for this request and every later one.
class AccountThenKeySpeech implements DeepSeekSpeech {
  AccountThenKeySpeech(this._account, this._key);

  final DeepSeekSpeech _account;
  final DeepSeekSpeech Function() _key;
  DeepSeekSpeech? _fallback;
  bool _closed = false;

  @override
  DeepSeekSpeechRoute get route => (_fallback ?? _account).route;

  static bool _refused(DeepSeekSpeechError error) => error.failure == DeepSeekSpeechFailure.signIn;

  /// The key from now on. The account is left open: other requests already on
  /// it finish (or are refused and come here too).
  DeepSeekSpeech? _toKey() {
    _accountRefused = true;
    if (_closed) return null;
    return _fallback ??= _key();
  }

  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    if (_fallback case final key?) {
      yield* key.synthesize(text, voice: voice);
      return;
    }
    var heard = false;
    try {
      await for (final pcm in _account.synthesize(text, voice: voice)) {
        heard = true;
        yield pcm;
      }
    } on DeepSeekSpeechError catch (error) {
      final key = heard || !_refused(error) ? null : _toKey();
      if (key == null) rethrow;
      yield* key.synthesize(text, voice: voice);
    }
  }

  @override
  Future<String> transcribe(Uint8List wav) async {
    if (_fallback case final key?) return key.transcribe(wav);
    try {
      return await _account.transcribe(wav);
    } on DeepSeekSpeechError catch (error) {
      final key = _refused(error) ? _toKey() : null;
      if (key == null) rethrow;
      return key.transcribe(wav);
    }
  }

  @override
  void close() {
    _closed = true;
    _account.close();
    _fallback?.close();
  }
}

final deepSeekSpeechHttpProvider = Provider<http.Client Function()>((ref) => http.Client.new);

final deepSeekSpeechProvider = Provider<DeepSeekSpeechResolver>((ref) {
  return () async {
    final client = ref.read(activeConnectionProvider).value?.client;
    final bridge = client == null ? null : await _bridgeRoute(client);
    final carrier = client?.carrier;
    final key = ref.read(settingsProvider).apiKey.trim();
    DeepSeekSpeech direct() => DirectDeepSeekSpeech(key, client: ref.read(deepSeekSpeechHttpProvider));
    if (Platform.operatingSystem == 'ohos') {
      return _resolveOhosSpeech(bridge, carrier, key, ref.read(deepSeekSpeechHttpProvider));
    }
    if (bridge == DeepSeekSpeechRoute.account && carrier is DshHttpCarrier && !(_accountRefused && key.isNotEmpty)) {
      final account = BridgeDeepSeekSpeech(carrier.connection, bridge!);
      return key.isEmpty ? account : AccountThenKeySpeech(account, direct);
    }
    if (key.isNotEmpty) return direct();
    if (bridge == DeepSeekSpeechRoute.hostKey && carrier is DshHttpCarrier) {
      return BridgeDeepSeekSpeech(carrier.connection, bridge!);
    }
    return null;
  };
});

/// Why [deepSeekSpeechProvider] has nothing to offer: signed in, the account
/// cannot pay for speech here; else there is no account and no key.
final deepSeekSpeechGapProvider = Provider<DeepSeekSpeechFailure Function()>(
  (ref) =>
      () => ref.read(accountProvider).signedIn
      ? DeepSeekSpeechFailure.accountUnusable
      : DeepSeekSpeechFailure.noCredential,
);

/// Adds a WAV header to DeepSeek's PCM, for players and tools that want a file.
Uint8List deepSeekWav(Uint8List pcm, {int rate = deepSeekTtsRate}) {
  final length = pcm.length & ~1;
  final wav = Uint8List(44 + length);
  final header = ByteData.sublistView(wav, 0, 44);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      header.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  header.setUint32(4, 36 + length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 2, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  header.setUint32(40, length, Endian.little);
  return wav..setRange(44, 44 + length, pcm);
}
