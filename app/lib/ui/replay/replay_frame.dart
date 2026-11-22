// A shared conversation at one moment of its replay, as the chat's own items
// (ChatItem, TurnTrace, CommandNotice), so the replay is drawn by the chat's
// row widgets and looks like the conversation did.

import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../../share_code/conversation_share.dart';
import '../../state/chat_state.dart' show CommandNotice;
import 'replay_timeline.dart';

/// The parts of a conversation visible at one replay time.
class ReplayFrame {
  const ReplayFrame({
    required this.items,
    required this.turns,
    required this.commands,
    required this.todos,
    required this.goal,
    required this.running,
    required this.visible,
  });

  final List<ChatItem> items;
  final List<TurnTrace> turns;
  final List<CommandNotice> commands;

  /// The todo list at that time (DSH's projection rules), null when none.
  final List<TodoItem>? todos;

  /// The goal at that time, null when none.
  final GoalEntry? goal;

  /// A turn is going on.
  final bool running;

  /// How many entries have appeared.
  final int visible;
}

/// Builds [ReplayFrame]s of one conversation. Finished parts are built once
/// and reused, so unchanged rows keep their identity from frame to frame.
class ReplayFrames {
  ReplayFrames(this.share) : timeline = ReplayTimeline.of(share.entries);

  final ConversationShare share;
  final ReplayTimeline timeline;
  final _wideRunes = <(int, bool), List<int>>{};

  final Map<int, ChatItem> _done = {};
  final Map<int, TurnTrace> _open = {};
  final Map<int, TurnTrace> _closed = {};
  final Map<int, ToolChatItem> _runningTools = {};

  /// The sequence number entry [i] gets (turns start just before their
  /// prompt; room for a turn's end after its last part).
  static int seqOf(int i) => (i + 1) * 4;

  /// Attachment ids of shared pictures are their asset ids.
  static String imageKey(String assetId) => assetId;

  ReplayFrame at(double time) {
    final entries = share.entries;
    final beats = timeline.beats;
    final visible = timeline.visibleAt(time);
    final items = <ChatItem>[];
    final commands = <CommandNotice>[];
    final turns = <TurnTrace>[];
    TodosEntry? todoSource;
    GoalEntry? goal;
    var running = false;
    for (var i = 0; i < visible; i++) {
      final entry = entries[i];
      final beat = beats[i];
      final done = time >= beat.end;
      switch (entry) {
        case TurnEntry():
          todoSource = null;
          final end = timeline.turnEnds[i];
          final closed = end != null && time >= end;
          if (!closed) running = true;
          final traces = closed ? _closed : _open;
          turns.add(traces[i] ??= _trace(i, entry, done: closed));
        case UserEntry():
          items.add(_done[i] ??= _user(i, entry));
        case ReplyEntry():
          items.add(
            done ? (_done[i] ??= _reply(i, entry, beat, time, done: true)) : _reply(i, entry, beat, time, done: false),
          );
        case ToolEntry():
          items.add(
            done ? (_done[i] ??= _tool(i, entry, done: true)) : (_runningTools[i] ??= _tool(i, entry, done: false)),
          );
        case NoticeEntry():
          items.add(_done[i] ??= NoticeChatItem(seq: seqOf(i), kind: entry.kind, text: entry.text));
        case CommandEntry():
          commands.add(_command(i, entry));
        case TodosEntry():
          todoSource = entry;
        case GoalEntry():
          goal = entry.text == null ? null : entry;
      }
    }
    return ReplayFrame(
      items: items,
      turns: turns,
      commands: commands,
      todos: todoSource == null ? null : [for (final item in todoSource.items) TodoItem(item.text, item.status)],
      goal: goal,
      running: running,
      visible: visible,
    );
  }

  /// Elapsed time in the original conversation, before replay pacing.
  late final Duration originalSpan = share.span;

  /// The whole conversation, everything finished.
  ReplayFrame get end => at(double.infinity);

  DateTime _time(int i) => share.start.add(Duration(milliseconds: share.entries[i].t));

