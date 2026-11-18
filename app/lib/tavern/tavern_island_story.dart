// What a card's HTML in an island may read of the story (docs/design/
// roleplay-compat.md §5.3): a status bar asks its floor's variables
// (getVariables, MVU's Mvu.getMvuData) to draw them. Islands do not run the
// card's scripts or write anything — that is 整页画布's — but they read: each
// message's floor and variables and the chat's, as the engine has them, read
// afresh when the engine says something in the chat changed.

import 'dart:async';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'tavern_provider.dart';

/// One message as an island reads it.
typedef TavernIslandFloor = ({int floor, Map<String, Object?> data});

/// The chat as its islands read it: the messages along its path by node,
/// and the chat's own variables.
final class TavernIslandStory {
  const TavernIslandStory({required this.floors, required this.chat, required this.last});

  final Map<String, TavernIslandFloor> floors;
  final Map<String, Object?> chat;

  /// The latest floor's number (-1 for none) and variables.
  final ({int floor, Map<String, Object?> data}) last;

  factory TavernIslandStory.of(TavernScriptSnapshot s) {
    final floors = <String, TavernIslandFloor>{};
    var last = (floor: -1, data: const <String, Object?>{});
    for (final m in s.messages) {
      final floor = (floor: m.messageId, data: m.data ?? const <String, Object?>{});
      floors[m.ref.nodeId] = floor;
      for (final swipe in m.swipes) {
        floors[swipe.ref.nodeId] = (floor: floor.floor, data: swipe.data ?? const <String, Object?>{});
      }
      last = floor;
    }
    return TavernIslandStory(
      floors: floors,
      last: last,
      chat: {
        for (final v in s.variableSnapshots)
          if (v.resolvedTarget.scope == TavernVariableScope.chat) ...v.value,
      },
    );
  }

  /// What the island in [nodeId]'s message is told (its page's
  /// TavernIslandStory script): its floor, its variables, the latest's, the
  /// chat's, and its words; null for a message not on the path.
  Map<String, Object?>? forMessage(String nodeId, {required String text, required String name, required bool user}) {
    final at = floors[nodeId];
    if (at == null) return null;
    return {
      'messageId': at.floor,
      'last': last.floor,
      'data': at.data,
      'latest': last.data,
      'chat': chat,
      'message': text,
      'name': name,
      'role': user ? 'user' : 'assistant',
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
