// 语音通话: talking with a conversation, hands free. The microphone is cut into
// utterances on the phone (speech/call capture: echo cancellation, a speech
// gate, 300 ms kept before each start); each utterance is recognized whole
// (DeepSeek's recognizer by default) and sent as an ordinary message; the reply
// is read aloud while it is still being written.
//
// Speaking over the reply (插话打断, on by default) goes in two steps, as voice
// agents do it: she steps back at once (quieter), and what was said decides —
// agreement (嗯、对、好的) and noise let her carry on, 停 / 等一下 stop her, and
// anything else, or talking on past [VoiceCallController.confirmAfter] (1.6 s), is the
// person taking the turn: she stops, the turn behind her too, and the next
// message tells the model where she was cut off.
//
// The controller knows nothing of widgets or of where messages go: a
// [CallConversation] sends and reports the reply, a [VoiceCloud] recognizes,
// [voice] makes a fresh [SpeechOut] for each reply.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../diagnostics/diagnostics_channel.dart';
import '../speech_audio.dart';
import '../speech_out.dart';
import '../voice_cloud.dart';
import 'turn_words.dart';

enum CallPhase {
  /// Getting the microphone.
  starting,

  /// Waiting for the person to speak.
  listening,

  /// The person is speaking.
  hearing,

  /// Recognizing what was said, then waiting for the reply's first words.
  thinking,

  /// The reply is being read aloud.
  speaking,

  ended,
}

enum CallEnd { hungUp, permission, microphone, noRecognizer, background, failed }

/// The reply to what was last sent, so far.
class CallReply {
  const CallReply(this.text, {required this.done});

  /// Everything said so far (it only grows while [done] is false).
  final String text;

  /// The turn ended.
  final bool done;
}

/// Where a call's messages go and its replies come from.
abstract class CallConversation {
  /// Sends what the person said; false when it could not go.
  Future<bool> send(String text);

  /// The reply to the last [send], as it grows.
  Stream<CallReply> get replies;

  /// Stops the turn under way (the person spoke over it).
  Future<void> interrupt();

  /// Waiting on the person (an approval, a question): the call page shows it.
  bool get waiting;

  void dispose();
}

/// The person's choices for a call: speaking over her stops her; the
/// loudspeaker or the earpiece; [spokenHint] goes before the first message.
typedef CallChoices = ({bool bargeIn, bool speaker, String? spokenHint, CallPause pause});

/// One exchange of the call as it reads: what the person said, and her reply
/// as far as it is known (all of it, or, [cut], as far as she got).
@immutable
class CallTurn {
  const CallTurn(this.you, {this.her = '', this.cut = false});

  final String you;
  final String her;
  final bool cut;
}

class VoiceCallController extends ChangeNotifier {
  VoiceCallController({
    required this.audio,
    required this.conversation,
    required this.recognizer,
    required this.voice,
    required this.choices,
    this.permission,
    this.cutNote,
    this.thinkingCue,
    this.confirmAfter = const Duration(milliseconds: 1600),
    this.cueAfter = const Duration(milliseconds: 1200),
  });

  /// Talking on over her this long is taking the turn, whatever the words.
  final Duration confirmAfter;

  /// No reply yet this long after the person finished: the thinking cue, once a turn.
  final Duration cueAfter;

  /// The line telling the model where the person cut its reply off ([heard]:
  /// the end of what they heard, '' when they cut in before a word).
  final String Function(String heard)? cutNote;

  /// Plays the soft "still thinking" sound.
  final Future<void> Function()? thinkingCue;

  final SpeechAudio audio;
  final CallConversation conversation;

  /// The recognizer for this call; null when none can be had (the call ends).
  final Future<VoiceCloud?> Function() recognizer;

  /// A voice for one reply.
  final SpeechOut Function() voice;

  /// The saved choices, read as the call starts (they may still be loading
  /// when the page opens).
  final Future<CallChoices> Function() choices;
  bool _bargeIn = true;
  CallPause _pause = CallPause.normal;

  /// Put before the call's first message: asks for short spoken answers.
  String? _spokenHint;

  /// Asks for the microphone (the system dialog); false when refused.
  final Future<bool> Function()? permission;

  /// The microphone is being asked for: the dialog may pause the app.
  bool get asking => _asking;
  bool _asking = false;

