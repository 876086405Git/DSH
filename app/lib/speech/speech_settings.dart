// 设置 › 语音: whose voice reads replies aloud (the same choices as her voice
// in 伙伴小屋, DeepSeek's first), the cloud recognizer for 语音输入 when it
// isn't DeepSeek's, and how a 语音通话 behaves.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../companion/companion_voice_source.dart';
import 'speech_audio.dart';

const speechVoiceKeys = VoiceSettingsKeys(
  on: 'speech_voice_enabled',
  plain: 'speech_voice_v1',
  openaiKey: 'speech_voice_openai_key',
  headers: 'speech_voice_custom_headers',
  presetKeys: 'speech_voice_preset_keys',
);

/// The 朗读 voice: DeepSeek's until the person picks another. Its `on` is
/// unused (reading aloud is a button, not a switch).
class SpeechVoiceSettingsController extends VoiceOutputSettingsController {
  @override
  VoiceSettingsKeys get keys => speechVoiceKeys;

  @override
  CompanionVoiceSettings get defaults => const CompanionVoiceSettings(source: CompanionVoiceSource.deepseek);
}

final speechVoiceSettingsProvider = NotifierProvider<SpeechVoiceSettingsController, CompanionVoiceSettings?>(
  SpeechVoiceSettingsController.new,
);

/// Her voice as it is used: her own settings, or 朗读's when she follows them
/// (still only when she is switched on, and never cloned).
final companionEffectiveVoiceProvider = Provider<CompanionVoiceSettings?>((ref) {
  final own = ref.watch(companionVoiceSettingsProvider);
  if (own == null || !own.follow) return own;
  final shared = ref.watch(speechVoiceSettingsProvider);
  if (shared == null) return null;
  return shared.copyWith(on: own.on, follow: true, cloneOn: false);
});

// ── Cloud recognizer ───────────────────────────────────────────────────────

/// An OpenAI-compatible `/audio/transcriptions` service (OpenAI's Whisper,
/// SiliconFlow's SenseVoice, Groq, most self-hosted Whisper servers).
class CloudAsrSettings {
  const CloudAsrSettings({this.base = '', this.key = '', this.model = ''});

  final String base;
  final String key;
  final String model;

  bool get configured => base.trim().isNotEmpty && model.trim().isNotEmpty;

  CloudAsrSettings copyWith({String? base, String? key, String? model}) =>
      CloudAsrSettings(base: base ?? this.base, key: key ?? this.key, model: model ?? this.model);
}

class CloudAsrController extends Notifier<CloudAsrSettings> {
  static const _plainKey = 'speech_asr_cloud_v1';
  static const _secretKey = 'speech_asr_cloud_key';
  static const _secure = FlutterSecureStorage();
  late Future<void> _loaded;

  @override
  CloudAsrSettings build() {
    _loaded = _load();
    return const CloudAsrSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_plainKey);
      final json = raw == null ? null : jsonDecode(raw);
      var next = CloudAsrSettings(
        base: json is Map && json['base'] is String ? json['base'] as String : '',
        model: json is Map && json['model'] is String ? json['model'] as String : '',
      );
      try {
        next = next.copyWith(key: await _secure.read(key: _secretKey) ?? '');
      } on Object {
        // No keystore here: no key, nothing else lost.
      }
      if (ref.mounted) state = next;
    } on Object {
      // Unreadable: empty for this run.
    }
  }

  Future<CloudAsrSettings> ready() async {
    await _loaded;
    return state;
  }

  Future<void> update(CloudAsrSettings next) async {
    await _loaded;
    if (!ref.mounted) return;
    final before = state;
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_plainKey, jsonEncode({'base': next.base.trim(), 'model': next.model.trim()}));
    if (before.key != next.key) {
      try {
        await _secure.write(key: _secretKey, value: next.key.trim());
      } on Object {
        // Kept for this run only.
      }
    }
  }
}

final cloudAsrProvider = NotifierProvider<CloudAsrController, CloudAsrSettings>(CloudAsrController.new);

