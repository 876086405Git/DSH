// The app's one [Tavern]: the engine (packages/dsh_tavern) opened on
// `<app support>/tavern`. It opens asynchronously, so the screens get a
// [DeferredTavern] that queues calls until it is ready. It follows 酒馆设置's
// channel and reads that channel's key (the app's DeepSeek key for the
// built-in one) on every call; the engine never stores a key. Tests swap in
// the preview stand-in (tavern_preview.dart).

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../state/settings_state.dart';
import '../usage/usage_stats.dart';
import 'deferred_tavern.dart';
import 'tavern_channels.dart';
import 'tavern_script_host.dart';
import 'tavern_settings.dart';

final tavernProvider = Provider<Tavern>((ref) {
  final tavern = DeferredTavern(() async {
    final support = await getApplicationSupportDirectory();
    return TavernEngine.open(
      support,
      modelClient: TavernModelClient(
        onUsageSettled: (report, {required partial}) {
          if (!ref.mounted) return;
          final fields = report?.fields;
          Object? read(String key) => switch (fields?[key]) {
            {'state': 'invalid'} => -1,
            {'state': 'reported', 'value': final int value} => value,
            _ => null,
          };
          ref.read(usageStatsProvider.notifier).tokenUsage(UsageTokenSource.tavern, {
            // Chat Completions prompt_tokens already includes cache hits.
            'inputTokens': read('prompt_tokens'),
            'outputTokens': read('completion_tokens'),
          }, partial: partial);
        },
      ),
    );
  }());
  ref.onDispose(tavern.close);
  final keys = ref.read(tavernChannelKeysProvider);
  void configure(TavernSettings settings) =>
      tavern.configure(tavernModelConfig(settings, appKey: () => ref.read(settingsProvider).apiKey, keys: keys));
  configure(ref.read(tavernSettingsProvider));
  ref.listen(tavernSettingsProvider, (_, next) => configure(next));
  return tavern;
});

/// What the engine talks to under [settings]: the channel in use, and the
/// 辅助模型 when one is chosen. Each key is read on every call, the built-in
/// channel's from the app's settings ([appKey]).
TavernModelConfig tavernModelConfig(
  TavernSettings settings, {
  required String Function() appKey,
  required TavernChannelKeys keys,
}) {
  // DeepSeek's own (null) or an added channel.
  TavernModelConfig config(
    TavernChannel? channel,
    String model, {
    bool thinking = false,
    TavernModelConfig? auxiliary,
  }) => TavernModelConfig(
    apiKey: () async {
      final key = (channel == null ? appKey() : await keys.read(channel.id))?.trim();
      return key == null || key.isEmpty ? null : key;
    },
    baseUrl: channel?.baseUrl ?? tavernDeepSeekBaseUrl,
    model: model,
    deepseek: channel?.deepseek ?? true,
    thinking: thinking,
    headers: channel?.headers ?? const {},
    auxiliary: auxiliary,
  );
  final helper = settings.auxiliaryChannel;
  return config(
    settings.activeChannel,
    settings.activeModel,
    thinking: settings.thinking,
    // 辅助模型: thinking off, as the engine's own choice has it.
    auxiliary: switch (settings.auxiliary) {
      tavernAuxiliaryDeepSeek => config(null, tavernModels.first),
      _ when helper != null => config(helper, helper.model),
      _ => null,
    },
  );
}

/// The app's host for card scripts, one per tavern: what the engine delivers
/// to a canvas page's script context goes to that page.
final tavernScriptPagesProvider = Provider<TavernScriptPages>((ref) {
  ref.watch(tavernProvider);
  return TavernScriptPages();
});

/// Every character, as the library lists them.
final tavernCharactersProvider = StreamProvider<List<TavernCharacter>>(
  (ref) => ref.watch(tavernProvider).watchCharacters(),
);

/// One character in full. The list carries only what a card in the grid
/// shows; greetings, the definition and the creator's notes come from here,
/// read again whenever the list changes (an edit, a re-import).
final tavernCharacterDetailProvider = FutureProvider.autoDispose.family<TavernCharacter?, String>((ref, id) {
  ref.watch(tavernCharactersProvider);
  return ref.watch(tavernProvider).character(id);
});

/// Chats, newest first; one character's when the argument is its id.
final tavernChatsProvider = StreamProvider.family<List<TavernChatSummary>, String?>(
  (ref, characterId) => ref.watch(tavernProvider).watchChats(characterId: characterId),
);

/// Saved personas (人设).
final tavernPersonasProvider = StreamProvider<List<TavernPersona>>((ref) => ref.watch(tavernProvider).watchPersonas());

/// Who you are in a chat (null: outside any chat, just the default). Read
/// again whenever the personas notify, which default and binding changes do.
final tavernPersonaSelectionProvider = FutureProvider.family<PersonaSelection, String?>((ref, chatId) {
  ref.watch(tavernPersonasProvider);
  return ref.watch(tavernProvider).personaSelection(chatId: chatId);
});

/// No reply can be asked for until a key is in: only DeepSeek's own channel
/// needs the app's key; an added one brings its own (or needs none).
final tavernNeedsKeyProvider = Provider<bool>(
  (ref) =>
      ref.watch(tavernSettingsProvider.select((s) => s.activeChannel == null)) &&
      !ref.watch(settingsProvider.select((s) => s.hasApiKey)),
);
