// Recognizers in the cloud for 语音输入 and 语音通话: DeepSeek's (the signed-in
// account or the API key, deepseek_speech.dart), or an OpenAI-compatible
// `/audio/transcriptions` service the person set up (speech_settings.dart).
// Both take a whole recording; nothing is recognized while still speaking.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../state/account_state.dart';
import '../state/connection_state.dart';
import '../state/settings_state.dart';
import '../state/voice_settings.dart';
import 'deepseek_speech.dart';
import 'speech_settings.dart';

abstract class VoiceCloud {
  /// The longest recording it takes, in seconds.
  int get maxSeconds;

  /// What was said in [wav] (16 kHz mono PCM16). Throws [DeepSeekSpeechError]
  /// (also for the other service: same kinds of failure).
  Future<String> transcribe(Uint8List wav);
}

/// DeepSeek's recognizer. Each recording asks who pays afresh and closes what
/// it opened, so a call can use it turn after turn.
class DeepSeekVoiceCloud implements VoiceCloud {
  DeepSeekVoiceCloud(this._resolve, {DeepSeekSpeechFailure Function()? gap}) : _gap = gap ?? _noCredential;
  final DeepSeekSpeechResolver _resolve;

  /// What to say when nobody can pay ([deepSeekSpeechGapProvider]).
  final DeepSeekSpeechFailure Function() _gap;

  static DeepSeekSpeechFailure _noCredential() => DeepSeekSpeechFailure.noCredential;

  @override
  int get maxSeconds => deepSeekAsrMaxSeconds;

  @override
  Future<String> transcribe(Uint8List wav) async {
    final speech = await _resolve();
    if (speech == null) throw DeepSeekSpeechError(_gap());
    try {
      return await speech.transcribe(wav);
    } finally {
      speech.close();
    }
  }
}

/// A key may only travel encrypted, or to this device itself (a local server).
bool cloudBaseSafe(String base) {
  final uri = Uri.tryParse(base.trim());
  if (uri == null || !uri.hasScheme) return false;
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  final host = uri.host.toLowerCase();
  return host == 'localhost' || host == '127.0.0.1' || host == '::1' || host == '[::1]';
}

/// An OpenAI-compatible `/audio/transcriptions`.
class OpenAiVoiceCloud implements VoiceCloud {
  OpenAiVoiceCloud(this.settings, this._client);
  final CloudAsrSettings settings;
  final http.Client Function() _client;

  @override
  int get maxSeconds => 300;

  @override
  Future<String> transcribe(Uint8List wav) async {
    final base = settings.base.trim().replaceAll(RegExp(r'/+$'), '');
    final request = http.MultipartRequest('POST', Uri.parse('$base/audio/transcriptions'))
      ..fields['model'] = settings.model.trim()
      ..fields['response_format'] = 'json'
      ..files.add(http.MultipartFile.fromBytes('file', wav, filename: 'speech.wav'));
    if (settings.key.trim().isNotEmpty) {
      // Never a key in the clear over the network.
      if (!cloudBaseSafe(base)) throw const DeepSeekSpeechError(DeepSeekSpeechFailure.insecure);
      request.headers['authorization'] = 'Bearer ${settings.key.trim()}';
    }
    final client = _client();
    final http.Response response;
    try {
      // One deadline for the headers and the body together.
      response = await () async {
        return http.Response.fromStream(await client.send(request));
      }().timeout(const Duration(seconds: 90));
    } on TimeoutException {
      throw const DeepSeekSpeechError(DeepSeekSpeechFailure.busy, 'timeout');
    } on Object catch (error) {
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.network, error.toString().split('\n').first);
    } finally {
      client.close();
    }
    final note = utf8.decode(response.bodyBytes.take(200).toList(), allowMalformed: true).replaceAll('\n', ' ');
    if (response.statusCode != 200) {
      throw DeepSeekSpeechError(switch (response.statusCode) {
        401 || 403 => DeepSeekSpeechFailure.unauthorized,
        402 => DeepSeekSpeechFailure.insufficientBalance,
        413 => DeepSeekSpeechFailure.tooLarge,
        429 => DeepSeekSpeechFailure.rateLimited,
        >= 500 => DeepSeekSpeechFailure.busy,
        _ => DeepSeekSpeechFailure.rejected,
      }, note);
    }
    try {
      final json = jsonDecode(utf8.decode(response.bodyBytes));
      if (json is Map && json['text'] is String) return (json['text'] as String).trim();
    } on FormatException {
      // Some servers answer text/plain.
      return utf8.decode(response.bodyBytes).trim();
    }
    throw DeepSeekSpeechError(DeepSeekSpeechFailure.protocol, note);
  }
}

