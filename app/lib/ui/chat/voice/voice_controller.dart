// Composer dictation. Automatic mode uses DeepSeek's recognizer when someone
// can pay for it (the signed-in account or the API key: speech/voice_cloud.dart),
// then the engine's voice model when it is ready (the on-device SenseVoice
// model, voice settings); otherwise the system
// service, retried once with engine transcription after a non-user service
// failure. Audio is recorded again; the system service's earlier audio is never
// claimed to be recoverable.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../voice/live_words.dart';
import '../../../l10n/l10n.dart';
import '../../../speech/voice_cloud.dart';
import '../../../state/voice_settings.dart';
import '../../speech/speech_ui.dart';
import '../mention/mention_text_controller.dart';
import 'voice_bridge.dart';

enum VoicePhase { idle, starting, listening, transcribing }

/// Who recognizes: the phone's service, the engine's model, or a cloud service.
enum VoiceEngine { system, engine, cloud }

class VoiceMessage {
  const VoiceMessage(this.text, {this.openSettings = false, this.change = false});
  final String text;

  /// The app's system settings page (microphone permission) helps.
  final bool openSettings;

  /// Another way of dictating would do (no recognizer, no service, the
  /// service failed, the voice model not downloaded): the toast offers
  /// 「更换」, to 设置 › 语音输入 (the mode and the voice model).
  final bool change;
}

/// Complete Android SpeechRecognizer error table; unknown/vendor codes remain visible.
String voiceErrorText(int code) => switch (code) {
  1 => appL10n.voiceErrorNetworkTimeout,
  2 => appL10n.voiceErrorNetwork,
  3 => appL10n.voiceErrorAudio,
  4 => appL10n.voiceErrorServer,
  5 => appL10n.voiceErrorClient,
  6 => appL10n.voiceErrorSpeechTimeout,
  7 => appL10n.voiceErrorNoMatch,
  8 => appL10n.voiceErrorBusy,
  9 => appL10n.voiceErrorPermission,
  10 => appL10n.voiceErrorTooManyRequests,
  11 => appL10n.voiceErrorDisconnected,
  12 => appL10n.voiceErrorLanguageUnsupported,
  13 => appL10n.voiceErrorLanguageUnavailable,
  14 => appL10n.voiceErrorSupportCheck,
  15 => appL10n.voiceErrorDownloadEvents,
  VoiceError.recorderFailed => appL10n.chatVoiceMicrophoneFailed,
  _ => appL10n.voiceErrorUnknown(code),
};

class _VoiceTarget {
  const _VoiceTarget(this.client, this.generation, this.catalog);
  final DshClient client;
  final MuxGeneration? generation;
  final SpeechCatalog catalog;

  bool current(DshClient? active) => identical(client, active) && identical(generation, client.mux.generation);
}

