import 'dart:async';

import 'package:dsh_app/speech/call/voice_call.dart';
import 'package:dsh_app/speech/deepseek_speech.dart';
import 'package:dsh_app/speech/speech_audio.dart';
import 'package:dsh_app/speech/speech_out.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'speech_fakes.dart';

// The native audio stream can change volume only after playback has opened.
class _OpeningVoice extends FakeOut {
  bool opened = false;

  @override
  void emit(SpeechOutEvent event) {
    if (event is SpeechOutStarted) opened = true;
    super.emit(event);
  }

  @override
  void duck(bool on) {
    if (opened) super.duck(on);
  }
}

class _Rig {
  _Rig({
    FakeCloud? cloud,
    FakeOut Function()? makeVoice,
    bool noRecognizer = false,
    bool verbatim = false,
    CallStart start = CallStart.ok,
    bool bargeIn = true,
    Duration confirmAfter = const Duration(milliseconds: 60),
    Duration cueAfter = const Duration(milliseconds: 40),
    // 快: the timings these tests were written for.
    CallPause pause = CallPause.quick,
  }) : audio = FakeAudio(start: start),
       cloud = cloud ?? FakeCloud() {
    call = VoiceCallController(
      audio: audio,
      conversation: conversation,
      verbatimInput: () => verbatim,
      recognizer: () async => noRecognizer ? null : (pick != null ? await pick!() : (next ?? this.cloud)),
      voice: () {
        final out = makeVoice?.call() ?? FakeOut();
        outs.add(out);
        return out;
      },
      choices: () async => (bargeIn: bargeIn, speaker: true, spokenHint: '（语音通话）', pause: pause),
      cutNote: (heard) => '（被打断在：$heard）',
      thinkingCue: () async => cues++,
      confirmAfter: confirmAfter,
      cueAfter: cueAfter,
    );
  }

  final FakeAudio audio;
  final FakeCloud cloud;

  /// What the recognition setting names now, when changed during the call.
  FakeCloud? next;

  /// Or, answered later: the recognizer as the provider would find it.
  Future<FakeCloud> Function()? pick;
  final conversation = FakeConversation();
  final outs = <FakeOut>[];
  int cues = 0;
  late final VoiceCallController call;

  static final second = Uint8List(44 + 32000);