  UserChatItem _user(int i, UserEntry e) => UserChatItem(
    seq: seqOf(i),
    time: _time(i),
    text: e.text,
    images: [
      for (final image in e.images)
        ImageAttachment(
          attachmentId: imageKey(image.id),
          mediaType: 'image/jpeg',
          width: image.width,
          height: image.height,
          name: image.name,
        ),
    ],
    files: [for (final f in e.files) FileAttachment(name: f.name, bytes: f.size)],
    sourceKind: e.source ?? 'user',
  );

  AssistantChatItem _reply(int i, ReplyEntry e, ReplayBeat beat, double time, {required bool done}) {
    var reasoning = e.thinking ?? '';
    var text = e.text;
    if (!done) {
      if (time < beat.thinkEnd) {
        reasoning = _prefix((i, true), reasoning, (time - beat.start) / (beat.thinkEnd - beat.start));
        text = '';
      } else {
        final span = beat.end - beat.thinkEnd;
        text = _prefix((i, false), text, span <= 0 ? 1 : (time - beat.thinkEnd) / span);
      }
    }
    return AssistantChatItem(
      id: 'a${seqOf(i)}',
      seq: seqOf(i),
      time: _time(i),
      text: text,
      reasoning: reasoning,
      streaming: !done,
      interrupted: done && e.interrupted,
      model: e.model,
    );
  }

  ToolChatItem _tool(int i, ToolEntry e, {required bool done}) {
    final failed = e.status == ToolOutcome.failed || e.status == ToolOutcome.denied;
    return ToolChatItem(
      callId: 'c${seqOf(i)}',
      name: e.name,
      arguments: jsonEncode(e.args),
      seq: seqOf(i),
      status: !done
          ? ToolStatus.running
          : switch (e.status) {
              ToolOutcome.ok => ToolStatus.succeeded,
              ToolOutcome.failed => ToolStatus.failed,
              ToolOutcome.denied => ToolStatus.denied,
              ToolOutcome.cancelled => ToolStatus.cancelled,
            },
      resultParts: done && e.result != null ? [TextPart(e.result!)] : const [],
      failure: done && failed && e.error != null ? ToolFailure(e.name, 'ERROR', e.error) : null,
    );
  }

  CommandNotice _command(int i, CommandEntry e) {
    final line = e.line.startsWith('/') ? e.line.substring(1) : e.line;
    final space = line.indexOf(' ');
    return CommandNotice(
      id: 'r${seqOf(i)}',
      name: space < 0 ? line : line.substring(0, space),
      args: space < 0 ? null : line.substring(space),
      seq: seqOf(i),
      done: true,
      success: e.ok,
      text: e.text,
    );
  }

  TurnTrace _trace(int i, TurnEntry e, {required bool done}) {
    final start = _time(i);
    // The turn's parts: up to the next turn.
    var last = i;
    if (done) {
      for (var j = i + 1; j < share.entries.length && share.entries[j] is! TurnEntry; j++) {
        if (e.d != null && share.entries[j].t > e.t + e.d!) break;
        last = j;
      }
    }
    final steps = e.steps ?? 0;
    return TurnTrace(
      turn: i,
      startSeq: seqOf(i),
      start: start,
      endSeq: done ? seqOf(last) + 2 : null,
      end: done && e.d != null ? start.add(Duration(milliseconds: e.d!)) : null,
      endReason: done ? TurnEndReason(e.end ?? 'completed') : null,
      spans: [
        for (var s = 0; s < steps; s++)
          TraceSpan(
            kind: TraceKind.model,
            step: s + 1,
            seq: seqOf(i) + 1,
            start: start,
            end: start,
            usage: s == 0 && e.tokens != null ? TokenUsage(inputTokens: e.tokens!, outputTokens: 0) : null,
          ),
      ],
    );
  }

  /// The first [fraction] of [text], by characters (never half a character).
  String _prefix((int, bool) part, String text, double fraction) {
    if (fraction >= 1) return text;
    if (fraction <= 0 || text.isEmpty) return '';
    final wide = _wideRunes.putIfAbsent(part, () {
      final positions = <int>[];
      var index = 0;
      for (final rune in text.runes) {
        if (rune > 0xffff) positions.add(index);
        index++;
      }
      return positions;
    });
    final n = ((text.length - wide.length) * fraction).floor();
    // Each two-unit rune before the boundary adds one UTF-16 code unit.
    var lo = 0;
    var hi = wide.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (wide[mid] < n) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return text.substring(0, n + lo);
  }
}
