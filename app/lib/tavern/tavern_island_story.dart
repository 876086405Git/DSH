// What a card's HTML in an island may read of the story (docs/design/
// roleplay-compat.md §5.3): a status bar asks its floor's variables
// (getVariables, getAllVariables, MVU's Mvu.getMvuData) to draw them, a
// styled story reads its floor's words (getChatMessages, SillyTavern's
// chat). Islands do not run the card's scripts or write anything — that is
// 整页画布's — but they read: each message's floor and variables, the
// chat's, the character's and the global ones, as the engine has them, read
// afresh when the engine says something in the chat changed.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tavern_provider.dart';

/// One message as an island reads it.
typedef TavernIslandFloor = ({int floor, Map<String, Object?> data});

/// One floor as an island's getChatMessages gives it: who, its words, its
/// variables.
typedef TavernIslandWords = ({String name, String role, bool hidden, String message, Map<String, Object?> data});

/// The chat as its islands read it: the messages along its path by node,
/// and the chat's own variables.
final class TavernIslandStory {
  const TavernIslandStory({
    required this.floors,
    required this.chat,
    required this.last,
    this.words = const {},
    this.global = const {},
    this.character = const {},
    this.characterName = '',
    this.characterId,
  });

  final Map<String, TavernIslandFloor> floors;
  final Map<String, Object?> chat;

  /// The latest floor's number (-1 for none) and variables.
  final ({int floor, Map<String, Object?> data}) last;

  /// Each floor's words, by its number.
  final Map<int, TavernIslandWords> words;

  /// The global and the character's variables.
  final Map<String, Object?> global, character;

  /// The chat's character (SillyTavern's name2), and its id; none for a group.
  final String characterName;
  final String? characterId;

  factory TavernIslandStory.of(TavernScriptSnapshot s) {
    final floors = <String, TavernIslandFloor>{};
    final words = <int, TavernIslandWords>{};
    var last = (floor: -1, data: const <String, Object?>{});
    var characterName = '';
    for (final m in s.messages) {
      final floor = (floor: m.messageId, data: m.data ?? const <String, Object?>{});
      floors[m.ref.nodeId] = floor;
      for (final swipe in m.swipes) {
        floors[swipe.ref.nodeId] = (floor: floor.floor, data: swipe.data ?? const <String, Object?>{});
      }
      words[m.messageId] = (name: m.name, role: m.role.name, hidden: m.hidden, message: m.message, data: floor.data);
      if (m.role == TavernScriptRole.assistant) characterName = m.name;
      last = floor;
    }
    Map<String, Object?> scope(TavernVariableScope scope) => {
      for (final v in s.variableSnapshots)
        if (v.resolvedTarget.scope == scope) ...v.value,
    };
    return TavernIslandStory(
      floors: floors,
      last: last,
      words: words,
      chat: scope(TavernVariableScope.chat),
      global: scope(TavernVariableScope.global),
      character: scope(TavernVariableScope.character),
      characterName: characterName,
      characterId: s.memberCharacterIds.length == 1 ? s.memberCharacterIds.single : null,
    );
  }

  /// What the island in [nodeId]'s message is told (its page's
  /// TavernIslandStory script): its floor, its variables, the latest's, the
  /// chat's, the character's and the global ones, its words, and the words
  /// of the floors it may read — its own, the first and the latest (each
  /// with its variables); [persona] is the reader's name (name1). Null for a
  /// message not on the path.
  Map<String, Object?>? forMessage(
    String nodeId, {
    required String text,
    required String name,
    required bool user,
    String persona = '',
    String? chatId,
  }) {
    final at = floors[nodeId];
    if (at == null) return null;
    Map<String, Object?> floor(TavernIslandWords w) => {
      'name': w.name,
      'role': w.role,
      'is_hidden': w.hidden,
      'message': w.message,
      'data': w.data,
    };
    final role = user ? 'user' : 'assistant';
    return {
      'messageId': at.floor,
      'last': last.floor,
      'data': at.data,
      'latest': last.data,
      'chat': chat,
      'global': global,
      'character': character,
      'message': text,
      'name': name,
      'role': role,
      'name1': persona,
      'name2': characterName,
      'characterId': characterId,
      'chatId': chatId,
      'floors': {
        for (final n in {0, last.floor})
          if (words[n] case final w? when n != at.floor) '$n': floor(w),
        '${at.floor}': floor((name: name, role: role, hidden: false, message: text, data: at.data)),
      },
    };
  }
}

/// The story of [chatId] as its islands read it, kept current. Through a
/// script context of its own, closed when no island reads any more.
final tavernIslandStoryProvider = StreamProvider.autoDispose.family<TavernIslandStory, String>((ref, chatId) {
  final scripts = ref.watch(tavernProvider).scripts;
  final out = StreamController<TavernIslandStory>();
  Future<String>? context;
  Timer? again;
  var reading = false, stale = false;
  Future<void> read() async {
    if (reading) {
      stale = true;
      return;
    }
    reading = true;
    try {
      final id = await (context ??= scripts
          .openContext(TavernScriptContextSpec(instanceId: 'islands', chatId: chatId))
          .then((c) => c.id));
      final snapshot = await scripts.snapshot(id);
      if (!out.isClosed) out.add(TavernIslandStory.of(snapshot));
    } on Object catch (e, stack) {
      final opened = context;
      context = null;
      if (opened != null) unawaited(opened.then(scripts.closeContext).catchError((_) {}));
      if (!out.isClosed) out.addError(e, stack);
    } finally {
      reading = false;
    }
    if (stale && !out.isClosed) {
      stale = false;
      await read();
    }
  }

  unawaited(read());
  // The engine telling anything in the chat: read again, once it settles.
  final events = scripts.watchEvents(chatId: chatId).listen((_) {
    again?.cancel();
    again = Timer(const Duration(milliseconds: 250), () => unawaited(read()));
  });
  ref.onDispose(() {
    again?.cancel();
    unawaited(events.cancel());
    unawaited(out.close());
    final opened = context;
    if (opened != null) unawaited(opened.then(scripts.closeContext).catchError((_) {}));
  });
  return out.stream;
});
