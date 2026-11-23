import 'dart:async';

import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/chat/voice/voice_controller.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart';

class _Carrier extends DshCarrier {
  _Carrier({this.catalog, this.transcribe});
  FutureOr<Object?> Function()? catalog;
  FutureOr<Object?> Function()? transcribe;
  final calls = <String>[];
  @override
  String get kind => 'p15-controlled';
  @override
  DshTracer? get tracer => null;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add(endpoint);
    return RpcOk(await switch (endpoint) {
      'speech/catalog' => catalog?.call() ?? readySpeechCatalog(),
      'speech/transcribe' => transcribe?.call() ?? {'text': 'new transcript', 'audioSeconds': 1.0},
      _ => throw DshHttpException(404, 'unsupported endpoint'),
    });
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) => Future.error(const DshTransportException('unused'));
  @override
  Future<void> close() async {}
}

class _Bridge extends FakeVoiceBridge {
  Completer<void>? cancelGate;
  Completer<Uint8List?>? stopGate;
  PlatformException? recognizerError;
  PlatformException? recorderError;
  PlatformException? stopError;
  @override
  Future<void> cancel() async {
    await super.cancel();
    await cancelGate?.future;
  }

  @override
  Future<Uint8List?> stop() async {
    final value = await super.stop();
    if (stopError case final error?) throw error;
    return stopGate == null ? value : await stopGate!.future;
  }

  @override
  Future<void> startRecognizer({String? language}) async {
    await super.startRecognizer(language: language);
    if (recognizerError case final error?) throw error;
  }

  @override
  Future<void> startRecorder({required int maxSeconds}) async {
    await super.startRecorder(maxSeconds: maxSeconds);
    if (recorderError case final error?) throw error;
  }
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
}

class _Rig {
  _Rig({
    VoiceMode mode = VoiceMode.auto,
    _Carrier? carrier,
    Future<VoiceMode> Function()? choose,
    VoidCallback? onRecognized,
  }) : wire = carrier ?? _Carrier() {
    host = DshClient.withCarrier(wire);
    voice = VoiceInputController(
      input: input,
      bridge: bridge,
      client: () => host,
      mode: choose ?? () async => mode,
      onRecognized: onRecognized,
      observeLifecycle: false,
    );
    voice.onMessage = (message) => messages.add(message.text);
    addTearDown(() {
      voice.dispose();
      input.dispose();
    });
  }
  final _Carrier wire;
  final bridge = _Bridge()..recording = silentWav(1);
  final input = TextEditingController();
  final messages = <String>[];
  late DshClient? host;
  late VoiceInputController voice;
}