  CallPhase _phase = CallPhase.starting;
  CallEnd? _ended;
  bool _muted = false;
  bool _speaker = true;
  bool? _speakerPreference;
  int _speakerRequest = 0;
  Object? _speakerError;
  Completer<void>? _initialSpeaker;
  double _micLevel = 0;
  double _voiceLevel = 0;
  String _heard = '';
  String _reply = '';
  Object? _error;
  bool _hinted = false;

  /// The person began speaking over her: she is quieter until it is known what they said.
  bool _over = false;
  Timer? _overTimer;

  /// Since the person began talking over her (for [_overTimer]'s deadline).
  final _overFor = Stopwatch();

  /// What the person had heard of a reply they cut off, for their next message.
  String? _cutAt;

  /// The person's words as the phone hears them while they speak (live captions,
  /// when the streaming recognizer is there); the message still goes from [recognizer].
  String _live = '';

  /// What she has said of the reply so far, while her voice carries it.
  String _said = '';
  bool _voiced = false;
  Timer? _cueTimer;
  bool _cued = false;

  VoiceCloud? _cloud;
  StreamSubscription<SpeechAudioEvent>? _audioSub;
  StreamSubscription<CallReply>? _replySub;
  SpeechOut? _out;
  StreamSubscription<SpeechOutEvent>? _outSub;
  int _spoken = 0;
  bool _replyDone = true;
  int _turn = 0;
  int _recognizing = 0;

  /// The recognition under way when she was skipped before speaking.
  int _hushed = 0;
  bool _disposed = false;

  final _turns = <CallTurn>[];

  /// The call so far, oldest first.
  List<CallTurn> get turns => List.unmodifiable(_turns);

  CallPhase get phase => _phase;
  CallEnd? get ended => _ended;
  bool get muted => _muted;
  bool get speaker => _speaker;
  double get micLevel => _micLevel;
  double get voiceLevel => _voiceLevel;

  /// What the person is saying now (live), else what they said last (recognized).
  String get heard => (_phase == CallPhase.hearing || _over) && _live.isNotEmpty ? _live : _heard;

  /// Words heard live by the phone's own recognizer. Over her voice, a few real
  /// words (not agreement) are enough: the person is taking the turn.
  void live(String text) {
    if (_phase == CallPhase.ended) return;
    _live = text.trim();
    if (_over && _live.runes.length >= 4 && overWords(_live) == OverWords.speech) _cutIn();
    notifyListeners();
  }

  /// The reply being read (so far).
  String get reply => _reply;

  /// The reply as far as she has said it (nothing yet while her voice gets
  /// ready); all of it when there is no voice.
  String get caption => _voiced || _out != null ? _said : _reply;

  /// The thinking cue may still play: nothing of the reply has a voice yet.
  bool get cueStill => _phase == CallPhase.thinking && _out == null;

  /// The last thing that went wrong without ending the call (recognition,
  /// sending, the voice); cleared when the next turn starts.
  Object? get error => _error;

  /// The recognition setting changed: what is said next goes to what it names
  /// now (if that can listen; else to the one already in use).
  Future<void> refreshRecognizer() async {
    if (_phase == CallPhase.ended) return;
    final mine = ++_refreshing;
    // Still starting: start() looks again with the new setting.
    if (_cloud == null) return;
    final next = await recognizer();
    // A later change has the last word, whichever answer comes back first.
    if (next != null && mine == _refreshing && _phase != CallPhase.ended) _cloud = next;
  }

  int _refreshing = 0;

