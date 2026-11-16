import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_features.dart';
import 'hosts_state.dart';

/// How 语音输入 listens. [deepseek]: DeepSeek's recognizer (the signed-in account or
/// the API key); [cloud]: an OpenAI-compatible service set up in 设置 › 语音; auto
/// uses DeepSeek's when someone can pay for it, else as before.
enum VoiceMode { auto, deepseek, system, engine, cloud }

/// [mode] as it works on HarmonyOS's own engine, which has no voice model: one
/// chosen for a remote host's recognizer is automatic here.
VoiceMode voiceModeOnHarmonyLocal(VoiceMode mode) => mode == VoiceMode.engine ? VoiceMode.auto : mode;

/// HarmonyOS, talking to its own engine, which has no voice model.
final harmonyLocalVoiceProvider = Provider<bool>(
  (ref) => ref.watch(operatingSystemProvider) == 'ohos' && ref.watch(activeHostProvider).isLocal,
);

class VoiceSettingsController extends Notifier<VoiceMode> {
  static const preferenceKey = 'voice_recognition_mode';
  late Future<void> _loaded;

  @override
  VoiceMode build() {
    _loaded = _load();
    return VoiceMode.auto;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final stored = prefs.getString(preferenceKey);
      state = VoiceMode.values.firstWhere((mode) => mode.name == stored, orElse: () => VoiceMode.auto);
    } catch (_) {
      // Unreadable preferences: stay on auto for this run.
    }
  }

  Future<VoiceMode> ready() async {
    await _loaded;
    return ref.mounted ? state : VoiceMode.auto;
  }

  Future<void> setMode(VoiceMode mode) async {
    await _loaded;
    if (!ref.mounted) return;
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(preferenceKey, mode.name);
  }
}

final voiceSettingsProvider = NotifierProvider<VoiceSettingsController, VoiceMode>(VoiceSettingsController.new);
