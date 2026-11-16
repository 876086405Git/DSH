// Voice input: the platform bridge (a seam for tests).

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/chat/voice/voice_bridge.dart';

final voiceBridgeProvider = Provider<VoiceBridge>((ref) => MethodChannelVoiceBridge());

/// Asked once per page that shows them.
final voiceCapabilitiesProvider = FutureProvider.autoDispose<VoiceCapabilities>(
  (ref) => ref.watch(voiceBridgeProvider).capabilities(),
);

/// Dictation into the composer is on (starting, listening or transcribing).
/// The chat page reports it; what waits for a quiet moment reads it.
class VoiceInputActiveController extends Notifier<bool> {
  @override
  bool build() => false;

  void set(bool active) {
    if (ref.mounted && active != state) state = active;
  }
}

final voiceInputActiveProvider = NotifierProvider<VoiceInputActiveController, bool>(VoiceInputActiveController.new);
