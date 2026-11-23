import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_app/companion/companion_voice_source.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_settings.dart';
import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/voice_cloud.dart';
import 'package:dsh_app/state/app_notes.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/speech/call/call_backdrop.dart';
import 'package:dsh_app/ui/speech/call/call_parts.dart';
import 'package:dsh_app/ui/speech/voice_call_page.dart';
import 'package:dsh_app/state/android_features.dart' show operatingSystemProvider;
import 'package:dsh_app/ui/speech/call/call_visuals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/composer_fakes.dart';
import '../chat/support/harness.dart';
import 'speech_fakes.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// [still]: the system asks for less motion. [opened] runs on the page's first frame.
  Future<(FakeAudio, FakeConversation)> pumpCall(
    WidgetTester tester, {
    List<Override> extra = const [],
    bool still = false,
    void Function()? opened,
    String said = '这周末北京天气怎么样',
  }) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final audio = FakeAudio();
    final conversation = FakeConversation();
    await tester.pumpWidget(
      testApp(
        Navigator(
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => MediaQuery(
                        data: MediaQuery.of(context).copyWith(disableAnimations: still),
                        child: VoiceCallPage(title: '周末去哪儿玩', conversation: conversation),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
        overrides: [
          speechAudioProvider.overrideWithValue(audio),
          callRecognizerProvider.overrideWithValue(() async => FakeCloud(said)),
          voiceBridgeProvider.overrideWithValue(FakeVoiceBridge()),
          deepSeekSpeechProvider.overrideWithValue(() async => FakeDeepSeek()),
          ...extra,
        ],
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    opened?.call();
    for (var i = 0; i < 25; i++) {
      await tester.pump(const Duration(milliseconds: 60));
      // The saved voice is read with real async work before the call starts listening.
      if (i % 5 == 0) await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    }
    return (audio, conversation);
  }

  testWidgets('a turn on the page: heard, sent, the reply arriving; hang up closes it', (tester) async {
    final (audio, conversation) = await pumpCall(tester);
    expect(find.text('周末去哪儿玩'), findsOneWidget);
    expect(find.byType(CallLight), findsOneWidget, reason: 'the glass orb by default');
    expect(audio.calls, contains('callStart:bargeIn=true'));
    expect(find.text('在听'), findsOneWidget);

    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(Uint8List(32044), const Duration(seconds: 2)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('这周末北京天气怎么样'), findsOneWidget);
    expect(conversation.sent.single, endsWith('这周末北京天气怎么样'));
    // "This is a call" goes to the model as a note the chat does not show.
    expect(withoutAppNotes(conversation.sent.single), '这周末北京天气怎么样');

    conversation.reply('北京晴，最高二十度。');
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    // The caption follows her voice: nothing before it plays, all of it once played.
    expect(tester.widget<RevealText>(find.byType(RevealText)).text, isEmpty);
    // The microphone's levels alone leave the page as it was built: the light reads them itself.
    final status = tester.widget<CallStatus>(find.byType(CallStatus));
    for (final level in [0.1, 0.3, 0.6]) {
      audio.emit(MicLevel(level));
      await tester.pump(const Duration(milliseconds: 40));
    }
    expect(tester.widget<CallStatus>(find.byType(CallStatus)), same(status));
    final id = RegExp(r'^open:(\S+):call=true$').firstMatch(audio.calls.lastWhere((c) => c.startsWith('open:')))![1]!;
    audio
      ..emit(PlayEvent(id, PlayPhase.start))
      ..emit(PlayEvent(id, PlayPhase.done));
    // However long the wait for her voice, her words come in from the first letter.
    final words = find.descendant(of: find.byKey(const ValueKey('call-reply')), matching: find.byType(CaptionWindow));
    for (var i = 0; i < 20 && words.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(tester.widget<CaptionWindow>(words).span.toPlainText(), '北');
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.widget<RevealText>(find.byType(RevealText)).text, '北京晴，最高二十度。');

    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(audio.calls, contains('callStop'));
    expect(find.byType(VoiceCallPage), findsNothing);
  });

  testWidgets('a long question is shown whole, and 字幕 opens the call in full', (tester) async {
    const long = '我想问一下这个周末北京的天气怎么样，如果下雨的话有没有什么室内的地方可以带孩子去玩，最好离朝阳区近一点';
    const reply = '北京晴，最高二十度。';
    final (audio, conversation) = await pumpCall(tester, said: long);
    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(Uint8List(32044), const Duration(seconds: 5)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    // Whole, over several lines, not cut to one.
    expect(find.text(long, findRichText: true), findsOneWidget);

    conversation.reply('**$reply**', done: false);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.tap(find.byKey(const ValueKey('call-captions')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final list = find.byKey(const ValueKey('call-transcript-list'));
    expect(find.descendant(of: list, matching: find.text(long)), findsOneWidget);
    expect(find.descendant(of: list, matching: find.text(reply)), findsOneWidget);
    final beforeLevels = tester.widget<ListView>(list);
    for (final level in [0.0, 0.6, 0.0]) {
      audio.emit(MicLevel(level));
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.widget<ListView>(list), same(beforeLevels));
      expect(find.descendant(of: list, matching: find.text(reply)), findsOneWidget);
    }

    const extra = '出门记得带伞。';
    conversation.reply('**$reply**\n[$extra](https://example.test)', done: true);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(tester.widget<ListView>(list), isNot(same(beforeLevels)));
    expect(find.descendant(of: list, matching: find.text(reply)), findsNothing);
    expect(find.descendant(of: list, matching: find.text('$reply\n$extra')), findsOneWidget);
  });

  testWidgets('a call that fails with 字幕 open closes the call page, not just the sheet', (tester) async {
    final (audio, _) = await pumpCall(tester);
    await tester.tap(find.byKey(const ValueKey('call-transcript')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    audio.emit(const CallError('mic'));
    for (var i = 0; i < 70; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(VoiceCallPage), findsNothing);
  });

  testWidgets('字幕 follows new words at the bottom; scrolled up, the reader stays put', (tester) async {
    final (audio, conversation) = await pumpCall(tester);
    const reply = '这周末北京以晴为主，周六最高二十度，周日傍晚可能有小雨。带孩子的话，朝阳区可以去科技馆新馆，室内展区很大。';
    Future<void> turn() async {
      audio.emit(const SpeechStart(over: false));
      audio.emit(Utterance(Uint8List(32044), const Duration(seconds: 2)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      conversation.reply(reply, done: true);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    for (var i = 0; i < 5; i++) {
      await turn();
    }
    await tester.tap(find.byKey(const ValueKey('call-transcript')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final list = find.byKey(const ValueKey('call-transcript-list'));
    ScrollPosition position() =>
        tester.state<ScrollableState>(find.descendant(of: list, matching: find.byType(Scrollable))).position;
    expect(position().maxScrollExtent, greaterThan(0));
    expect(position().pixels, position().maxScrollExtent, reason: 'opens at the newest');

    // At the bottom: new words are followed.
    await turn();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(position().pixels, closeTo(position().maxScrollExtent, 1));

    // Scrolled up by the reader: more words do not pull them back.
    await tester.drag(list, const Offset(0, 300));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final kept = position().pixels;
    expect(kept, lessThan(position().maxScrollExtent - 100));
    await turn();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(position().pixels, closeTo(kept, 1));

    // Back at the bottom; her words arrive (the follow is scheduled for the
    // frame's end) and the reader scrolls up before that frame: they stay up.
    await tester.drag(list, const Offset(0, -3000));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(position().pixels, closeTo(position().maxScrollExtent, 1));
    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(Uint8List(32044), const Duration(seconds: 2)));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    conversation.reply(reply, done: true);
    await tester.drag(list, const Offset(0, 300));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(position().pixels, lessThan(position().maxScrollExtent - 100));
  });

  testWidgets('字幕 before anything is said: the page says so', (tester) async {
    await pumpCall(tester);
    await tester.tap(find.byKey(const ValueKey('call-transcript')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('还没开口。你们说的话会一句句记在这里。'), findsOneWidget);
  });

  for (final (os, frosted) in [('android', true), ('ohos', false)]) {
    testWidgets('on $os the keys over the moving field ${frosted ? 'are' : 'are not'} frosted', (tester) async {
      await pumpCall(tester, extra: [operatingSystemProvider.overrideWithValue(os)]);
      expect(find.byType(BackdropFilter), frosted ? findsWidgets : findsNothing);
      await tester.tap(find.byKey(const ValueKey('call-hang-up')));
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('mute and loudspeaker keys switch and say so', (tester) async {
    final (audio, _) = await pumpCall(tester);
    await tester.tap(find.byKey(const ValueKey('call-mute')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(audio.calls, contains('mute:true'));
    expect(find.text('取消静音'), findsOneWidget);
    expect(find.text('已静音'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-speaker')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(audio.calls, contains('speaker:false'));
    expect(find.text('听筒'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('背景: the water by default; a picture once picked; her only when she lives here', (tester) async {
    final (audio, _) = await pumpCall(tester, extra: [callBackdropPickerProvider.overrideWithValue(() async => null)]);
    await tester.tap(find.byKey(const ValueKey('call-backdrop')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('通话设置'), findsOneWidget);
    // In a call the sheet also offers her voice and the recognition.
    expect(find.byKey(const ValueKey('call-voice')), findsOneWidget);
    expect(find.byKey(const ValueKey('call-recognition')), findsOneWidget);
    // 停顿多久算说完: 适中 by default; 耐心 is kept and reaches the call.
    await tester.ensureVisible(find.text('耐心'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('耐心'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(
      ProviderScope.containerOf(tester.element(find.byType(VoiceCallPage))).read(callSettingsProvider).pause,
      CallPause.patient,
    );
    expect(audio.calls, contains('callPause:patient'));
    expect(find.text('深海'), findsOneWidget);
    expect(find.text('选一张图'), findsOneWidget);
    // No companion pack in tests: her card is there but can't be chosen.
    await tester.tap(find.byKey(const ValueKey('backdrop-companion')));
    await tester.pump(const Duration(milliseconds: 300));
    final container = ProviderScope.containerOf(tester.element(find.byType(VoiceCallPage)));
    expect(container.read(callSettingsProvider).backdrop, CallBackdrop.sea);
    await tester.tapAt(const Offset(20, 20));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('the first call after launch keeps the saved earpiece and no barge-in', (tester) async {
    SharedPreferences.setMockInitialValues({'speech_call_v1': '{"speaker":false,"bargeIn":false}'});
    final (audio, _) = await pumpCall(tester);
    expect(audio.calls, contains('callStart:bargeIn=false'));
    expect(audio.calls, contains('speaker:false'));
    expect(audio.calls, isNot(contains('speaker:true')));
    expect(find.text('听筒'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('hung up while her voice is still being read: the closed page is asked nothing more', (tester) async {
    final gate = Completer<void>();
    await pumpCall(tester, extra: [speechVoiceSettingsProvider.overrideWith(() => _SlowVoice(gate.future))]);
    await tester.tap(find.byKey(const ValueKey('call-hang-up')));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.byType(VoiceCallPage), findsNothing);
    // DeepSeek's voice by default: it would look up who pays for it next.
    gate.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final still in [false, true]) {
    testWidgets(still ? 'less motion: the keys are there at once' : 'the keys rise in with the page', (tester) async {
      final hangUp = find.byKey(const ValueKey('call-hang-up'));
      double? first;
      await pumpCall(
        tester,
        still: still,
        opened: () => first = tester
            .widgetList<Opacity>(find.ancestor(of: hangUp, matching: find.byType(Opacity)))
            .fold<double>(1.0, (low, o) => o.opacity < low ? o.opacity : low),
      );
      expect(first, still ? 1.0 : lessThan(0.5));
      await tester.tap(hangUp);
      await tester.pump(const Duration(seconds: 1));
    });
  }

  testWidgets('less motion: captions stay built while their reveal clock keeps up', (tester) async {
    final reduced = ValueNotifier(true);
    addTearDown(reduced.dispose);
    const stillKey = ValueKey('still-caption');
    const movingKey = ValueKey('moving-caption');
    final text = List.filled(16, 'abcdefghij').join();
    const style = TextStyle(fontSize: 14, color: Colors.white);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: reduced,
              builder: (_, value, child) => MediaQuery(data: MediaQueryData(disableAnimations: value), child: child!),
              child: RevealText(key: stillKey, text: text, style: style),
            ),
            MediaQuery(
              data: const MediaQueryData(disableAnimations: false),
              child: RevealText(key: movingKey, text: text, style: style),
            ),
          ],
        ),
      ),
    );
    TextSpan span(Key key) => tester
        .widget<CaptionWindow>(find.descendant(of: find.byKey(key), matching: find.byType(CaptionWindow)))
        .span as TextSpan;
    await tester.pump(const Duration(milliseconds: 16));
    final still = span(stillKey);
    var moving = span(movingKey);
    var movingBuilds = 0;
    expect(still.toPlainText(), text);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(span(stillKey), same(still));
      final next = span(movingKey);
      if (!identical(next, moving)) movingBuilds++;
      moving = next;
    }
    expect(movingBuilds, 20);
    expect(moving.toPlainText().length, lessThan(text.length));
    reduced.value = false;
    await tester.pump();
    // TextSpan equality includes every child's text and style, including the fading tail.
    expect(span(stillKey), span(movingKey));
    await tester.pumpWidget(const SizedBox());
  });

  test('less motion: the colours hold still; only a voice changes the size', () {
    final scene = CallScene();
    addTearDown(scene.dispose);
    for (var t = 0.0; t < 2; t += 0.05) {
      scene.tick(t, phase: CallPhase.listening, mic: 0, voice: 0, isMuted: false, still: true);
    }
    expect(scene.flow, 0);
    expect(scene.scale, 1);
    for (var t = 2.0; t < 3; t += 0.05) {
      scene.tick(t, phase: CallPhase.hearing, mic: 0.8, voice: 0, isMuted: false, still: true);
    }
    expect(scene.flow, 0);
    expect(scene.scale, greaterThan(1.05));

    final moving = CallScene();
    addTearDown(moving.dispose);
    for (var t = 0.0; t < 2; t += 0.05) {
      moving.tick(t, phase: CallPhase.listening, mic: 0, voice: 0, isMuted: false);
    }
    expect(moving.flow, greaterThan(0.4));
  });

  test('two changes made before the saved settings are read: both kept, and what was saved too', () async {
    SharedPreferences.setMockInitialValues({'speech_call_v1': '{"bargeIn":false}'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final calls = container.read(callSettingsProvider.notifier);
    await Future.wait([
      calls.edit((saved) => saved.copyWith(pause: CallPause.patient)),
      calls.edit((saved) => saved.copyWith(speaker: false)),
    ]);
    final now = container.read(callSettingsProvider);
    expect((now.pause, now.speaker, now.bargeIn), (CallPause.patient, false, false));
    // And saved so: the last write carries both.
    final saved = jsonDecode((await SharedPreferences.getInstance()).getString('speech_call_v1')!) as Map;
    expect((saved['pause'], saved['speaker'], saved['bargeIn']), ('patient', false, false));
  });

  test('a backdrop choice is kept', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(callSettingsProvider);
    await Future<void>.delayed(Duration.zero);
    await container
        .read(callSettingsProvider.notifier)
        .update(const CallSettings(backdrop: CallBackdrop.image, image: '/x/backdrop-1.jpg'));
    final again = ProviderContainer();
    addTearDown(again.dispose);
    again.read(callSettingsProvider);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(again.read(callSettingsProvider).backdrop, CallBackdrop.image);
    expect(again.read(callSettingsProvider).image, '/x/backdrop-1.jpg');
  });
}

/// Her voice's settings, read only once [_gate] opens.
class _SlowVoice extends SpeechVoiceSettingsController {
  _SlowVoice(this._gate);

  final Future<void> _gate;

  @override
  Future<CompanionVoiceSettings> ready() async {
    await _gate;
    return super.ready();
  }
}