  Future<void> start() async {
    unawaited(const DiagnosticsChannel().recordVoiceStage('call_started'));
    _replySub = conversation.replies.listen(_onReply);
    _audioSub = audio.events.listen(_onAudio);
    final chosen = await choices();
    if (_disposed || _phase == CallPhase.ended) return;
    _bargeIn = chosen.bargeIn;
    _pause = chosen.pause;
    if (!audio.requiresSpeakerAck) _speaker = chosen.speaker;
    _spokenHint = chosen.spokenHint;
    notifyListeners();
    VoiceCloud? cloud;
    int mine;
    do {
      // Changed while this looked (refreshRecognizer during start): look again.
      mine = ++_refreshing;
      cloud = await recognizer();
      if (_disposed || _phase == CallPhase.ended) return;
    } while (mine != _refreshing);
    if (cloud == null) {
      _end(CallEnd.noRecognizer);
      return;
    }
    _cloud = cloud;
    final ask = permission;
    if (ask != null) {
      _asking = true;
      final granted = await ask().catchError((Object _) => false);
      _asking = false;
      if (_disposed || _phase == CallPhase.ended) return;
      if (!granted) {
        _end(CallEnd.permission);
        return;
      }
    }
    unawaited(const DiagnosticsChannel().recordVoiceStage('preparing'));
    final started = audio.requiresSpeakerAck
        ? await audio.startCallMuted(bargeIn: _bargeIn, pause: _pause, muted: _muted)
        : await audio.startCall(bargeIn: _bargeIn, pause: _pause);
    if (_disposed || _phase == CallPhase.ended) {
      // OH already retired this native generation in _end. Its old success
      // acknowledgement must not issue a global stop after a newer call starts.
      if (started == CallStart.ok && !audio.requiresSpeakerAck) unawaited(audio.stopCall());
      return;
    }
    switch (started) {
      case CallStart.ok:
        unawaited(const DiagnosticsChannel().recordVoiceStage('capture_started'));
        if (audio.requiresSpeakerAck) {
          // A newer control can supersede this request while the call starts.
          // start() still waits for the current acknowledgement or call end.
          final ready = _initialSpeaker = Completer<void>();
          unawaited(_setSpeakerChecked(_speakerPreference ?? chosen.speaker));
          await ready.future;
          return;
        } else {
          _speaker = await audio.speaker(_speaker);
          if (_disposed || _phase == CallPhase.ended) return;
        }
        _set(CallPhase.listening);
      case CallStart.permission:
        _end(CallEnd.permission);
      case CallStart.microphone || CallStart.unavailable:
        _end(CallEnd.microphone);
    }
  }

  void _onAudio(SpeechAudioEvent event) {
    if (_phase == CallPhase.ended) return;
    switch (event) {
      case MicLevel(:final value):
        _micLevel = value;
        notifyListeners();
      case SpeechStart(:final over):
        _live = '';
        final out = _out;
        if ((over || _phase == CallPhase.speaking) && out != null) {
          _over = true;
          // The system voice cannot be turned down: she stops at once.
          if (!out.canDuck) {
            _cutIn();
            return;
          }
          // Over her voice: quieter (the native side already turned her down)
          // until what was said is known, or the person keeps talking.
          out.duck(true);
          _overTimer?.cancel();
          // The chosen pause's extra quiet doesn't count as talking on: a short
          // 嗯嗯 still arrives as an utterance before this confirms.
          _overFor
            ..reset()
            ..start();
          _overTimer = Timer(confirmAfter + _pause.longer, _cutIn);
          return;
        }
        _set(CallPhase.hearing);
      case Utterance(:final wav, :final duration):
        unawaited(const DiagnosticsChannel().recordVoiceStage('utterance_ready'));
        // Finished before [confirmAfter]: the words decide.
        _overTimer?.cancel();
        // The live words stand in until the recognizer's come back.
        if (_live.isNotEmpty) _heard = _live;
        _live = '';
        unawaited(_recognize(wav, duration));
      case CallError():
        _end(CallEnd.failed);
      case PlayEvent() || PlayLevel():
        break;
    }
  }

  Future<void> _recognize(Uint8List wav, Duration duration) async {
    final cloud = _cloud;
    if (cloud == null || _muted) return;
    // Said over her (she may already have stopped, if they talked on).
    final over = _over || _cutAt != null;
    // Too short to be words (a cough, a knock).
    if (duration < const Duration(milliseconds: 350)) {
      if (_over) {
        _carryOn();
      } else if (_phase == CallPhase.hearing) {
        _set(CallPhase.listening);
      }
      return;
    }
    final mine = ++_recognizing;
    _error = null;
    if (!_over) _set(CallPhase.thinking);
    String text;
    try {
      unawaited(const DiagnosticsChannel().recordVoiceStage('recognizing', backend: 'cloud'));
      text = await cloud.transcribe(wav);
      unawaited(const DiagnosticsChannel().recordVoiceStage('recognized', backend: 'cloud'));
    } catch (error) {
      unawaited(const DiagnosticsChannel().recordVoiceStage('failed', backend: 'cloud'));
      if (_phase == CallPhase.ended || mine != _recognizing) return;
      if (_over) {
        // Could not make it out: she carries on.
        _carryOn();
        return;
      }
      _error = error;
      _set(CallPhase.listening);
      return;
    }
    if (_phase == CallPhase.ended || mine != _recognizing) return;
    final taken = over ? overWords(text) : OverWords.speech;
    if (taken == OverWords.backchannel && _over) {
      _carryOn();
      return;
    }
    if (_over) _cutIn();
    if (taken != OverWords.speech || text.trim().isEmpty) {
      // 停, agreement after she stopped, or nothing at all: nothing to send (where
      // she was cut off still goes with the next message).
      _set(_out == null ? CallPhase.listening : CallPhase.speaking);
      return;
    }
    _heard = text.trim();
    _turns.add(CallTurn(_heard));
    _reply = '';
    _said = '';
    _voiced = false;
    _spoken = 0;
    _turn++;
    // Skipped while this was being made out: it still goes, its reply is not read.
    final hushed = mine == _hushed;
    _replyDone = hushed;
    final hint = _spokenHint;
    final cut = _cutAt;
    _cutAt = null;
    final note = cut == null ? null : cutNote?.call(cut.length > 30 ? '…${cut.substring(cut.length - 30)}' : cut);
    final message = [if (!_hinted && hint != null) hint, ?note, _heard].join('\n');
    _hinted = true;
    _cued = false;
    _cueTimer?.cancel();
    if (hushed) {
      if (!_disposed) notifyListeners();
    } else {
      _cueTimer = Timer(cueAfter, _cue);
      _set(CallPhase.thinking);
    }
    final sent = await conversation.send(message);
    if (_phase == CallPhase.ended) return;
    if (!sent) {
      _replyDone = true;
      _error = const CallSendFailed();
      _set(CallPhase.listening);
    }
  }

