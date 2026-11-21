import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../clipboard/binary_text.dart';
import 'attachments.dart';

/// What is in the composer of one conversation and not sent yet.
class ChatDraft {
  const ChatDraft({this.text = '', this.attachments = const [], required this.updatedAt});

  final String text;
  final List<DraftAttachment> attachments;
  final DateTime updatedAt;
}

class DraftState {
  const DraftState({this.drafts = const {}, this.loaded = false});

  /// By session id; `new` is the new-chat screen.
  final Map<String, ChatDraft> drafts;

  /// The saved texts are in (they arrive a moment after launch).
  final bool loaded;
}

/// Composer drafts per conversation. The text of the latest 30 survives a
/// restart; attachments only live as long as the app.
class DraftStore extends Notifier<DraftState> {
  static const preferenceKey = 'chat_drafts_v1';
  static const limit = 30;

  Timer? _write;
  final _forgotten = <String>{};
  late Future<void> _restored;

  @override
  DraftState build() {
    ref.onDispose(() => _write?.cancel());
    _restored = _restore();
    return const DraftState();
  }

  Future<void> _restore() async {
    final restored = <String, ChatDraft>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(preferenceKey);
      if (raw != null) {
        for (final MapEntry(:key, :value) in (jsonDecode(raw) as Map).entries) {
          // A picture pasted as its bytes (#1684) is no one's draft, and put
          // back in the composer it costs the launch: keep what was typed.
          var text = value['t'] as String;
          if (looksLikeBytes(text)) text = typedBeforeBytes(text);
          if (text.isEmpty) continue;
          restored[key as String] = ChatDraft(
            text: text,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(value['at'] as int),
          );
        }
      }
    } catch (_) {
      // No preferences backend (tests) or an unreadable value: start empty.
    }
    if (!ref.mounted) return;
    // Anything typed before the load finished wins.
    state = DraftState(
      drafts: _latest({...restored, ...state.drafts}..removeWhere((key, _) => _forgotten.contains(key))),
      loaded: true,
    );
  }

  Map<String, ChatDraft> _latest(Map<String, ChatDraft> drafts) {
    final entries = drafts.entries.toList()..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    return Map.unmodifiable(Map.fromEntries(entries.take(limit)));
  }

  /// Empty text and no attachments drops the slot.
  void save(String key, String text, List<DraftAttachment> attachments) {
    if (_forgotten.contains(key)) return;
    final current = state.drafts[key];
    if ((current?.text ?? '') == text && listEquals(current?.attachments ?? const [], attachments)) {
      return;
    }
    final next = {...state.drafts};
    if (text.isEmpty && attachments.isEmpty) {
      next.remove(key);
    } else {
      next[key] = ChatDraft(text: text, attachments: List.unmodifiable(attachments), updatedAt: DateTime.now());
    }
    state = DraftState(drafts: _latest(next), loaded: state.loaded);
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  void clear(String key) => save(key, '', const []);

  /// A deleted session cannot regain a draft through a late preferences load
  /// or the outgoing chat screen's save-on-selection/dispose callback.
  void forget(String key) {
    _forgotten.add(key);
    state = DraftState(drafts: Map.unmodifiable({...state.drafts}..remove(key)), loaded: state.loaded);
    _write?.cancel();
    _write = Timer(const Duration(milliseconds: 400), () => unawaited(flush()));
  }

  /// Writes the texts now (also done 400 ms after the last change).
  Future<void> flush() async {
    _write?.cancel();
    _write = null;
    // Writing before the saved drafts are in would drop them.
    await _restored;
    if (!ref.mounted) return;
    final json = jsonEncode({
      for (final MapEntry(:key, :value) in state.drafts.entries)
        if (value.text.isNotEmpty) key: {'t': value.text, 'at': value.updatedAt.millisecondsSinceEpoch},
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(preferenceKey, json);
    } catch (_) {}
  }
}

final draftStoreProvider = NotifierProvider<DraftStore, DraftState>(DraftStore.new);
