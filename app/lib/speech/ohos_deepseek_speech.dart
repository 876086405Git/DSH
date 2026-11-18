part of 'deepseek_speech.dart';

// OH alone selects these owners. Existing Android speech classes and their
// transport methods retain their original implementation.
DeepSeekSpeech? _resolveOhosSpeech(
  DeepSeekSpeechRoute? bridge,
  DshCarrier? carrier,
  String key,
  http.Client Function() client,
) {
  DeepSeekSpeech direct() => _OhosDirectSpeech(key, client: client);
  if (bridge == DeepSeekSpeechRoute.account && carrier is DshHttpCarrier && !(_accountRefused && key.isNotEmpty)) {
    final account = _OhosBridgeSpeech(carrier.connection, bridge!);
    return key.isEmpty ? account : AccountThenKeySpeech(account, direct);
  }
  if (key.isNotEmpty) return direct();
  if (bridge == DeepSeekSpeechRoute.hostKey && carrier is DshHttpCarrier) {
    return _OhosBridgeSpeech(carrier.connection, bridge!);
  }
  return null;
}

// Failure diagnostics are bounded separately from the successful PCM stream.
Future<Uint8List> _ohosSpeechErrorBody(Stream<List<int>> body) async {
  const limit = 4096;
  final bytes = BytesBuilder(copy: false);
  final reader = StreamIterator<List<int>>(body);
  try {
    while (bytes.length < limit && await reader.moveNext().timeout(const Duration(seconds: 20))) {
      final chunk = reader.current;
      final room = limit - bytes.length;
      bytes.add(chunk.length <= room ? chunk : chunk.sublist(0, room));
    }
    return bytes.takeBytes();
  } finally {
    await reader.cancel();
  }
}

class _OhosBridgeSpeech extends BridgeDeepSeekSpeech {
  _OhosBridgeSpeech(super.connection, super.route);

  final _abort = DshHttpAbort();

  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    if (_closed) return;
    DshHttpStreamResponse? response;
    try {
      response = await _connection.postJsonStream('$_bridge/tts', {
        'text': text,
        'voice': deepSeekVoices.contains(voice) ? voice : deepSeekVoices.first,
      }, abort: _abort, headerTimeout: const Duration(seconds: 60));
      if (_closed) return;
      if (response.statusCode != 200) {
        final body = await _ohosSpeechErrorBody(response.body);
        if (_closed) return;
        throw DeepSeekSpeechError(_bridgeFailure(response.statusCode, body, account: _account), _detail(body));
      }
      await for (final chunk in response.body) {
        if (_closed) return;
        yield chunk;
      }
    } on DeepSeekSpeechError {
      rethrow;
    } on Object catch (error) {
      if (_closed) return;
      throw DeepSeekSpeechError(
        DeepSeekSpeechFailure.network,
        error is DshTransportException ? error.message : 'speech stream failed',
      );
    } finally {
      await response?.cancel();
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _abort.abort();
  }
}

class _OhosDirectSpeech extends DirectDeepSeekSpeech {
  _OhosDirectSpeech(super.key, {super.client});

  @override
  Stream<Uint8List> synthesize(String text, {String voice = 'stella'}) async* {
    if (_closed) return;
    final request = http.Request('POST', Uri.parse('$base/v1/tools/tts'))
      ..headers['authorization'] = 'Bearer $_key'
      ..headers['content-type'] = 'application/json'
      ..body = _ttsBody(text, voice);
    try {
      final response = await _client.send(request).timeout(const Duration(seconds: 20));
      if (_closed) return;
      if (response.statusCode != 200) {
        final body = await _ohosSpeechErrorBody(response.stream);
        if (_closed) return;
        throw DeepSeekSpeechError(_failureOf(response.statusCode, account: false), _detail(body));
      }
      await for (final chunk in response.stream.timeout(const Duration(seconds: 20))) {
        if (_closed) return;
        yield chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      }
    } on DeepSeekSpeechError {
      rethrow;
    } on TimeoutException {
      if (_closed) return;
      throw const DeepSeekSpeechError(DeepSeekSpeechFailure.busy, 'timeout or stalled');
    } on Object {
      if (_closed) return;
      throw const DeepSeekSpeechError(DeepSeekSpeechFailure.network, 'speech stream failed');
    }
  }
}