  void _onReply(CallReply reply) {
    if (_phase == CallPhase.ended || _replyDone) return;
    final text = reply.text;
    if (text.length > _spoken) {
      if (_spoken == 0) unawaited(const DiagnosticsChannel().recordVoiceStage('reply_received'));
      final out = _out ??= _newVoice();
      out.add(text.substring(_spoken));
      _spoken = text.length;
      _reply = text;
      if (_turns.isNotEmpty) _turns.last = CallTurn(_turns.last.you, her: text);
      notifyListeners();
    }
    if (reply.done) {
      _replyDone = true;
      final out = _out;
      if (out == null) {
        // Nothing to say (the turn only ran tools, or was stopped).
        if (_phase == CallPhase.thinking) _set(CallPhase.listening);
      } else {
        out.finish();
      }
    }
  }

  /// The person takes the turn over her: she stops where they cut in, and so
  /// does the turn behind her.
  void _cutIn() {
    _overTimer?.cancel();
    if (!_over) return;
    unawaited(const DiagnosticsChannel().recordVoiceStage('interrupted'));
    _over = false;
    final out = _out;
    if (out != null) {
      _cutAt = out.heard;
      if (_turns.isNotEmpty && _turns.last.her.isNotEmpty) {
        _turns.last = CallTurn(_turns.last.you, her: out.heard, cut: true);
      }
      _stopVoice();
    }
    if (!_replyDone) unawaited(conversation.interrupt());
    _replyDone = true;
    _set(CallPhase.hearing);
  }

  /// It was agreement or noise: she comes back up and carries on.
  void _carryOn() {
    _overTimer?.cancel();
    _over = false;
    final out = _out;
    if (out == null) {
      if (_phase != CallPhase.thinking) _set(CallPhase.listening);
      return;
    }
    out.duck(false);
    _set(CallPhase.speaking);
  }

  void _cue() {
    // Only before any reply text: the cue's stream would take the place of her voice's.
    if (_cued || !cueStill) return;
    _cued = true;
    unawaited(thinkingCue?.call());
  }

  SpeechOut _newVoice() {
    final out = voice();
    final turn = _turn;
    _outSub = out.events.listen((event) {
      if (!identical(_out, out) || _phase == CallPhase.ended) return;
      switch (event) {
        case SpeechOutStarted():
          _voiced = true;
          _cueTimer?.cancel();
          if (_phase == CallPhase.thinking || _phase == CallPhase.listening) _set(CallPhase.speaking);
        case SpeechOutLevel(:final value):
          _voiceLevel = value;
          _said = out.heard;
          notifyListeners();
        case SpeechOutDone():
          _said = out.heard;
          _clearVoice(out);
          if (_phase == CallPhase.speaking || (_phase == CallPhase.thinking && turn == _turn && _replyDone)) {
            _set(CallPhase.listening);
          }
        case SpeechOutFailed(:final error):
          _clearVoice(out);
          _voiced = false;
          _error = error;
          if (_phase == CallPhase.speaking || _phase == CallPhase.thinking) _set(CallPhase.listening);
      }
    });
    return out;
  }