// ── Calls ──────────────────────────────────────────────────────────────────

/// What a call shows behind its light: deep water, the person's own picture,
/// or her (伙伴小屋's character, speaking with the call's voice).
enum CallBackdrop { sea, image, companion }

/// The light in the middle of a call: the glass orb (the default), or
/// Libraries.dev's voice ring (a glassy ribbon in the theme's colours) or its single grey line.
enum CallVisual { ring, mono, glass }

class CallSettings {
  const CallSettings({
    this.bargeIn = true,
    this.spoken = true,
    this.speaker = true,
    this.backdrop = CallBackdrop.sea,
    this.image = '',
    this.cue = true,
    this.visual = CallVisual.glass,
    this.pause = CallPause.normal,
  });

  /// Speaking over her stops her (else what is said while she talks is ignored).
  final bool bargeIn;

  /// Each message of a call asks for a short, spoken answer without formatting.
  final bool spoken;

  /// Starts on the loudspeaker (a headset always wins).
  final bool speaker;
  final CallBackdrop backdrop;

  /// The picture for [CallBackdrop.image]: a copy this app keeps ('' for none).
  final String image;

  /// A soft chime when an answer is slow to start.
  final bool cue;

  /// The light in the middle.
  final CallVisual visual;

  /// How long a pause ends what the person says.
  final CallPause pause;

  CallSettings copyWith({
    bool? bargeIn,
    bool? spoken,
    bool? speaker,
    CallBackdrop? backdrop,
    String? image,
    bool? cue,
    CallVisual? visual,
    CallPause? pause,
  }) => CallSettings(
    bargeIn: bargeIn ?? this.bargeIn,
    spoken: spoken ?? this.spoken,
    speaker: speaker ?? this.speaker,
    backdrop: backdrop ?? this.backdrop,
    image: image ?? this.image,
    cue: cue ?? this.cue,
    visual: visual ?? this.visual,
    pause: pause ?? this.pause,
  );
}

class CallSettingsController extends Notifier<CallSettings> {
  static const _key = 'speech_call_v1';
  late Future<void> _loaded;

  @override
  CallSettings build() {
    _loaded = _load();
    return const CallSettings();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      final json = raw == null ? null : jsonDecode(raw);
      if (json is! Map || !ref.mounted) return;
      state = CallSettings(
        bargeIn: json['bargeIn'] != false,
        spoken: json['spoken'] != false,
        speaker: json['speaker'] != false,
        backdrop: CallBackdrop.values.asNameMap()[json['backdrop']] ?? CallBackdrop.sea,
        image: json['image'] is String ? json['image'] as String : '',
        cue: json['cue'] != false,
        visual: CallVisual.values.asNameMap()[json['visual']] ?? CallVisual.glass,
        pause: CallPause.values.asNameMap()[json['pause']] ?? CallPause.normal,
      );
    } on Object {
      // Defaults for this run.
    }
  }

  /// The settings once the saved ones have been read.
  Future<CallSettings> ready() async {
    await _loaded;
    return state;
  }

  /// [change] applied to the saved settings once they are in (not to the
  /// defaults shown before then).
  Future<void> edit(CallSettings Function(CallSettings saved) change) async {
    await _loaded;
    // Applied and taken in at once: another edit waiting too sees this one.
    if (ref.mounted) await _keep(change(state));
  }

  Future<void> update(CallSettings next) async {
    // After the saved settings are in: they never overwrite a change made meanwhile.
    await _loaded;
    if (ref.mounted) await _keep(next);
  }

  Future<void> _keep(CallSettings next) async {
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'bargeIn': next.bargeIn,
        'spoken': next.spoken,
        'speaker': next.speaker,
        'backdrop': next.backdrop.name,
        'image': next.image,
        'cue': next.cue,
        'visual': next.visual.name,
        'pause': next.pause.name,
      }),
    );
  }
}

final callSettingsProvider = NotifierProvider<CallSettingsController, CallSettings>(CallSettingsController.new);