  Future<void> say() async {
    audio.emit(const SpeechStart(over: false));
    audio.emit(Utterance(second, const Duration(seconds: 1)));
    await pumpEventQueue();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('persistent call stages contain no transcript, reply or audio content', () async {
    const channel = MethodChannel('dsh/diagnostics');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final records = <Map<Object?, Object?>>[];
    final writes = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'recordVoiceStage');
      records.add(call.arguments as Map<Object?, Object?>);
      return writes.future;
    });
    addTearDown(() {
      if (!writes.isCompleted) writes.complete();
      messenger.setMockMethodCallHandler(channel, null);
    });
    final rig = _Rig();
    rig.cloud.text = 'PRIVATE_TRANSCRIPT';
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('PRIVATE_REPLY');
    rig.call.hangUp();
    await pumpEventQueue();
    final stages = records.map((row) => row['stage']).toList();
    expect(
      stages,
      containsAllInOrder([
        'call_started',
        'preparing',
        'capture_started',
        'listening',
        'utterance_ready',
        'recognizing',
        'recognized',
        'reply_received',
        'call_ended',
      ]),
    );
    for (final record in records) {
      expect(record.keys.every((key) => const ['stage', 'backend', 'code'].contains(key)), true);
      expect(record.toString(), isNot(contains('PRIVATE_')));
    }
    rig.call.dispose();
  });

  test('a turn: heard, sent with the hint once, the reply read as it grows', () async {
    final rig = _Rig();
    await rig.call.start();
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.audio.calls, contains('callStart:bargeIn=true'));

    rig.audio.emit(const SpeechStart(over: false));
    expect(rig.call.phase, CallPhase.hearing);
    rig.audio.emit(Utterance(_Rig.second, const Duration(seconds: 1)));
    await pumpEventQueue();
    expect(rig.call.phase, CallPhase.thinking);
    expect(rig.call.heard, '今天天气怎么样');
    expect(rig.conversation.sent, ['（语音通话）\n今天天气怎么样']);

    rig.conversation.reply('北京晴，');
    expect(rig.outs, hasLength(1));
    rig.outs.single.emit(const SpeechOutStarted());
    expect(rig.call.phase, CallPhase.speaking);
    rig.conversation.reply('北京晴，最高二十度。');
    rig.conversation.reply('北京晴，最高二十度。', done: true);
    expect(rig.outs.single.added, ['北京晴，', '最高二十度。']);
    expect(rig.outs.single.finished, isTrue);
    rig.outs.single.emit(const SpeechOutDone());
    expect(rig.call.phase, CallPhase.listening);

    // The next message goes without the hint.
    rig.cloud.text = '那上海呢';
    await rig.say();
    expect(rig.conversation.sent.last, '那上海呢');
  });

  Future<_Rig> speaking({
    Duration confirmAfter = const Duration(milliseconds: 60),
    bool verbatim = false,
    FakeOut Function()? makeVoice,
  }) async {
    final rig = _Rig(confirmAfter: confirmAfter, verbatim: verbatim, makeVoice: makeVoice);
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('好的，我来详细说一说。');
    rig.outs.single.emit(const SpeechOutStarted());
    rig.outs.single.heard = '好的，';
    return rig;
  }

  test('an authoritative correction replaces queued speech and the call transcript', () async {
    final rig = await speaking(verbatim: true);
    addTearDown(rig.call.dispose);
    final old = rig.outs.single;
    rig.conversation.reply('改在明天。');
    expect(old.stopped, isTrue);
    expect(rig.outs, hasLength(2));
    final corrected = rig.outs.last;
    expect(corrected.added, ['改在明天。']);
    expect(rig.call.turns.single.her, '改在明天。');
    old.emit(const SpeechOutDone());
    rig.conversation.reply('改在明天。九点。', done: true);
    expect(corrected.added, ['改在明天。', '九点。']);
    expect(corrected.finished, isTrue);
    expect(rig.call.reply, '改在明天。九点。');
    expect(rig.conversation.interrupts, 0);
  });

  test('an empty final correction retires the voice and clears the old turn text', () async {
    final rig = await speaking(verbatim: true);
    addTearDown(rig.call.dispose);
    rig.conversation.reply('', done: true);
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.call.caption, isEmpty);
    expect(rig.call.turns.single.her, isEmpty);
  });

  for (final stillTalking in [true, false]) {
    test('a replacement voice uses the overlap state when playback opens: $stillTalking', () async {
      final rig = await speaking(makeVoice: _OpeningVoice.new, confirmAfter: const Duration(seconds: 5));
      addTearDown(rig.call.dispose);
      rig.audio.emit(const SpeechStart(over: true));
      final old = rig.outs.single;
      expect(old.ducks, [true]);
      rig.conversation.reply('改在周五。');
      final replacement = rig.outs.last;
      expect(old.stopped, isTrue);
      expect(replacement.ducks, isEmpty);
      if (!stillTalking) {
        rig.audio.emit(Utterance(_Rig.second, const Duration(milliseconds: 100)));
        await pumpEventQueue();
      }
      replacement.emit(const SpeechOutStarted());
      expect(replacement.ducks, stillTalking ? [true] : isEmpty);
      rig.call.hangUp();
      old.emit(const SpeechOutStarted());
      replacement.emit(const SpeechOutStarted());
      rig.conversation.reply('挂断后迟到的文字。');
      expect(rig.call.phase, CallPhase.ended);
      expect(rig.outs, hasLength(2));
      expect(replacement.ducks, stillTalking ? [true] : isEmpty);
    });
  }

  test('a replacement that cannot duck yields to an ongoing interruption', () async {
    var number = 0;
    final rig = await speaking(
      makeVoice: () => _OpeningVoice()..canDuck = number++ == 0,
      confirmAfter: const Duration(seconds: 5),
    );
    addTearDown(rig.call.dispose);
    rig.audio.emit(const SpeechStart(over: true));
    rig.conversation.reply('新声音刚开始。');
    final replacement = rig.outs.last;
    replacement.emit(const SpeechOutStarted());
    expect(replacement.stopped, isTrue);
    expect(rig.call.phase, CallPhase.hearing);
    expect(rig.conversation.interrupts, 1);
    rig.conversation.reply('同一轮迟到的话。');
    expect(rig.outs, hasLength(2));
  });

  Future<void> over(_Rig rig, String said) async {
    rig.cloud.text = said;
    rig.audio.emit(const SpeechStart(over: true));
    rig.audio.emit(Utterance(_Rig.second, const Duration(milliseconds: 600)));
    await pumpEventQueue();
  }

  test('agreement over her: she steps back, then carries on; nothing is sent', () async {
    final rig = await speaking();
    rig.audio.emit(const SpeechStart(over: true));
    expect(rig.outs.single.ducks, [true]);
    expect(rig.call.phase, CallPhase.speaking);
    rig.cloud.text = '嗯嗯，对';
    rig.audio.emit(Utterance(_Rig.second, const Duration(milliseconds: 600)));
    await pumpEventQueue();
    expect(rig.outs.single.ducks, [true, false]);
    expect(rig.outs.single.stopped, isFalse);
    expect(rig.conversation.interrupts, 0);
    expect(rig.conversation.sent, hasLength(1));
    expect(rig.call.phase, CallPhase.speaking);
  });

  test('words over her: she stops, the turn too, and the next message says where she was cut off', () async {
    final rig = await speaking();
    await over(rig, '换个话题吧');
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.conversation.sent.last, '（被打断在：好的，）\n换个话题吧');
  });

  test('verbatim companion call keeps app hint and cut-off assistant words out of the human prompt', () async {
    final rig = await speaking(verbatim: true);
    expect(rig.conversation.sent.single, '今天天气怎么样');
    await over(rig, '换个话题吧');
    expect(rig.conversation.interrupts, 1);
    expect(rig.conversation.sent, ['今天天气怎么样', '换个话题吧']);
    rig.call.dispose();
  });

  test('the turns: what was said and her reply, cut where she stopped', () async {
    final rig = await speaking();
    expect(rig.call.turns.single.you, '今天天气怎么样');
    expect(rig.call.turns.single.her, '好的，我来详细说一说。');
    await over(rig, '我想问别的');
    expect(rig.call.turns.first.her, '好的，');
    expect(rig.call.turns.first.cut, isTrue);
    expect(rig.call.turns.last.you, '我想问别的');
    expect(rig.call.turns.last.her, isEmpty);
    rig.call.hangUp();
  });

  test('another recognition setting during the call takes the next sentence', () async {
    final rig = _Rig();
    await rig.call.start();
    final other = FakeCloud('换了识别方式');
    rig.next = other;
    await rig.call.refreshRecognizer();
    await rig.say();
    expect(other.heard, hasLength(1));
    expect(rig.cloud.heard, isEmpty);
    expect(rig.conversation.sent.last, endsWith('换了识别方式'));
    rig.call.hangUp();
  });

  test('two quick recognition changes: the later one stays, however the answers come back', () async {
    final rig = _Rig();
    await rig.call.start();
    final slow = Completer<void>();
    final first = FakeCloud('先选的');
    final second = FakeCloud('后选的');
    var calls = 0;
    rig.pick = () async {
      calls++;
      if (calls == 1) {
        await slow.future;
        return first;
      }
      return second;
    };
    final earlier = rig.call.refreshRecognizer();
    await rig.call.refreshRecognizer();
    slow.complete();
    await earlier;
    await rig.say();
    expect(second.heard, hasLength(1));
    expect(first.heard, isEmpty);
    rig.call.hangUp();
  });

  test('a recognition change while the call starts: the latest is used from the first sentence', () async {
    final rig = _Rig();
    final slow = Completer<void>();
    final first = FakeCloud('先选的');
    final second = FakeCloud('后选的');
    var calls = 0;
    rig.pick = () async {
      calls++;
      if (calls == 1) {
        await slow.future;
        return first;
      }
      return second;
    };
    final starting = rig.call.start();
    await pumpEventQueue();
    await rig.call.refreshRecognizer();
    slow.complete();
    await starting;
    await rig.say();
    expect(second.heard, hasLength(1));
    expect(first.heard, isEmpty);
    rig.call.hangUp();
  });

  test('停 over her: she stops and nothing is sent; the next message still says where', () async {
    final rig = await speaking();
    await over(rig, '等一下！');
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.conversation.sent, hasLength(1));
    expect(rig.call.phase, CallPhase.listening);
    // What she was still writing is no longer read.
    rig.conversation.reply('好的，我来详细说一说。第一点', done: true);
    expect(rig.outs, hasLength(1));

    rig.cloud.text = '我想问别的';
    await rig.say();
    expect(rig.conversation.sent.last, '（被打断在：好的，）\n我想问别的');
  });

  test('talking on over her takes the turn before the words are known', () async {
    // Long enough that a busy machine cannot reach it before the first check.
    final rig = await speaking(confirmAfter: const Duration(milliseconds: 500));
    rig.audio.emit(const SpeechStart(over: true));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.outs.single.stopped, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.call.phase, CallPhase.hearing);
    rig.call.hangUp();
  });

  test('a slow answer gets the thinking cue once; a quick one none', () async {
    final rig = _Rig(cueAfter: const Duration(milliseconds: 400));
    await rig.call.start();
    await rig.say();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(rig.cues, 1);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(rig.cues, 1);

    rig.conversation.reply('好。', done: true);
    rig.outs.single
      ..emit(const SpeechOutStarted())
      ..emit(const SpeechOutDone());
    rig.cloud.text = '再说一个';
    await rig.say();
    rig.conversation.reply('行，');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(rig.cues, 1);
    rig.call.hangUp();
  });

  test('live words show while the person speaks, and stand in until the recognizer answers', () async {
    final rig = _Rig();
    await rig.call.start();
    rig.audio.emit(const SpeechStart(over: false));
    rig.call.live('今天天气');
    expect(rig.call.heard, '今天天气');
    rig.call.live('今天天气怎么样');
    rig.audio.emit(Utterance(_Rig.second, const Duration(seconds: 1)));
    expect(rig.call.heard, '今天天气怎么样');
    await pumpEventQueue();
    expect(rig.conversation.sent.single, endsWith('今天天气怎么样'));
  });

  test('over her, a few live words take the turn at once; agreement does not', () async {
    final rig = await speaking();
    rig.audio.emit(const SpeechStart(over: true));
    rig.call.live('嗯嗯');
    expect(rig.outs.single.stopped, isFalse);
    rig.call.live('换个话题');
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.conversation.interrupts, 1);
    expect(rig.call.phase, CallPhase.hearing);
  });

  test('the caption follows her voice; all of it once she is skipped', () async {
    final rig = await speaking();
    expect(rig.call.caption, '');
    rig.outs.single.emit(const SpeechOutLevel(0.4));
    expect(rig.call.caption, '好的，');
    rig.call.skip();
    expect(rig.call.caption, '好的，我来详细说一说。');
  });

  test('a knock is not a sentence', () async {
    final rig = _Rig();
    await rig.call.start();
    rig.audio.emit(const SpeechStart(over: false));
    rig.audio.emit(Utterance(_Rig.second, const Duration(milliseconds: 200)));
    await pumpEventQueue();
    expect(rig.cloud.heard, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('nothing recognized: back to listening, nothing sent', () async {
    final rig = _Rig(cloud: FakeCloud(''));
    await rig.call.start();
    await rig.say();
    expect(rig.conversation.sent, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('recognition fails: the call goes on and says why', () async {
    final cloud = FakeCloud()..fail = const DeepSeekSpeechError(DeepSeekSpeechFailure.insufficientBalance);
    final rig = _Rig(cloud: cloud);
    await rig.call.start();
    await rig.say();
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.call.error, isA<DeepSeekSpeechError>());
  });

  test('a reply with nothing to say (tools only) returns to listening', () async {
    final rig = _Rig();
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('', done: true);
    expect(rig.outs, isEmpty);
    expect(rig.call.phase, CallPhase.listening);
  });

  test('no recognizer, no permission: it ends and says so', () async {
    final none = _Rig(noRecognizer: true);
    await none.call.start();
    expect(none.call.phase, CallPhase.ended);
    expect(none.call.ended, CallEnd.noRecognizer);
    expect(none.audio.calls, isNot(contains('callStart:bargeIn=true')));

    final denied = _Rig(start: CallStart.permission);
    await denied.call.start();
    expect(denied.call.ended, CallEnd.permission);
  });

  test('mute, loudspeaker and hang up reach the native side', () async {
    final rig = _Rig(bargeIn: false);
    await rig.call.start();
    expect(rig.audio.calls, contains('callStart:bargeIn=false'));
    rig.call.setMuted(true);
    expect(rig.call.muted, isTrue);
    await rig.call.setSpeaker(false);
    expect(rig.call.speaker, isFalse);
    rig.call.hangUp();
    expect(rig.call.phase, CallPhase.ended);
    expect(rig.audio.calls, containsAllInOrder(['mute:true', 'speaker:false', 'callStop']));
  });

  test('停顿多久算说完: the chosen one opens the call; a change reaches the microphone at once', () async {
    final rig = _Rig(pause: CallPause.normal);
    await rig.call.start();
    expect(rig.audio.calls, contains('callStart:pause=normal'));
    rig.call.setPause(CallPause.patient);
    rig.call.setPause(CallPause.patient);
    expect(rig.audio.calls.where((c) => c.startsWith('callPause:')), ['callPause:patient']);
    rig.call.hangUp();
    rig.call.setPause(CallPause.quick);
    expect(rig.audio.calls.where((c) => c.startsWith('callPause:')), ['callPause:patient']);
  });

  test('耐心: a short 嗯嗯 over her, arriving after the longer pause, does not stop her', () async {
    final rig = _Rig(confirmAfter: const Duration(milliseconds: 60), pause: CallPause.patient);
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('一段很长的回答。');
    rig.outs.single.emit(const SpeechOutStarted());
    rig.audio.emit(const SpeechStart(over: true));
    // Past confirmAfter, within 耐心's extra second: still waiting for the words.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(rig.outs.single.stopped, isFalse);
    rig.cloud.text = '嗯嗯';
    rig.audio.emit(Utterance(_Rig.second, const Duration(seconds: 1)));
    await pumpEventQueue();
    expect(rig.outs.single.stopped, isFalse);
    expect(rig.call.phase, CallPhase.speaking);
    rig.call.hangUp();
  });

  test('changed to 耐心 while talking over her: the confirmation waits the longer pause too', () async {
    final rig = _Rig(confirmAfter: const Duration(milliseconds: 150));
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('一段很长的回答。');
    rig.outs.single.emit(const SpeechOutStarted());
    rig.audio.emit(const SpeechStart(over: true));
    rig.call.setPause(CallPause.patient);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(rig.outs.single.stopped, isFalse);
    rig.call.hangUp();
  });

  test('skip: she stops, the call listens again', () async {
    final rig = _Rig();
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('一段很长的回答。');
    rig.outs.single.emit(const SpeechOutStarted());
    rig.call.skip();
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.conversation.interrupts, 0);
  });

  test('skip before she begins: none of this reply is read, it goes on in the conversation', () async {
    final rig = _Rig();
    await rig.call.start();
    await rig.say();
    rig.conversation.reply('北京晴，');
    expect(rig.call.phase, CallPhase.thinking);
    rig.call.skip();
    expect(rig.outs.single.stopped, isTrue);
    expect(rig.call.phase, CallPhase.listening);
    rig.conversation.reply('北京晴，最高二十度。', done: true);
    expect(rig.outs.single.added, ['北京晴，']);

    // Before any text: none comes to her voice either.
    await rig.say();
    rig.call.skip();
    rig.conversation.reply('好的。', done: true);
    expect(rig.outs, hasLength(1));
    expect(rig.call.phase, CallPhase.listening);
    expect(rig.conversation.interrupts, 0);
  });

  test('skip while what was said is still being made out: it is sent, its reply not read', () async {
    final rig = _Rig();
    await rig.call.start();
    final gate = Completer<void>();
    rig.cloud.wait = gate.future;
    await rig.say();
    expect(rig.call.phase, CallPhase.thinking);
    rig.call.skip();
    gate.complete();
    await pumpEventQueue();
    expect(rig.conversation.sent.single, endsWith('今天天气怎么样'));
    expect(rig.call.phase, CallPhase.listening);
    rig.conversation.reply('晴。', done: true);
    expect(rig.outs, isEmpty);
    expect(rig.call.phase, CallPhase.listening);

    // The next one is read again.
    rig.cloud.wait = null;
    await rig.say();
    rig.conversation.reply('好的。');
    expect(rig.outs, hasLength(1));
    rig.call.hangUp();
  });
}