void main() {
  test('all fifteen public speech errors have precise distinct messages; vendor code remains visible', () {
    final messages = [for (var code = 1; code <= 15; code++) voiceErrorText(code)];
    expect(messages.toSet(), hasLength(15));
    expect(messages, isNot(contains('语音识别出错了')));
    expect(voiceErrorText(777), contains('777'));
    expect(voiceErrorText(13), contains('下载'));
    expect(voiceErrorText(9), contains('权限'));
  });

  for (final code in [1, 2, 3, 4, 8, 10, 12, 13, 14, 15, 777]) {
    testWidgets('automatic service failure $code retries once with the engine', (tester) async {
      final rig = _Rig();
      await rig.voice.start();
      rig.bridge.emit(VoiceError(code));
      rig.bridge.emit(const VoiceEnd());
      await _flush(tester);
      expect(rig.voice.engine, VoiceEngine.engine);
      expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), hasLength(1));
      rig.bridge.emit(const VoiceError(100));
      await _flush(tester);
      expect(rig.voice.phase, VoicePhase.idle);
      expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), hasLength(1));
    });
  }

  testWidgets('a permission error from the service itself retries with the engine (the app holds the permission)', (
    tester,
  ) async {
    final rig = _Rig();
    await rig.voice.start();
    rig.bridge.emit(const VoiceError(9));
    await _flush(tester);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), hasLength(1));
    expect(rig.voice.engine, VoiceEngine.engine);
    await rig.voice.cancel();
  });

  for (final code in [6, 7]) {
    testWidgets('user-related error $code does not retry or erase a selection', (tester) async {
      final rig = _Rig();
      rig.input.value = const TextEditingValue(
        text: 'keep this',
        selection: TextSelection(baseOffset: 0, extentOffset: 4),
      );
      final before = rig.input.value;
      await rig.voice.start();
      rig.bridge.emit(VoiceError(code));
      await _flush(tester);
      expect(rig.voice.phase, VoicePhase.idle);
      expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), isEmpty);
      expect(rig.wire.calls, isEmpty);
      expect(rig.input.value, before);
    });
  }

  testWidgets('explicit system choice overrides remembered failure and never auto switches', (tester) async {
    final rig = _Rig(mode: VoiceMode.system);
    rig.bridge.caps = const VoiceCapabilities(recognizer: true, recorder: true, systemUnreliable: true);
    await rig.voice.start();
    expect(rig.voice.engine, VoiceEngine.system);
    rig.bridge.emit(const VoiceError(5));
    await _flush(tester);
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.wire.calls, isEmpty);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), isEmpty);
  });

  testWidgets('explicit engine choice never opens the system recognizer', (tester) async {
    final rig = _Rig(mode: VoiceMode.engine);
    await rig.voice.start();
    expect(rig.voice.engine, VoiceEngine.engine);
    expect(rig.bridge.calls, isNot(contains('recognizer')));
    await rig.voice.cancel();
  });

  testWidgets('automatic next attempt uses persisted environment health; reset health reevaluates', (tester) async {
    final rig = _Rig();
    rig.bridge.caps = const VoiceCapabilities(
      recognizer: true,
      recorder: true,
      systemUnreliable: true,
      environmentId: 'old',
    );
    await rig.voice.start();
    expect(rig.voice.engine, VoiceEngine.engine);
    await rig.voice.cancel();
    rig.bridge.caps = const VoiceCapabilities(recognizer: true, recorder: true, environmentId: 'upgraded');
    await rig.voice.start();
    expect(rig.voice.engine, VoiceEngine.system);
    await rig.voice.cancel();
  });

  testWidgets('no engine fallback provides both configuration routes and preserves draft', (tester) async {
    final rig = _Rig(carrier: _Carrier(catalog: () => throw const DshTransportException('unavailable')));
    rig.input.text = 'keep';
    await rig.voice.start();
    rig.bridge.emit(const VoicePartial('temporary'));
    await tester.pump();
    rig.bridge.emit(const VoiceError(5));
    await _flush(tester);
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.input.text, 'keep');
    expect(rig.messages.last, contains('系统识别'));
    expect(rig.messages.last, contains('语音模型'));
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), isEmpty);
  });

  testWidgets('recognizer startup exception takes the same one-time fallback', (tester) async {
    final rig = _Rig();
    rig.bridge.recognizerError = PlatformException(code: 'recognizer', details: {'code': 5});
    await rig.voice.start();
    await _flush(tester);
    expect(rig.voice.engine, VoiceEngine.engine);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), hasLength(1));
    await rig.voice.cancel();
  });

  testWidgets('recorder startup failure does not loop or leave recording active', (tester) async {
    final rig = _Rig();
    rig.bridge.recorderError = PlatformException(code: 'audio', details: {'code': 100});
    await rig.voice.start();
    rig.bridge.emit(const VoiceError(5));
    await _flush(tester);
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), hasLength(1));
    expect(rig.messages.last, '没能打开麦克风');
  });

  testWidgets('user cancellation ignores the recognizer error emitted afterwards', (tester) async {
    var recognized = 0;
    final rig = _Rig(onRecognized: () => recognized++);
    await rig.voice.start();
    await rig.voice.cancel();
    rig.bridge.emit(const VoiceError(5));
    rig.bridge.emit(const VoiceEnd());
    await _flush(tester);
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.wire.calls, isEmpty);
    expect(rig.messages, isEmpty);

    rig.input.value = const TextEditingValue(text: '旧草稿', selection: TextSelection.collapsed(offset: 3));
    await rig.voice.start();
    rig.bridge.emit(const VoicePartial('旧识别'));
    await _flush(tester);
    expect(rig.input.text, '旧草稿旧识别');
    const edited = TextEditingValue(
      text: '我改成键盘输入。',
      selection: TextSelection(baseOffset: 1, extentOffset: 3),
      composing: TextRange(start: 0, end: 1),
    );
    rig.input.value = edited;
    await rig.voice.cancel();
    expect(rig.input.value, edited);
    rig.bridge.emit(const VoiceFinal('迟到的识别'));
    rig.bridge.emit(const VoiceError(5));
    rig.bridge.emit(const VoiceEnd());
    await _flush(tester);
    expect(rig.input.value, edited);
    expect(recognized, 0, reason: 'a later draft is not a recognized result to submit');
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.wire.calls, isEmpty);
    expect(rig.messages, isEmpty);
  });

  testWidgets('a canceled fallback catalog cannot start recording over a new system attempt', (tester) async {
    final catalog = Completer<Object?>();
    final rig = _Rig(carrier: _Carrier(catalog: () => catalog.future));
    await rig.voice.start();
    rig.bridge.emit(const VoiceError(5));
    await _flush(tester);
    expect(rig.voice.phase, VoicePhase.starting);
    await rig.voice.cancel();
    await rig.voice.start();
    catalog.complete(readySpeechCatalog());
    await _flush(tester);
    expect(rig.voice.engine, VoiceEngine.system);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), isEmpty);
    await rig.voice.cancel();
  });

  testWidgets('host change during fallback never sends audio to the replacement host', (tester) async {
    final catalog = Completer<Object?>();
    final rig = _Rig(carrier: _Carrier(catalog: () => catalog.future));
    final replacement = _Carrier();
    await rig.voice.start();
    rig.bridge.emit(const VoiceError(5));
    await _flush(tester);
    rig.host = DshClient.withCarrier(replacement);
    catalog.complete(readySpeechCatalog());
    await _flush(tester);
    expect(rig.voice.phase, VoicePhase.idle);
    expect(replacement.calls, isEmpty);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), isEmpty);
  });

  testWidgets('backgrounding during fallback cleanup prevents recorder restart', (tester) async {
    final rig = _Rig();
    await rig.voice.start();
    final cleanup = Completer<void>();
    rig.bridge.cancelGate = cleanup;
    rig.bridge.emit(const VoiceError(5));
    await _flush(tester);
    rig.voice.didChangeAppLifecycleState(AppLifecycleState.paused);
    cleanup.complete();
    await _flush(tester);
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), isEmpty);
    expect(rig.wire.calls, isEmpty);
  });

  testWidgets('a new capture waits for the prior cancellation acknowledgement', (tester) async {
    final rig = _Rig(mode: VoiceMode.engine);
    await rig.voice.start();
    final cleanup = Completer<void>();
    rig.bridge.cancelGate = cleanup;
    addTearDown(() {
      if (!cleanup.isCompleted) cleanup.complete();
    });
    final release = rig.voice.cancel();
    expect(rig.voice.cancel(), same(release));
    final next = rig.voice.start();
    await _flush(tester);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), hasLength(1));
    cleanup.complete();
    await release;
    await next;
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), hasLength(2));
  });

  testWidgets('late mode load from a canceled attempt cannot change new explicit system routing', (tester) async {
    final oldMode = Completer<VoiceMode>();
    var choices = 0;
    final rig = _Rig(choose: () => ++choices == 1 ? oldMode.future : Future.value(VoiceMode.system));
    final oldStart = rig.voice.start();
    await _flush(tester);
    await rig.voice.cancel();
    await rig.voice.start();
    oldMode.complete(VoiceMode.auto);
    await oldStart;
    rig.bridge.emit(const VoiceError(5));
    await _flush(tester);
    expect(rig.bridge.calls.where((s) => s.startsWith('recorder:')), isEmpty);
    expect(rig.voice.phase, VoicePhase.idle);
  });

  testWidgets('late old WAV cannot transcribe or end a new recording', (tester) async {
    final rig = _Rig(mode: VoiceMode.engine);
    await rig.voice.start();
    final oldWav = Completer<Uint8List?>();
    rig.bridge.stopGate = oldWav;
    final oldStop = rig.voice.stop();
    await _flush(tester);
    await rig.voice.cancel();
    rig.bridge.stopGate = null;
    await rig.voice.start();
    oldWav.complete(silentWav(1));
    await oldStop;
    expect(rig.voice.phase, VoicePhase.listening);
    expect(rig.wire.calls.where((e) => e == 'speech/transcribe'), isEmpty);
    await rig.voice.cancel();
  });

  testWidgets('late old transcript cannot replace a new in-flight transcript', (tester) async {
    final transcripts = <Completer<Object?>>[];
    var recognized = 0;
    final rig = _Rig(
      mode: VoiceMode.engine,
      onRecognized: () => recognized++,
      carrier: _Carrier(
        transcribe: () {
          final pending = Completer<Object?>();
          transcripts.add(pending);
          return pending.future;
        },
      ),
    );
    await rig.voice.start();
    final first = rig.voice.stop();
    await _flush(tester);
    await rig.voice.cancel();
    await rig.voice.start();
    final second = rig.voice.stop();
    await _flush(tester);
    expect(transcripts, hasLength(2));
    transcripts.first.complete({'text': 'old wrong host text', 'audioSeconds': 1.0});
    await first;
    expect(rig.voice.phase, VoicePhase.transcribing);
    expect(rig.input.text, isEmpty);
    // Only moving the caret/composing range still accepts this dictation.
    rig.input.value = const TextEditingValue(
      selection: TextSelection.collapsed(offset: 0),
      composing: TextRange.collapsed(0),
    );
    transcripts.last.complete({'text': 'new correct text', 'audioSeconds': 1.0});
    await second;
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.input.text, 'new correct text');
    expect(recognized, 1);

    await rig.voice.start();
    final editedStop = rig.voice.stop();
    await _flush(tester);
    expect(transcripts, hasLength(3));
    expect(rig.voice.phase, VoicePhase.transcribing);
    const edited = TextEditingValue(
      text: '这是后来键入的新草稿。',
      selection: TextSelection(baseOffset: 2, extentOffset: 5),
      composing: TextRange(start: 2, end: 5),
    );
    rig.input.value = edited;
    transcripts.last.complete({'text': 'late voice must not replace the draft', 'audioSeconds': 1.0});
    await editedStop;
    expect(rig.input.value, edited);
    expect(rig.voice.phase, VoicePhase.idle);
    expect(recognized, 1, reason: 'preserving the edited draft must not auto-submit it');
    expect(rig.wire.calls.where((e) => e == 'speech/transcribe'), hasLength(3));
  });

  testWidgets('host switch while WAV is pending never redirects audio', (tester) async {
    final rig = _Rig(mode: VoiceMode.engine);
    await rig.voice.start();
    final wav = Completer<Uint8List?>();
    rig.bridge.stopGate = wav;
    final stopped = rig.voice.stop();
    await _flush(tester);
    final replacement = _Carrier();
    rig.host = DshClient.withCarrier(replacement);
    wav.complete(silentWav(1));
    await stopped;
    expect(rig.voice.phase, VoicePhase.idle);
    expect(replacement.calls, isEmpty);
    expect(rig.wire.calls.where((e) => e == 'speech/transcribe'), isEmpty);
  });
  testWidgets('failed settings load does not silently choose another audio route', (tester) async {
    final rig = _Rig(choose: () => Future.error(StateError('settings unavailable')));
    await rig.voice.start();
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.bridge.calls, ['permission']);
    expect(rig.messages.last, contains('语音设置'));
  });

  testWidgets('recording stop exception has an audio message and sends no waveform', (tester) async {
    final rig = _Rig(mode: VoiceMode.engine);
    await rig.voice.start();
    rig.bridge.stopError = PlatformException(code: 'audio', details: {'code': 100});
    await rig.voice.stop();
    expect(rig.voice.phase, VoicePhase.idle);
    expect(rig.messages.last, '没能打开麦克风');
    expect(rig.wire.calls.where((e) => e == 'speech/transcribe'), isEmpty);
  });

  for (final event in [const VoiceFinal(''), const VoiceEnd()]) {
    testWidgets('empty system ${event.runtimeType} preserves an existing selection', (tester) async {
      final rig = _Rig();
      rig.input.value = const TextEditingValue(
        text: 'keep this',
        selection: TextSelection(baseOffset: 0, extentOffset: 4),
      );
      final before = rig.input.value;
      await rig.voice.start();
      rig.bridge.emit(event);
      await _flush(tester);
      expect(rig.input.value, before);
      expect(rig.voice.phase, VoicePhase.idle);
      expect(rig.messages.last, '没有听清，再说一次');
    });
  }
}