  void _clearVoice(SpeechOut out) {
    if (!identical(_out, out)) return;
    _out = null;
    unawaited(_outSub?.cancel());
    _outSub = null;
    _voiceLevel = 0;
  }

  void _stopVoice() {
    final out = _out;
    if (out == null) return;
    _clearVoice(out);
    out.stop();
  }

  /// The microphone hears nothing (and nothing is recorded) while muted.
  void setMuted(bool on) {
    if (_phase == CallPhase.ended) return;
    _muted = on;
    _micLevel = 0;
    unawaited(audio.mute(on));
    if (on && _phase == CallPhase.hearing) _set(CallPhase.listening);
    notifyListeners();
  }

  /// Changed in 通话设置: the next pause is judged by it (the one under way too).
  void setPause(CallPause pause) {
    if (_phase == CallPhase.ended || pause == _pause) return;
    _pause = pause;
    // Talking over her right now: the deadline moves with the pause, from when they began.
    if (_overTimer?.isActive ?? false) {
      _overTimer!.cancel();
      final left = confirmAfter + pause.longer - _overFor.elapsed;
      _overTimer = Timer(left.isNegative ? Duration.zero : left, _cutIn);
    }
    // Before the microphone is open this changes nothing there; startCall takes [_pause].
    unawaited(audio.callPause(pause));
  }

  Future<void> setSpeaker(bool on) async {
    if (_phase == CallPhase.ended) return;
    if (audio.requiresSpeakerAck) {
      _speakerPreference = on;
      return _setSpeakerChecked(on);
    }
    _speaker = await audio.speaker(on);
    notifyListeners();
  }

  Future<void> _setSpeakerChecked(bool on) async {
    final request = ++_speakerRequest;
    try {
      final accepted = await audio.speaker(on);
      if (_disposed || _phase == CallPhase.ended || request != _speakerRequest) return;
      _speaker = accepted;
      if (identical(_error, _speakerError)) _error = null;
      _speakerError = null;
      final ready = _initialSpeaker;
      if (ready != null) {
        _initialSpeaker = null;
        _set(CallPhase.listening);
        ready.complete();
        return;
      }
    } catch (error) {
      if (_disposed || _phase == CallPhase.ended || request != _speakerRequest) return;
      // The existing call error state is safe for the UI's unawaited control.
      // Keep the previous preference; the requested value was not accepted.
      _error = _speakerError = error;
      if (_initialSpeaker != null) {
        // There is no acknowledged preference for this new call yet.
        _end(CallEnd.failed);
        return;
      }
    }
    notifyListeners();
  }

  /// Tapped while she speaks: she stops, the reply goes on in the conversation.
  /// Before she has begun (her voice about to be tried out on the same
  /// speaker), she won't read this reply at all.
  void skip() {
    if (_phase != CallPhase.speaking && _phase != CallPhase.thinking) return;
    // Thinking may still be making out what was said: that reply stays quiet too.
    if (_phase == CallPhase.thinking) _hushed = _recognizing;
    _cueTimer?.cancel();
    _stopVoice();
    // The rest is there to read.
    _voiced = false;
    _replyDone = true;
    _set(CallPhase.listening);
  }

  void hangUp() => _end(CallEnd.hungUp);

  /// The app went to the background: Android gives a backgrounded app no
  /// microphone, so the call ends rather than listen to silence.
  void backgrounded() {
    if (!_asking) _end(CallEnd.background);
  }

  void _end(CallEnd why) {
    if (_phase == CallPhase.ended) return;
    if (audio.requiresSpeakerAck) _speakerRequest++;
    unawaited(const DiagnosticsChannel().recordVoiceStage('call_ended', code: why.index));
    _ended = why;
    _overTimer?.cancel();
    _cueTimer?.cancel();
    _stopVoice();
    unawaited(audio.stopCall());
    unawaited(_replySub?.cancel());
    unawaited(_audioSub?.cancel());
    _set(CallPhase.ended);
    final ready = _initialSpeaker;
    _initialSpeaker = null;
    ready?.complete();
  }

  void _set(CallPhase phase) {
    if (_phase != phase && phase == CallPhase.listening) {
      unawaited(const DiagnosticsChannel().recordVoiceStage('listening'));
    }
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    // Quiet first: the page is going away and listens no more.
    _disposed = true;
    _end(CallEnd.hungUp);
    conversation.dispose();
    super.dispose();
  }
}

/// What was said could not be sent (no engine, the conversation is busy elsewhere).
class CallSendFailed implements Exception {
  const CallSendFailed();
}