/// The cloud recognizer for [mode]: DeepSeek's for deepseek (and for auto,
/// when someone can pay for it), the person's own service for cloud; null
/// when there is none (auto then uses the phone's or the engine's).
typedef VoiceCloudResolver = Future<VoiceCloud?> Function(VoiceMode mode);

final voiceCloudProvider = Provider<VoiceCloudResolver>((ref) {
  return (mode) async {
    switch (mode) {
      case VoiceMode.deepseek || VoiceMode.auto:
        final resolve = ref.read(deepSeekSpeechProvider);
        final speech = await resolve();
        if (speech == null) return null;
        speech.close();
        return DeepSeekVoiceCloud(resolve, gap: ref.read(deepSeekSpeechGapProvider));
      case VoiceMode.cloud:
        final settings = await ref.read(cloudAsrProvider.notifier).ready();
        return settings.configured ? OpenAiVoiceCloud(settings, ref.read(deepSeekSpeechHttpProvider)) : null;
      case VoiceMode.system || VoiceMode.engine || VoiceMode.offline:
        return null;
    }
  };
});

/// Whether [mode] probably has a cloud recognizer, without asking anyone: the
/// composer's microphone shows on phones with no other way to listen.
/// (Starting still asks; a wrong guess ends in a notice, not a silent failure.)
final voiceCloudLikelyProvider = Provider<bool Function()>(
  (ref) =>
      () => switch (ref.read(voiceSettingsProvider)) {
        VoiceMode.deepseek => true,
        VoiceMode.cloud => ref.read(cloudAsrProvider).configured,
        VoiceMode.auto =>
          ref.read(settingsProvider).apiKey.trim().isNotEmpty ||
              ref.read(accountProvider).phase == AccountPhase.signedIn,
        VoiceMode.system || VoiceMode.engine || VoiceMode.offline => false,
      },
);

/// The engine's own recognizer (the on-device voice model), for a call when
/// no cloud one can be had.
class EngineVoiceCloud implements VoiceCloud {
  EngineVoiceCloud(this._client, this._catalog);
  final DshClient _client;
  final SpeechCatalog _catalog;

  @override
  int get maxSeconds => _catalog.maxSeconds;

  @override
  Future<String> transcribe(Uint8List wav) async {
    try {
      final transcript = await _client.transcribe(wav, providerId: _catalog.providerId, language: _catalog.language);
      return transcript.text;
    } on Object catch (error) {
      throw DeepSeekSpeechError(DeepSeekSpeechFailure.busy, error.toString().split('\n').first);
    }
  }
}

/// The recognizer a 语音通话 uses: it needs one that takes a recording (the
/// phone's own service can't). The chosen mode's first, then DeepSeek's, then
/// the engine's voice model.
final callRecognizerProvider = Provider<Future<VoiceCloud?> Function()>((ref) {
  return () async {
    final mode = await ref.read(voiceSettingsProvider.notifier).ready();
    final cloud = ref.read(voiceCloudProvider);
    Future<VoiceCloud?> engine() async {
      final client = ref.read(activeConnectionProvider).value?.client;
      if (client == null) return null;
      try {
        final catalog = await client.speechCatalog().timeout(const Duration(seconds: 4));
        if (catalog?.selected?.usable ?? false) return EngineVoiceCloud(client, catalog!);
      } catch (_) {
        // No voice model on this engine.
      }
      return null;
    }

    return switch (mode) {
      VoiceMode.engine => await engine() ?? await cloud(VoiceMode.deepseek),
      VoiceMode.cloud => await cloud(VoiceMode.cloud) ?? await cloud(VoiceMode.deepseek) ?? await engine(),
      VoiceMode.auto || VoiceMode.deepseek || VoiceMode.system => await cloud(VoiceMode.deepseek) ?? await engine(),
      // 内置模型在本机转写，不走云端也不走引擎。
      VoiceMode.offline => await engine(),
    };
  };
});
