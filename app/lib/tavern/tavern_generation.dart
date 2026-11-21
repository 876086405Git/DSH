// 酒馆设置 › 生成: how much of the story goes to the model, how long a reply
// may be, and how freely it writes. The engine's global preset numbers are
// read and written through readSettings / setSettings; a chat can select its
// own library preset (tavern_presets_page.dart).

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tavern_provider.dart';

/// The context the model sees (tokens): ST's default 4K, then what DeepSeek's
/// window allows. More context remembers more, and costs more each turn.
/// Another channel's model may take more: any size in the range can be typed.
const tavernContextSizes = [4095, 16384, 32768, 65536, 131072];
const tavernContextRange = (min: 512, max: 2097152);

/// 16384 as `16K` (ST's 4095 as `4K`).
String tavernContextLabel(num tokens) => '${(tokens + 1) ~/ 1024}K';

/// The longest reply (tokens).
const tavernReplySizes = [300, 1000, 2000, 4000];
const tavernReplyRange = (min: 16, max: 131072);

/// How freely it writes: DeepSeek suggests 1.3 for conversation, 1.5 for
/// creative writing. The Chat Completions range is 0–2.
const tavernTemperatures = [0.7, 1.0, 1.3, 1.5];
const tavernTemperatureRange = (min: 0.0, max: 2.0);

/// A preset's other sampling numbers (the preset page): its common values,
/// and the Chat Completions range for typing another.
const tavernTopPs = [0.8, 0.9, 0.95, 1.0];
const tavernTopPRange = (min: 0.0, max: 1.0);
const tavernPenalties = [0.0, 0.5, 1.0];
const tavernPenaltyRange = (min: -2.0, max: 2.0);

class TavernGeneration {
  const TavernGeneration({required this.maxContext, required this.maxReply, required this.temperature});

  /// The default preset's values when nothing is set: ST's own.
  static const standard = TavernGeneration(maxContext: 4095, maxReply: 300, temperature: 1);

  final int maxContext;
  final int maxReply;
  final double temperature;

  static TavernGeneration of(Map<String, Object?> preset) => TavernGeneration(
    maxContext: (preset['openai_max_context'] as num?)?.toInt() ?? standard.maxContext,
    maxReply: (preset['openai_max_tokens'] as num?)?.toInt() ?? standard.maxReply,
    temperature: (preset['temperature'] as num?)?.toDouble() ?? standard.temperature,
  );
}

class TavernGenerationController extends AsyncNotifier<TavernGeneration> {
  static const contextKey = 'openai_max_context';
  static const replyKey = 'openai_max_tokens';
  static const temperatureKey = 'temperature';

  @override
  Future<TavernGeneration> build() async => TavernGeneration.of(await _preset());

  /// The default preset as the engine has it: ST's own when none is set.
  Future<Map<String, Object?>> _preset() async {
    final settings = await ref.read(tavernProvider).readSettings();
    return switch (settings['preset']) {
      final Map<String, Object?> preset when preset.isNotEmpty => preset,
      _ => ChatPreset.stDefault().raw,
    };
  }

  Future<void> setMaxContext(int tokens) => _set(contextKey, tokens);
  Future<void> setMaxReply(int tokens) => _set(replyKey, tokens);
  Future<void> setTemperature(double value) => _set(temperatureKey, value);

  /// Writes the whole preset back with [key] changed: a preset the engine is
  /// given is all of it, so one field alone would lose the prompts.
  Future<void> _set(String key, Object value) async {
    final preset = {...await _preset(), key: value};
    state = AsyncData(TavernGeneration.of(preset));
    await ref.read(tavernProvider).setSettings({'preset': preset});
  }
}

final tavernGenerationProvider = AsyncNotifierProvider<TavernGenerationController, TavernGeneration>(
  TavernGenerationController.new,
);
