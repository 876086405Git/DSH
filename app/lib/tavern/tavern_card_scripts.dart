// The 酒馆助手 scripts that run in a chat (docs/design/roleplay-compat.md
// §8.3), as the engine chooses them: the global library's, the current
// preset's, then the card's — each in a hidden frame of the whole-story
// canvas — and what the canvas needs to know about the card itself.

import 'dart:convert';
import 'dart:isolate';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'tavern_provider.dart';
import 'tavern_script_wire.dart';

/// The scripts that run in a chat (its id, and the character chosen for it;
/// null for a group, which gets the global and preset ones), as they change.
final tavernChatScriptsProvider = StreamProvider.autoDispose.family<TavernChatScripts, (String, String?)>(
  (ref, chat) => ref.watch(tavernProvider).watchChatScripts(chat.$1, characterId: chat.$2),
);

/// [s] as the canvas page runs it: its key ([tavernScriptKey]), its own id
/// and name, its code, its owner as the wire gives it, and all its buttons.
Map<String, Object?> tavernScriptJson(TavernRunnableScript s) => {
  'key': tavernScriptKey(s.owner),
  'id': s.owner.scriptId,
  'name': s.name,
  'content': s.content,
  'owner': tavernScriptOwnerJson(s.owner),
  'buttonList': [for (final b in s.buttons) b.toJson()],
};

/// The buttons [s] shows over the composer, as its list has them.
List<String> tavernScriptButtons(TavernRunnableScript s) => [
  if (s.buttonsEnabled)
    for (final b in s.buttons)
      if (b.visible && b.name.isNotEmpty) b.name,
];

/// Whether [card] (its fields) uses MVU: it says so (extensions.dshgo.mvu),
/// or something in it — a script, a regex, a greeting — loads MagVarUpdate.
bool tavernUsesMvu(Map<String, Object?>? card) {
  if (card == null) return false;
  if (card['extensions'] case {'dshgo': {'mvu': {'enabled': true}}}) return true;
  // Its world book left out: often most of the card, and never what loads it.
  return jsonEncode({...card}..remove('character_book')).contains('MagVarUpdate');
}

const _bigCard = 256 * 1024;

/// A character's card as the engine exports it, its fields (V2/V3 data, or a
/// V1 card's top level); null when it cannot be read.
final tavernCardDataProvider = FutureProvider.autoDispose.family<Map<String, Object?>?, String>((
  ref,
  characterId,
) async {
  try {
    final bytes = await ref.watch(tavernProvider).exportCard(characterId, format: TavernCardFormat.json);
    // A big card (a world book of hundreds of entries) is megabytes of JSON:
    // read off the screen's thread.
    Map<String, Object?>? read() => tavernCardData(jsonDecode(utf8.decode(bytes)));
    return bytes.length > _bigCard ? await Isolate.run(read) : read();
  } on Object {
    return null;
  }
});

/// [card]'s fields: under data for V2/V3, else its top level; null for
/// something that is not a card.
Map<String, Object?>? tavernCardData(Object? card) {
  if (card is! Map<String, Object?>) return null;
  return switch (card['data']) {
    final Map<String, Object?> data => data,
    _ => card,
  };
}

/// Where it is kept, per chat, that the engine's MVU was turned on for it.
const tavernMvuOnKey = 'tavern.mvuOn.';

/// Where it is kept, per character, that the word over the composer about
/// its card's scripts waiting on 整页画布 was put away.
const tavernScriptsHintOffKey = 'tavern.scriptsHintOff.';

/// Whether that word was put away for [characterId]'s card: then it is not
/// said again, for any of its chats.
final tavernScriptsHintOffProvider = FutureProvider.autoDispose.family<bool, String>(
  (ref, characterId) async =>
      (await SharedPreferences.getInstance()).getBool('$tavernScriptsHintOffKey$characterId') ?? false,
);

/// Puts that word away for [characterId]'s card, for good.
Future<void> tavernPutScriptsHintAway(String characterId) async =>
    (await SharedPreferences.getInstance()).setBool('$tavernScriptsHintOffKey$characterId', true);
