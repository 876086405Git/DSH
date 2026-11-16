// The fixed a836 source predates main's read-aloud settings and diagnostics.
// Keep its existing enum and methods intact. Main b452 has real members with
// these names; Dart instance members take precedence over these extensions.
import 'package:flutter/services.dart';
import '../companion/companion_voice_source.dart';
import '../diagnostics/diagnostics_channel.dart';

/// An explicit request setting for callers on the older source snapshot.
/// Main's existing settings/UI continue to use CompanionVoiceSource.deepseek.
/// This object is not a replacement for the app's persisted settings model.
class OhosSpeechVoiceSettings extends CompanionVoiceSettings {
  const OhosSpeechVoiceSettings({this.voice = 'stella'});
  final String voice;
  @override
  String get deepseekVoice => voice;
}

extension SpeechVoiceCompatibility on CompanionVoiceSettings {
  bool get usesDeepSeekSpeech => this is OhosSpeechVoiceSettings || source.name == 'deepseek';
  String get deepseekVoice {
    final settings = this;
    return settings is OhosSpeechVoiceSettings ? settings.voice : 'stella';
  }
}

extension SpeechDiagnosticsCompatibility on DiagnosticsChannel {
  Future<void> recordVoiceStage(String stage, {String backend = 'unknown', int? code}) async {
    const stages = {'synthesis_requested', 'playback_opening', 'playback_started', 'failed'};
    if (!stages.contains(stage) || !{'deepseek', 'unknown'}.contains(backend)) return;
    try {
      await channel.invokeMethod<void>('recordVoiceStage', {'stage': stage, 'backend': backend, 'code': ?code});
    } on MissingPluginException {
      // The older native diagnostics endpoint is optional.
    } on PlatformException {
      // Diagnostics must not replace the playback result.
    }
  }
}
