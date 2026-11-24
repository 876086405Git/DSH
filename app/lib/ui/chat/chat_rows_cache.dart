import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart';

import '../../state/artifacts.dart';
import '../../state/chat_state.dart';
import 'chat_rows.dart';
import 'tool_view.dart' show ToolCardPlacement;

/// Keeps historical row objects and their key index while a draft streams
/// (reply text, thinking, a tool call's arguments). Structural changes still
/// go through [deriveRows], including a draft commit, tool update, history
/// page, turn completion, or changed pending cards.
class ChatRowsCache {
  ChatState? _state;
  bool _foldTurns = false;
  bool _compactTools = false;
  List<TurnArtifacts> _artifacts = const [];
  List<ChatRow> _rows = const [];
  Map<String, int> _index = const {};

  Map<String, int> get index => _index;

  /// The last [update] changed nothing but the streaming draft's row: every
  /// other row object is the one it was, and so is everything they show.
  bool get onlyDraftChanged => _unchangedPrefix != null;

  /// On a draft-only update, the rows before this index keep their identities.
  int? get unchangedPrefix => _unchangedPrefix;
  int? _unchangedPrefix;

  List<ChatRow> update(
    ChatState state, {
    required bool foldTurns,
    List<TurnArtifacts> artifacts = const [],
    bool compactTools = false,
  }) {
    final previous = _state;
    List<ChatRow>? reused;
    if (previous != null &&
        foldTurns == _foldTurns &&
        compactTools == _compactTools &&
        listEquals(artifacts, _artifacts) &&
        state.running == previous.running &&
        listEquals(state.approvals, previous.approvals) &&
        listEquals(state.questions, previous.questions) &&
        listEquals(state.pending, previous.pending) &&
        setEquals(state.autoAnswered, previous.autoAnswered) &&
        listEquals(state.commands, previous.commands) &&
        listEquals(state.turns, previous.turns)) {
      reused = _reuseTail(previous.items, state.items, running: state.running);
    }
    _state = state;
    _foldTurns = foldTurns;
    _compactTools = compactTools;
    _artifacts = artifacts;
    if (reused != null) {
      _rows = reused;
    } else {
      _unchangedPrefix = null;
      _rows = deriveRows(
        items: state.items,
        approvals: state.approvals,
        questions: state.questions,
        pending: state.pending,
        running: state.running,
        autoAnswered: state.autoAnswered,
        commands: state.commands,
        turns: state.turns,
        foldTurns: foldTurns,
        artifacts: artifacts,
        compactTools: compactTools,
      );
      _index = {for (var i = 0; i < _rows.length; i++) _rows[i].key: i};
    }
    return _rows;
  }

  List<ChatRow>? _reuseTail(List<ChatItem> previous, List<ChatItem> items, {required bool running}) {
    if (identical(previous, items)) {
      // A cached live projection is the same unchanged draft the value check
      // below used to find. Keep its historical widgets across status updates.
      _unchangedPrefix = running && items.isNotEmpty && _isDraft(items.last) ? _rows.length : null;
      return _rows;
    }
    if (previous.length != items.length) return null;
    // The transcript reuses durable ChatItems across deltas and makes the
    // streaming draft's items (no seq yet, at the end) anew when they change.
    // Check every item: a matching last key alone cannot detect a history edit.
    var start = 0;
    while (start < items.length && identical(previous[start], items[start])) {
      start++;
    }
    if (start == items.length) {
      _unchangedPrefix = null;
      return _rows;
    }
    if (!running) return null;
    var rows = _rows;
    _unchangedPrefix = rows.length;
    for (var i = start; i < items.length; i++) {
      final before = previous[i];
      final after = items[i];
      if (!_isDraft(before) || !_isDraft(after) || before.key != after.key) return null;
      // Made anew but the same: the row keeps the item it has.
      if (_sameDraft(before, after)) continue;
      final next = _replaceDraft(rows, before, after);
      if (next == null) return null;
      rows = next;
    }
    return rows;
  }

  /// A streaming reply or a tool call whose arguments are still coming.
  static bool _isDraft(ChatItem item) => switch (item) {
    AssistantChatItem(:final seq, :final streaming) => seq == null && streaming,
    ToolChatItem(:final seq, :final status) =>
      seq == null &&
          (status == ToolStatus.streaming || status == ToolStatus.running) &&
          item.resultParts.isEmpty &&
          item.meta == null &&
          item.pendingApproval == null,
    _ => false,
  };

  /// What a draft is made of ([ChatTranscript] gives drafts nothing else).
  static bool _sameDraft(ChatItem a, ChatItem b) => switch ((a, b)) {
    (final AssistantChatItem a, final AssistantChatItem b) =>
      a.id == b.id && a.key == b.key && a.text == b.text && a.reasoning == b.reasoning && a.streaming == b.streaming,
    (final ToolChatItem a, final ToolChatItem b) =>
      a.callId == b.callId && a.name == b.name && a.arguments == b.arguments && a.status == b.status,
    _ => false,
  };

  /// [rows] with the row showing draft [before] showing [after] instead, or
  /// null when that row is not a plain draft row. Running drafts are not
  /// folded, given a copy action or a card (a draft call has no result yet),
  /// and the number of calls in a run is unchanged: nothing else moves.
  List<ChatRow>? _replaceDraft(List<ChatRow> rows, ChatItem before, ChatItem after) {
    final at = _index[before.key];
    if (at != null) {
      if (at < _unchangedPrefix!) _unchangedPrefix = at;
      switch ((rows[at], after)) {
        case (final AssistantRow row, final AssistantChatItem after)
            when !row.showActions && row.footnote == null && _sameDraft(row.item, before):
          return [...rows]..[at] = AssistantRow(after);
        case (final ToolCallRow row, final ToolChatItem after)
            when row.card == ToolCardPlacement.inline && _sameDraft(row.item, before):
          return [...rows]..[at] = ToolCallRow(after);
        default:
          return null;
      }
    }
    // A call in a run of three or more: its group (live, at the end).
    if (after is! ToolChatItem) return null;
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i] case final ToolGroupRow group) {
        final j = group.tools.indexWhere((tool) => tool.key == before.key);
        // Another group (an earlier run of calls) may hold the draft.
        if (j < 0) continue;
        if (!_sameDraft(group.tools[j], before)) return null;
        if (i < _unchangedPrefix!) _unchangedPrefix = i;
        final tools = [...group.tools]..[j] = after;
        return [...rows]..[i] = ToolGroupRow(tools, live: group.live);
      }
    }
    return null;
  }
}