class VoiceInputController extends ChangeNotifier with WidgetsBindingObserver {
  VoiceInputController({
    required this.input,
    required this.bridge,
    required this.client,
    Object? Function()? inputOwner,
    Future<VoiceMode> Function()? mode,
    bool Function()? modelReady,
    bool Function()? harmony,
    this._cloud,
    this._cloudLikely,
    this._signedIn,
    this._liveWords,
    this.onRecognized,
    this.requiredProviderId,
    bool observeLifecycle = true,
  }) : _mode = mode ?? _automatic,
       _inputOwner = inputOwner ?? client,
       _modelReady = modelReady ?? _noModel,
       _harmony = harmony ?? _noModel,
       _observing = observeLifecycle {
    if (_observing) {
      final binding = WidgetsBinding.instance;
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
        _foreground = binding.lifecycleState == AppLifecycleState.resumed;
      }
      binding.addObserver(this);
    }
    unawaited(refresh());
  }

  String get _noRecognizer => _harmony() ? appL10n.harmonyVoiceSystemUnavailable : appL10n.voiceConfigureEither;

  static Future<VoiceMode> _automatic() async => VoiceMode.auto;
  static bool _noModel() => false;

  /// Optional strict offline provider for the pet foreground fallback.
  final String? requiredProviderId;
  final TextEditingController input;
  final VoiceBridge bridge;
  final DshClient? Function() client;

  /// The draft receiving phone recognition. Defaults to the client; the chat
  /// supplies its saved host selection, which survives transport replacement.
  final Object? Function() _inputOwner;
  final Future<VoiceMode> Function() _mode;

  /// The on-device voice model is ready for this host (voice settings):
  /// automatic mode then records for it instead of trying the phone service.
  final bool Function() _modelReady;

  /// HarmonyOS: the recogniser is the system's own, so there is none to choose,
  /// and its engine has no model to download.
  final bool Function() _harmony;

  /// The cloud recognizer for a mode, if any (DeepSeek's, or the person's own).
  final VoiceCloudResolver? _cloud;

  /// A cloud recognizer is probably there (settings only, nothing asked):
  /// the microphone shows even without a phone or engine recognizer.
  final bool Function()? _cloudLikely;

  /// Signed in to a DeepSeek account (for saying why DeepSeek cannot listen).
  final bool Function()? _signedIn;

  /// Words as they are spoken, from the phone's streaming recognizer (null
  /// when its model is not downloaded): shown as provisional text while a
  /// recording runs; the recording's own text replaces them when it is done.
  final Future<LiveWords?> Function(void Function(String words) onWords)? _liveWords;
  LiveWords? _live;

  /// Live words are in the draft, not yet replaced by the recording's text.
  bool _liveShown = false;
  VoiceCloud? _cloudRun;
  final bool _observing;
  void Function(VoiceMessage message)? onMessage;

  /// A dictation put its words in the composer (usage statistics).
  final VoidCallback? onRecognized;
  final level = ValueNotifier<double>(0);

  VoiceCapabilities _caps = VoiceCapabilities.none;
  _VoiceTarget? _catalog;
  _VoiceTarget? _target;
  DshClient? _probedClient;
  MuxGeneration? _probedGeneration;
  Future<void>? _refreshing;
  Future<void>? _cancelling;
  int _catalogProbe = 0;
  bool _disposed = false;
  bool _foreground = true;
  bool _requestingPermission = false;

  VoicePhase _phase = VoicePhase.idle;
  VoiceEngine? _engine;
  VoiceMode _runMode = VoiceMode.auto;
  int _operation = 0;
  bool _fallbackTried = false;
  bool _switching = false;
  DshClient? _runClient;
  Object? _runInputOwner;
  MuxGeneration? _runGeneration;
  StreamSubscription<VoiceEvent>? _events;
  Timer? _finalTimeout;

  TextEditingValue? _base;
  // The last text owned by this dictation; external edits keep their draft.
  String? _draftText;
  int _anchorStart = 0;
  int _anchorEnd = 0;
  String _heard = '';

  VoicePhase get phase => _phase;
  bool get active => _phase != VoicePhase.idle;
  VoiceEngine? get engine => _engine;
  bool get engineReady => _caps.recorder && (_catalog?.current(client()) ?? false);
  bool get available =>
      _caps.recognizer || engineReady || (_caps.recorder && _cloud != null && (_cloudLikely?.call() ?? false));

  bool _current(int operation) => !_disposed && active && operation == _operation;
  // Phone recognition belongs to the draft, not its Host transport. Starting
  // before an engine is selected, recording and fallback keep the original link.
  bool get _hostCurrent => _engine == VoiceEngine.system || _engine == VoiceEngine.cloud
      ? _runInputOwner == _inputOwner()
      : identical(_runClient, client()) && identical(_runGeneration, _runClient?.mux.generation);

  Future<void> refresh() {
    if (_disposed) return Future.value();
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  /// A model change must not be absorbed by a probe of its previous state.
  /// Wait for that probe, without replaying the event onto a replacement host.
  Future<void> refreshAfterModelChange() async {
    if (_disposed) return;
    final c = client();
    final generation = c?.mux.generation;
    await _refreshing;
    if (_disposed || !identical(client(), c) || !identical(c?.mux.generation, generation)) return;
    await refresh();
  }

  Future<void> _refresh() async {
    final caps = await bridge.capabilities();
    if (_disposed) return;
    _caps = caps;
    final c = client();
    final generation = c?.mux.generation;
    _probedClient = c;
    _probedGeneration = generation;
    if (!(_catalog?.current(c) ?? false)) _catalog = null;
    // A working system service must not wait for a slow engine probe. The
    // fallback and explicit Engine mode probe on demand, including on ROMs
    // that report a system service which fails as soon as it is called.
    if (!caps.recognizer && caps.recorder) await _readCatalog(c, generation);
    if (!_disposed) notifyListeners();
  }

  Future<_VoiceTarget?> _readCatalog(DshClient? c, MuxGeneration? generation) async {
    if (c == null || !_caps.recorder || !identical(client(), c) || !identical(c.mux.generation, generation)) {
      return null;
    }
    final probe = ++_catalogProbe;
    _VoiceTarget? target;
    try {
      var catalog = await c.speechCatalog().timeout(const Duration(seconds: 4));
      if (requiredProviderId case final id?) {
        final provider = catalog?.providers.where((p) => p.id == id && p.location == 'host-local').firstOrNull;
        if (provider == null || !provider.usable) return null;
        catalog = SpeechCatalog(
          providers: catalog!.providers,
          providerId: id,
          language: catalog.language,
          maxAudioBytes: catalog.maxAudioBytes,
          maxDurationSeconds: catalog.maxDurationSeconds,
        );
      }
      if (catalog?.selected?.usable ?? false) target = _VoiceTarget(c, generation, catalog!);
    } catch (_) {
      // Missing speech bundle, unavailable provider, or disconnected host.
    }
    if (_disposed || !identical(client(), c) || !identical(c.mux.generation, generation)) return null;
    if (probe == _catalogProbe) _catalog = target;
    return target;
  }

  void ensureFresh() {
    if (_disposed) return;
    if (active && !_hostCurrent) {
      // Composer calls this while building. Restoring the draft notifies its
      // persistence listener, so defer it until after this synchronous build.
      // A queued check from an older run must never cancel its replacement.
      final operation = _operation;
      scheduleMicrotask(() {
        if (_current(operation) && !_hostCurrent) unawaited(cancel());
      });
    }
    final c = client();
    if (_refreshing != null || (identical(c, _probedClient) && identical(c?.mux.generation, _probedGeneration))) return;
    scheduleMicrotask(() => unawaited(refresh()));
  }

  Future<void> start() async {
    if (_cancelling case final pending?) await pending;
    if (active || _disposed || !_foreground) return;
    final operation = ++_operation;
    _fallbackTried = false;
    _switching = false;
    _runClient = client();
    _runInputOwner = _inputOwner();
    _runGeneration = _runClient?.mux.generation;
    _setPhase(VoicePhase.starting);
    final VoicePermission permission;
    _requestingPermission = true;
    try {
      permission = await bridge.requestPermission();
    } on PlatformException {
      if (_current(operation)) {
        _finish();
        _say(VoiceMessage(appL10n.chatVoiceMicrophoneFailed));
      }
      return;
    } finally {
      if (operation == _operation) _requestingPermission = false;
    }
    if (!_current(operation)) return;
    if (!_foreground || !_hostCurrent) {
      await cancel();
      return;
    }
    if (permission != VoicePermission.granted) {
      _finish();
      _say(
        permission == VoicePermission.blocked
            ? VoiceMessage(appL10n.chatVoicePermissionOff, openSettings: true)
            : VoiceMessage(appL10n.chatVoicePermissionNeeded),
      );
      return;
    }
    final VoiceMode mode;
    try {
      mode = await _mode();
    } catch (_) {
      if (_current(operation)) {
        _finish();
        _say(VoiceMessage(appL10n.voiceSettingsFailed));
      }
      return;
    }
    if (!_current(operation)) return;
    _runMode = mode;
    await refresh();
    if (!_current(operation)) return;
    if (!_hostCurrent) {
      await cancel();
      return;
    }
    // A cloud recognizer first: DeepSeek's in automatic mode when someone pays for it.
    final cloudMode = _runMode == VoiceMode.deepseek || _runMode == VoiceMode.cloud;
    if ((cloudMode || _runMode == VoiceMode.auto) && _cloud != null && _caps.recorder) {
      VoiceCloud? cloud;
      try {
        cloud = await _cloud(_runMode);
      } catch (_) {
        cloud = null;
      }
      if (!_current(operation)) return;
      if (cloud != null) {
        final value = input.value;
        _base = value;
        _draftText = value.text;
        _anchorStart = value.selection.isValid ? value.selection.start : value.text.length;
        _anchorEnd = value.selection.isValid ? value.selection.end : value.text.length;
        _heard = '';
        await _startCloud(operation, cloud);
        return;
      }
    }
    if (cloudMode) {
      _finish();
      _say(
        VoiceMessage(
          !_caps.recorder
              ? appL10n.chatVoiceMicrophoneFailed
              : _runMode == VoiceMode.deepseek
              ? (_signedIn?.call() ?? false ? appL10n.speechAccountUnusable : appL10n.speechNoCredential)
              : appL10n.speechCloudNotSetUp,
          change: true,
        ),
      );
      return;
    }
    final system =
        _runMode == VoiceMode.system || (_runMode == VoiceMode.auto && _caps.recognizer && !_caps.systemUnreliable);
    if (system && !_caps.recognizer) {
      _finish();
      _say(
        VoiceMessage(
          _harmony()
              ? appL10n.harmonyVoiceSystemUnavailable
              : wordsForIos
              ? appL10n.iosVoiceAllowSystem
              : appL10n.voiceChooseSystem,
          change: true,
        ),
      );
      return;
    }
    final value = input.value;
    _base = value;
    _draftText = value.text;
    _anchorStart = value.selection.isValid ? value.selection.start : value.text.length;
    _anchorEnd = value.selection.isValid ? value.selection.end : value.text.length;
    _heard = '';
    if (system && _runMode == VoiceMode.auto && _caps.recorder && _modelReady()) {
      // The voice model first: phone services on Chinese ROMs report
      // themselves available and then fail. The engine has the last word; a
      // stale "ready" leaves the phone service as it was.
      final target = await _readCatalog(_runClient, _runGeneration);
      if (!_current(operation)) return;
      if (target != null) {
        await _startRecorder(operation, target);
        return;
      }
    }
    if (!system) {
      final target = await _readCatalog(_runClient, _runGeneration);
      if (!_current(operation)) return;
      if (target == null) {
        _finish();
        _say(VoiceMessage(_runMode == VoiceMode.engine ? appL10n.voiceConfigureEngine : _noRecognizer, change: true));
        return;
      }
      await _startRecorder(operation, target);
      return;
    }
    _engine = VoiceEngine.system;
    _listen(operation);
    try {
      await bridge.startRecognizer();
    } on PlatformException catch (error) {
      if (_current(operation) && _engine == VoiceEngine.system) _error(operation, _platformCode(error));
      return;
    }
    if (!_current(operation) || _engine != VoiceEngine.system || _switching || _phase != VoicePhase.starting) return;
    HapticFeedback.lightImpact();
    _setPhase(VoicePhase.listening);
  }

  void _listen(int operation) {
    unawaited(_events?.cancel());
    _events = bridge.events.listen((event) => _onEvent(operation, event));
  }

  static int _platformCode(PlatformException error) {
    final details = error.details;
    if (details is Map && details['code'] is num) return (details['code'] as num).toInt();
    return switch (error.code) {
      'permission' => 9,
      'audio' => VoiceError.recorderFailed,
      _ => 5,
    };
  }

  Future<void> _startRecorder(int operation, _VoiceTarget target, {bool fallback = false}) async {
    if (!_current(operation) || !target.current(client())) return;
    _target = target;
    _engine = VoiceEngine.engine;
    _switching = false;
    _listen(operation);
    try {
      await bridge.startRecorder(maxSeconds: (target.catalog.maxSeconds - 1).clamp(1, 600));
    } on PlatformException catch (error) {
      if (_current(operation)) {
        _finish();
        _say(VoiceMessage(voiceErrorText(_platformCode(error))));
      }
      return;
    }
    if (!_current(operation) || _phase != VoicePhase.starting) return;
    if (!target.current(client())) {
      await cancel();
      return;
    }
    unawaited(_startLive(operation));
    HapticFeedback.lightImpact();
    _setPhase(VoicePhase.listening);
    if (fallback) _say(VoiceMessage(appL10n.voiceFallbackStarted));
  }

  Future<void> _startCloud(int operation, VoiceCloud cloud) async {
    _cloudRun = cloud;
    _engine = VoiceEngine.cloud;
    _listen(operation);
    try {
      await bridge.startRecorder(maxSeconds: cloud.maxSeconds);
    } on PlatformException catch (error) {
      if (_current(operation)) {
        _finish();
        _say(VoiceMessage(voiceErrorText(_platformCode(error))));
      }
      return;
    }
    if (!_current(operation) || _phase != VoicePhase.starting) return;
    unawaited(_startLive(operation));
    HapticFeedback.lightImpact();
    _setPhase(VoicePhase.listening);
    if (_runMode == VoiceMode.auto) unawaited(_cloudNoticeOnce());
  }

  Future<void> _startLive(int operation) async {
    final live = await _liveWords?.call((words) {
      if (_current(operation) && _phase == VoicePhase.listening && words.isNotEmpty) {
        if (_apply(words, provisional: true)) _liveShown = true;
      }
    });
    if (live == null) return;
    if (_current(operation)) {
      _live = live;
    } else {
      unawaited(live.stop());
    }
  }

  void _stopLive() {
    final live = _live;
    _live = null;
    if (live != null) unawaited(live.stop());
  }

  static const cloudNoticeKey = 'speech_cloud_notice_shown';

  /// Automatic mode sends the recording to DeepSeek without the person having
  /// chosen it: said once, with 「更换」 to choose another way.
  Future<void> _cloudNoticeOnce() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(cloudNoticeKey) == true) return;
      // Marked as said only once someone is there to hear it.
      if (_disposed || onMessage == null) return;
      _say(VoiceMessage(appL10n.speechCloudNotice, change: true));
      await prefs.setBool(cloudNoticeKey, true);
    } catch (_) {
      // No preferences: said this time, and again next time.
    }
  }

  Future<void> _transcribeCloud(int operation) async {
    final cloud = _cloudRun;
    Uint8List? wav;
    try {
      wav = await bridge.stop();
    } on PlatformException catch (error) {
      if (_current(operation)) {
        _finish();
        _say(VoiceMessage(voiceErrorText(_platformCode(error))));
      }
      return;
    }
    if (!_current(operation)) return;
    if (cloud == null || wav == null || wav.length < 44 + 9600) {
      _finish();
      _say(VoiceMessage(appL10n.chatVoiceNotHeard));
      return;
    }
    try {
      final text = await cloud.transcribe(wav);
      if (!_current(operation)) return;
      if (text.isEmpty) {
        _finish();
        _say(VoiceMessage(appL10n.chatVoiceNotHeard));
        return;
      }
      if (_apply(text, provisional: false)) onRecognized?.call();
      _finish();
    } catch (error) {
      if (!_current(operation)) return;
      _finish();
      _say(VoiceMessage(speechErrorText(appL10n, error, listening: true), change: true));
    }
  }

  Future<void> _fallback(int operation) async {
    _fallbackTried = true;
    _switching = true;
    _engine = null;
    _finalTimeout?.cancel();
    _finalTimeout = null;
    unawaited(_events?.cancel());
    _events = null;
    _restoreDraft();
    _heard = '';
    _setPhase(VoicePhase.starting);
    try {
      await bridge.cancel();
    } catch (_) {}
    if (!_current(operation)) return;
    if (!_hostCurrent) {
      _finish();
      _say(VoiceMessage(appL10n.commonEngineUnreachable));
      return;
    }
    final target = await _readCatalog(_runClient, _runGeneration);
    if (!_current(operation)) return;
    if (target == null) {
      _finish();
      _say(VoiceMessage(_noRecognizer, change: true));
      return;
    }
    await _startRecorder(operation, target, fallback: true);
  }

  Future<void> stop() async {
    if (_phase != VoicePhase.listening) return;
    final operation = _operation;
    HapticFeedback.lightImpact();
    _setPhase(VoicePhase.transcribing);
    _stopLive();
    if (_engine == VoiceEngine.system) {
      _finalTimeout = Timer(const Duration(seconds: 6), () {
        if (!_current(operation) || _engine != VoiceEngine.system) return;
        unawaited(bridge.cancel());
        _completeSystem(_heard);
      });
      try {
        await bridge.stop();
      } on PlatformException catch (error) {
        if (_current(operation) && _engine == VoiceEngine.system) _error(operation, _platformCode(error));
      }
      return;
    }
    if (_engine == VoiceEngine.cloud) return _transcribeCloud(operation);
    await _transcribe(operation);
  }

  Future<void> _transcribe(int operation) async {
    final target = _target;
    Uint8List? wav;
    try {
      wav = await bridge.stop();
    } on PlatformException catch (error) {
      if (_current(operation)) {
        _finish();
        _say(VoiceMessage(voiceErrorText(_platformCode(error))));
      }
      return;
    }
    if (!_current(operation)) return;
    if (target == null || !target.current(client())) {
      _finish();
      _say(VoiceMessage(appL10n.commonEngineUnreachable));
      return;
    }
    if (wav == null || wav.length < 44 + 9600) {
      _finish();
      _say(VoiceMessage(appL10n.chatVoiceNotHeard));
      return;
    }
    try {
      final transcript = await target.client.transcribe(
        wav,
        providerId: target.catalog.providerId,
        language: target.catalog.language,
      );
      if (!_current(operation)) return;
      if (!target.current(client())) {
        _finish();
        return;
      }
      if (transcript.text.isEmpty) {
        _finish();
        _say(VoiceMessage(appL10n.chatVoiceNotHeard));
        return;
      }
      if (_apply(transcript.text, provisional: false)) onRecognized?.call();
      _finish();
    } catch (_) {
      if (!_current(operation)) return;
      _finish();
      _say(VoiceMessage(appL10n.chatVoiceTranscriptionFailed, change: true));
    }
  }

  void _restoreDraft() {
    final base = _base;
    if (base == null || input.text != _draftText) return;
    final mentions = input;
    if (mentions is MentionTextController) mentions.provisional = TextRange.empty;
    _draftText = base.text;
    input.value = base;
  }

  bool get cancelling => _cancelling != null;

  Future<void> cancel() {
    if (_cancelling case final pending?) return pending;
    if (!active) return Future<void>.value();
    _restoreDraft();
    final done = Future<void>.sync(bridge.cancel)
        .catchError((Object _) {
          // The bridge may already have detached.
        })
        .whenComplete(() => _cancelling = null);
    _cancelling = done;
    _finish();
    return done;
  }

  void _error(int operation, int code) {
    // The app holds the microphone permission (checked before starting), so
    // ERROR_INSUFFICIENT_PERMISSIONS here is the service's own: Xiaomi's 小爱
    // without its permissions, a vendor service refusing other apps.
    if (_engine == VoiceEngine.system &&
        _runMode == VoiceMode.auto &&
        !_fallbackTried &&
        (VoiceError.canFallback(code) || code == VoiceError.permission)) {
      unawaited(_fallback(operation));
      return;
    }
    final heard = _heard;
    if (heard.trim().isEmpty) {
      _restoreDraft();
    } else {
      if (_apply(heard, provisional: false)) onRecognized?.call();
    }
    _finish();
    if (!VoiceError.noSpeech.contains(code) || heard.trim().isEmpty) _say(VoiceMessage(voiceErrorText(code)));
  }

  void _onEvent(int operation, VoiceEvent event) {
    if (!_current(operation) || _switching) return;
    switch (event) {
      case VoiceLevel(:final value):
        level.value = value.clamp(0.0, 1.0);
      case VoicePartial(:final text):
        if (_engine != VoiceEngine.system) return;
        _heard = text;
        _apply(text, provisional: true);
      case VoiceFinal(:final text):
        if (_engine != VoiceEngine.system) return;
        _completeSystem(text.isEmpty ? _heard : text);
      case VoiceError(:final code):
        _error(operation, code);
      case VoiceLimit():
        if (_engine != VoiceEngine.system && _phase == VoicePhase.listening) unawaited(stop());
      case VoiceEnd():
        if (_engine == VoiceEngine.system) {
          _completeSystem(_heard);
        }
    }
  }

  void _completeSystem(String text) {
    if (text.trim().isEmpty) {
      _restoreDraft();
      _finish();
      _say(VoiceMessage(appL10n.chatVoiceNotHeard));
    } else {
      if (_apply(text, provisional: false)) onRecognized?.call();
      _finish();
    }
  }

  /// Puts [heard] at the anchor of the starting draft.
  bool _apply(String heard, {required bool provisional}) {
    final base = _base;
    if (base == null || input.text != _draftText) return false;
    if (!provisional) _liveShown = false;
    final text = base.text;
    final spoken = heard.trim();
    final before = text.substring(0, _anchorStart);
    final after = text.substring(_anchorEnd);
    final lead = spoken.isNotEmpty && _needsSpace(before, spoken) ? ' ' : '';
    final trail = spoken.isNotEmpty && _needsSpace(spoken, after) ? ' ' : '';
    final inserted = '$lead$spoken$trail';
    final caret = _anchorStart + inserted.length;
    final mentions = input;
    if (mentions is MentionTextController) {
      mentions.provisional = TextRange.empty;
    }
    final nextText = '$before$inserted$after';
    _draftText = nextText;
    input.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: caret - trail.length),
    );
    if (mentions is MentionTextController && provisional && spoken.isNotEmpty) {
      mentions.provisional = TextRange(
        start: _anchorStart + lead.length,
        end: _anchorStart + lead.length + spoken.length,
      );
    }
    return true;
  }

  /// Latin words on both sides of the seam get a space; CJK does not.
  static bool _needsSpace(String left, String right) {
    if (left.isEmpty || right.isEmpty) return false;
    final a = left.codeUnitAt(left.length - 1);
    final b = right.codeUnitAt(0);
    bool word(int u) => (u >= 0x30 && u <= 0x39) || (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);
    // `Hello,` + `world` too.
    final leftEnds = word(a) || ',.!?;:'.codeUnits.contains(a);
    return leftEnds && word(b);
  }

  void _finish() {
    _stopLive();
    // Not heard after all (failed, empty, too short): the draft goes back.
    if (_liveShown) _restoreDraft();
    _liveShown = false;
    _operation++;
    _requestingPermission = false;
    _switching = false;
    _target = null;
    _cloudRun = null;
    _runInputOwner = null;
    _finalTimeout?.cancel();
    _finalTimeout = null;
    unawaited(_events?.cancel());
    _events = null;
    final mentions = input;
    if (mentions is MentionTextController) {
      mentions.provisional = TextRange.empty;
    }
    _base = null;
    _draftText = null;
    _engine = null;
    level.value = 0;
    _setPhase(VoicePhase.idle);
  }

  void _setPhase(VoicePhase phase) {
    if (_phase == phase || _disposed) return;
    _phase = phase;
    notifyListeners();
  }

  void _say(VoiceMessage message) {
    if (!_disposed) onMessage?.call(message);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused || AppLifecycleState.hidden:
        _foreground = false;
        if (active && !_requestingPermission) unawaited(cancel());
      case AppLifecycleState.resumed:
        _foreground = true;
        unawaited(refresh());
      default:
        break;
    }
  }

  @override
  void dispose() {
    if (active) {
      unawaited(bridge.cancel().catchError((_) {}));
    }
    _operation++;
    _disposed = true;
    _stopLive();
    _finalTimeout?.cancel();
    unawaited(_events?.cancel());
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    level.dispose();
    super.dispose();
  }
}
