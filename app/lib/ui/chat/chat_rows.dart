// The row model between DSH ChatItems and the chat list.

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../state/artifacts.dart';
import '../../state/chat_state.dart';
import 'tool_view.dart';
import 'turn_summary.dart';

/// 消息列表的一行。由 [deriveRows] 从 transcript 派生。
sealed class ChatRow {
  const ChatRow();

  /// 稳定主键(列表 diff、视口锚定都靠它)。
  String get key;

  /// 用作视口分界锚点的候选:内容不会再被合并 / 替换的行。
  bool get stable => false;
}

final class UserRow extends ChatRow {
  const UserRow(this.item);
  final UserChatItem item;

  /// The optimistic bubble's key once echoed: the row keeps its element, so
  /// the bubble eases from "发送中" into place instead of being swapped.
  @override
  String get key => switch (item.requestId) {
    final id? => 'p$id',
    null => item.key,
  };
  @override
  bool get stable => true;
}

/// 本机刚发出、DSH 还没回显的消息。
final class PendingRow extends ChatRow {
  const PendingRow(this.prompt);
  final PendingPrompt prompt;
  @override
  String get key => 'p${prompt.requestId}';
}

final class AssistantRow extends ChatRow {
  const AssistantRow(this.item, {this.showActions = false, this.footnote});
  final AssistantChatItem item;

  /// 一轮的最后一条助手正文:下面挂复制键。
  final bool showActions;

  /// 这一轮在这里结束:操作行右端挂回合脚注(用时、步数……)。
  final TurnTrace? footnote;
  @override
  String get key => item.key;
  @override
  bool get stable => !item.streaming && item.seq != null;
}

final class ToolCallRow extends ChatRow {
  const ToolCallRow(this.item, {this.card = ToolCardPlacement.inline});
  final ToolChatItem item;

  /// 带原生卡片时卡片画在哪;不带卡片的调用永远是 inline。
  /// 折叠后外露的卡片沿用这次调用的主键:同一个元素从「工具行 + 卡片」
  /// 变成「只有卡片」,不当新内容播入场。
  final ToolCardPlacement card;
  @override
  String get key => item.key;
}

/// 连续 ≥ [toolGroupThreshold] 次工具调用收成一组。
final class ToolGroupRow extends ChatRow {
  const ToolGroupRow(this.tools, {this.live = false});
  final List<ToolChatItem> tools;
  final bool live;
  @override
  String get key => 'g${tools.first.key}';
}

final class NoticeRowData extends ChatRow {
  const NoticeRowData(this.item);
  final NoticeChatItem item;
  @override
  String get key => item.key;
  @override
  bool get stable => true;
}

/// 没挂在任何可见工具行上的审批(asker 没给 callId,或工具行还没出现)。
final class ApprovalRow extends ChatRow {
  const ApprovalRow(this.request);
  final ApprovalRequest request;
  @override
  String get key => 'ap${request.eventId}';
}

final class QuestionRow extends ChatRow {
  const QuestionRow(this.request);
  final UserQuestionRequest request;
  @override
  String get key => 'q${request.eventId}';
}

/// 一轮结束时的改动卡:这一轮改了哪些文件,各自 +/−。
final class ChangeCardRow extends ChatRow {
  const ChangeCardRow(this.files, {required this.anchor});
  final List<FileChange> files;

  /// 这一轮第一个改动工具的 callId(稳定主键)。
  final String anchor;
  @override
  String get key => 'chg$anchor';
}

/// 一轮结束时的产物卡:这一轮交付(`present`)或生成的文件(见
/// `state/artifacts.dart`)。接在改动卡后面,留在整轮折叠外面。
final class ArtifactCardRow extends ChatRow {
  const ArtifactCardRow(this.group);
  final TurnArtifacts group;
  @override
  String get key => 'art${group.endSeq}';
}

/// 正常结束的一轮:思考、工具调用和中间消息收成一行摘要,最终回答留在
/// 外面(官方 Web 的 foldCompletedTurns)。点开后 [rows] 长在这一行里面。
/// 被停下、出错的轮不收,停在哪一步要一眼看得到。
///
/// 运行中插话把一轮切成几片时,每一片各收一行:插话之前的片 [cut] 是那条
/// 插话的 seq,最后一片(带最终回答和脚注)[cut] 为 null。
final class TurnProcessRow extends ChatRow {
  const TurnProcessRow(this.trace, this.rows, {required this.toolCalls, required this.messages, this.cut});
  final TurnTrace trace;
  final List<ChatRow> rows;

  /// 收进来的工具调用次数。
  final int toolCalls;

  /// 收进来的、有正文的助手消息条数。
  final int messages;

  /// 这一片结束在哪条插话(用户消息的 seq);一轮的最后一片为 null。
  final int? cut;

  /// 最后一片沿用 `tp<轮起点>`(列表的收起动画、展开状态都按它认);
  /// 插话之前的片再带上插话的 seq,各片互不相串。
  @override
  String get key => switch (cut) {
    final seq? => 'tp${trace.startSeq}@$seq',
    null => 'tp${trace.startSeq}',
  };
  @override
  bool get stable => true;
}

/// 结束的一轮没有可挂脚注的回复(出错、被停下、只有工具调用):
/// 脚注单独占一行。
final class TurnFootnoteRow extends ChatRow {
  const TurnFootnoteRow(this.trace);
  final TurnTrace trace;
  @override
  String get key => 'ft${trace.startSeq}';
  @override
  bool get stable => true;
}

/// 斜杠指令的执行记录(`command/run` + `command/done`,或本机刚发出的)。
final class CommandNoticeRow extends ChatRow {
  const CommandNoticeRow(this.notice);
  final CommandNotice notice;
  @override
  String get key => notice.key;
  @override
  bool get stable => notice.done && notice.seq != null;
}

const toolGroupThreshold = 3;

/// How many times [deriveRows] ran: the streaming guard tests count it.
@visibleForTesting
int debugDeriveRowsCount = 0;

/// 把 transcript 折成列表行:
/// - 按 seq 把内容分到 [turns] 的各轮(`turn/start` 到 `turn/end`);一段
///   (两条用户消息之间)里挤了几轮(自动触发的轮、目标轮次、后台任务回调)
///   就各轮分开收尾;运行中插话把一轮切成几片,插话之前的片也各自收尾;
/// - 连续 ≥ 3 次工具调用合成 [ToolGroupRow];带原生卡片的调用不进组,
///   把连续的调用切开(卡片默认展开,不能藏在组里);
/// - 每一片最后一条助手正文标记 `showActions`(轮未结束、后面也没有插话
///   则不标);
/// - 改了文件的轮,在这一轮内容之后接一张 [ChangeCardRow];有 [artifacts]
///   的轮再接一张 [ArtifactCardRow](按 `turn/end` 对位);
/// - 结束了的轮带回合脚注:挂在这一轮最后一条回复的操作行上,没有这样的
///   回复时单独一行 [TurnFootnoteRow];
/// - [foldTurns] 时,正常结束的一轮每一片把过程收进一行 [TurnProcessRow]:
///   最后一片留最终回答,插话之前的片留它最后说的那句话(回答自己的思考也
///   收进去);用户消息不会被收进去;带原生卡片的调用,工具行收进去、卡片
///   本身留在外面(接在过程行后面);
/// - 斜杠指令按 seq 插进它执行时的位置,本机还没落盘的接在末尾;
/// - 被中断的助手正文后面那条"已停止"提示省掉(正文末尾已有标记);
/// - 游离的审批、提问卡、未回显的乐观消息依次接在末尾(等待中由输入条上的
///   胶囊表示,列表里不插三点:它在步骤之间忽隐忽现,整列跟着跳);
///   已被"本对话都允许"自动放行的审批不再单独出卡片。
List<ChatRow> deriveRows({
  required List<ChatItem> items,
  List<ApprovalRequest> approvals = const [],
  List<UserQuestionRequest> questions = const [],
  List<PendingPrompt> pending = const [],
  bool running = false,
  Set<String> autoAnswered = const {},
  List<CommandNotice> commands = const [],
  List<TurnTrace> turns = const [],
  bool foldTurns = false,
  List<TurnArtifacts> artifacts = const [],
  bool compactTools = false,
}) {
  debugDeriveRowsCount++;
  // Her conversation (伙伴小屋): what she used is folded away, one call or many,
  // and so is every ended turn's process, however it ended.
  final groupAt = compactTools ? 1 : toolGroupThreshold;
  final rows = <ChatRow>[];
  final attached = <String>{};
  var tools = <ToolChatItem>[];
  var nextCommand = 0;

  // 当前这一片(同一轮里,上一个收尾点之后)在 rows 里的起点,还没有内容
  // 时为 null;这一片内容的结束位置;最后一条有正文的助手消息的下标。
  int? pieceStart;
  var pieceEnd = 0;
  int? lastText;
  // 当前这一轮([turns] 里没加载到时为 null)和它的全部工具调用(插话切开
  // 的几片合起来算,改动卡按整轮出)。
  TurnTrace? turn;
  var turnTools = <ToolChatItem>[];

  void flushTools({bool live = false}) {
    if (tools.isEmpty) return;
    pieceStart ??= rows.length;
    // 带原生卡片的调用单独成行,把前后切成几段,每段照旧(≥ 3 次成组)。
    var run = <ToolChatItem>[];
    void flushRun({bool live = false}) {
      if (run.length >= groupAt) {
        rows.add(ToolGroupRow(run, live: live));
      } else {
        for (final tool in run) {
          rows.add(ToolCallRow(tool));
        }
      }
      run = <ToolChatItem>[];
    }

    for (final tool in tools) {
      if (hasToolCard(tool)) {
        flushRun();
        rows.add(ToolCallRow(tool));
      } else {
        run.add(tool);
      }
    }
    flushRun(live: live);
    tools = <ToolChatItem>[];
    pieceEnd = rows.length;
  }

  // 每一轮占的 seq:turn/start 到 turn/end;没有 turn/end 的(还在跑,或
  // Host 中途没了)到下一轮开始。[turns] 按起点排好(traceTurns 的顺序)。
  var cursor = 0;
  TurnTrace? turnAt(int seq) {
    if (turns.isEmpty) return null;
    while (cursor + 1 < turns.length && turns[cursor + 1].startSeq <= seq) {
      cursor++;
    }
    while (cursor > 0 && turns[cursor].startSeq > seq) {
      cursor--;
    }
    final trace = turns[cursor];
    if (trace.startSeq > seq) return null;
    if (trace.endSeq case final end? when seq > end) return null;
    return trace;
  }

  // 产物卡:按 turn/end 取。
  var nextArtifacts = 0;
  List<TurnArtifacts> takeArtifacts(int? beforeSeq) {
    final start = nextArtifacts;
    while (nextArtifacts < artifacts.length && (beforeSeq == null || artifacts[nextArtifacts].endSeq < beforeSeq)) {
      nextArtifacts++;
    }
    return artifacts.sublist(start, nextArtifacts);
  }

  /// 收起当前片的过程,保留显式正式答案;没有标记时用 [reply] 回退。
  /// 返回最后一条外露回复的新下标(全收进去时 null)。[cut]:这一片结束在哪条插话。
  int? fold(TurnTrace trace, int? reply, {int? cut}) {
    final start = pieceStart!;
    // Prefer explicit final answers: a late subagent result can produce another
    // answer in the same turn. Older hosts/models keep the positional fallback.
    final hasFinalAnswer = rows
        .getRange(start, pieceEnd)
        .whereType<AssistantRow>()
        .any((row) => row.item.isFinalAnswer && row.item.text.trim().isNotEmpty);
    var answer = hasFinalAnswer ? null : reply;
    if (answer != null) {
      for (var i = answer + 1; i < pieceEnd; i++) {
        final row = rows[i];
        if (row is ToolCallRow || row is ToolGroupRow || row is AssistantRow) {
          answer = null;
          break;
        }
      }
    }
    final end = answer ?? pieceEnd;
    final process = <ChatRow>[];
    final kept = <ChatRow>[];
    int? keptAnswer;
    var toolCalls = 0;
    var messages = 0;
    for (var i = start; i < end; i++) {
      switch (rows[i]) {
        case final ToolCallRow row when hasToolCard(row.item):
          // 原生卡片是给人看的:工具行收进去,卡片留在外面。
          toolCalls++;
          process.add(ToolCallRow(row.item, card: ToolCardPlacement.rowOnly));
          kept.add(ToolCallRow(row.item, card: ToolCardPlacement.cardOnly));
        case final ToolCallRow row:
          toolCalls++;
          process.add(row);
        case final ToolGroupRow row:
          toolCalls += row.tools.length;
          process.add(row);
        case final AssistantRow row when row.item.isFinalAnswer && row.item.text.trim().isNotEmpty:
          var item = row.item;
          if (item.reasoning.trim().isNotEmpty) {
            final (thinking, reply) = _splitReasoning(item);
            process.add(AssistantRow(thinking));
            item = reply;
          }
          keptAnswer = kept.length;
          kept.add(AssistantRow(item));
        case final AssistantRow row:
          if (row.item.text.trim().isNotEmpty) messages++;
          process.add(AssistantRow(row.item));
        case final NoticeRowData row:
          process.add(row);
        case final row:
          kept.add(row);
      }
    }
    var answerRow = answer == null ? null : rows[answer] as AssistantRow;
    if (answerRow != null && answerRow.item.reasoning.trim().isNotEmpty) {
      final (thinking, reply) = _splitReasoning(answerRow.item);
      process.add(AssistantRow(thinking));
      answerRow = AssistantRow(reply);
    }
    // 只有一段思考(普通问答):思考胶囊本来就是一行,不必再收一层。
    if (toolCalls == 0 && messages == 0 && process.length <= 1) return reply;
    final replacement = [
      TurnProcessRow(trace, List.unmodifiable(process), toolCalls: toolCalls, messages: messages, cut: cut),
      ...kept,
      ?answerRow,
    ];
    final removed = (answer == null ? end : answer + 1) - start;
    rows.replaceRange(start, start + removed, replacement);
    pieceEnd += replacement.length - removed;
    if (answerRow != null) return start + replacement.length - 1;
    return keptAnswer == null ? null : start + 1 + keptAnswer;
  }

  /// 收尾当前这一片。[cut] 为 null:这一轮到这里结束(不知道属于哪一轮的
  /// 内容也按结束算),挂脚注、接改动卡和 [artifactsBefore] 之前结束的轮的
  /// 产物卡(null = 剩下的全部);否则是插话 [cut] 把这一轮切开的地方,
  /// 只收这一片的过程。
  void close({int? cut, int? artifactsBefore}) {
    flushTools();
    final last = cut == null;
    final trace = turn;
    final done = trace != null && !trace.running && trace.endSeq != null ? trace : null;
    var index = lastText;
    if (foldTurns && done != null && pieceStart != null && (compactTools || (done.endReason?.isCompleted ?? false))) {
      index = fold(done, index, cut: cut);
    }
    final footnote = last ? done : null;
    if (index != null) {
      final row = rows[index] as AssistantRow;
      rows[index] = AssistantRow(row.item, showActions: true, footnote: footnote);
    } else if (footnote != null && rows.isNotEmpty) {
      rows.insert(pieceEnd, TurnFootnoteRow(footnote));
      pieceEnd++;
    }
    lastText = null;
    pieceStart = null;
    if (!last) return;
    if (turnTools.isNotEmpty) {
      final files = fileChangesOf(turnTools);
      if (files.isNotEmpty) {
        final anchor = turnTools.firstWhere((t) => toolKindOf(t) == ToolKind.edit).callId;
        rows.insert(pieceEnd, ChangeCardRow(files, anchor: anchor));
      }
    }
    final groups = takeArtifacts(artifactsBefore);
    if (groups.isNotEmpty && rows.isNotEmpty) {
      var at = pieceEnd;
      if (at < rows.length && rows[at] is ChangeCardRow) at++;
      for (final group in groups) {
        rows.insert(at++, ArtifactCardRow(group));
      }
    }
    turnTools = <ToolChatItem>[];
    pieceEnd = rows.length;
  }

  /// 指令行:落盘的按 seq 插在 [beforeSeq] 之前,null = 剩下的全部。
  void emitCommands(int? beforeSeq) {
    var flushed = false;
    while (nextCommand < commands.length) {
      final command = commands[nextCommand];
      final seq = command.seq;
      if (beforeSeq != null && (seq == null || seq >= beforeSeq)) break;
      if (!flushed) {
        flushTools();
        flushed = true;
      }
      rows.add(CommandNoticeRow(command));
      nextCommand++;
    }
  }

  int? seqOf(ChatItem item) => switch (item) {
    UserChatItem(:final seq) => seq,
    AssistantChatItem(:final seq) => seq,
    ToolChatItem(:final seq) => seq,
    NoticeChatItem(:final seq) => seq,
  };

  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    // 没有 seq 的(还在流式输出的草稿)跟着前面的内容走。
    if (seqOf(item) case final seq?) {
      final owner = turnAt(seq);
      if (!identical(owner, turn)) {
        // 换了一轮:上一轮(或不知道属于哪一轮的内容)到此为止。
        close(artifactsBefore: (turn?.endSeq ?? seq - 1) + 1);
        turn = owner;
      }
      emitCommands(seq);
    }
    switch (item) {
      case ToolChatItem():
        if (item.pendingApproval case final request?) {
          attached.add(request.eventId);
        }
        tools.add(item);
        turnTools.add(item);
      case UserChatItem():
        // 同一轮里的用户消息是运行中插话:插话之前的那一片单独收尾。
        // 不知道属于哪一轮时,一条用户消息就是一轮的分界。
        close(cut: turn == null ? null : item.seq, artifactsBefore: item.seq);
        rows.add(UserRow(item));
        pieceEnd = rows.length;
      case AssistantChatItem():
        flushTools();
        pieceStart ??= rows.length;
        rows.add(AssistantRow(item));
        if (item.text.trim().isNotEmpty) lastText = rows.length - 1;
      case NoticeChatItem():
        flushTools();
        final previous = i > 0 ? items[i - 1] : null;
        if (item.kind == 'aborted' && previous is AssistantChatItem && previous.interrupted) {
          break;
        }
        pieceStart ??= rows.length;
        rows.add(NoticeRowData(item));
    }
    if (item is AssistantChatItem || item is NoticeChatItem) {
      pieceEnd = rows.length;
    }
  }
  if (running) {
    flushTools(live: true);
  } else {
    close();
  }
  emitCommands(null);

  final orphans = [
    for (final request in approvals)
      if (!attached.contains(request.eventId) && !autoAnswered.contains(request.eventId)) ApprovalRow(request),
  ];

  rows.addAll(orphans);
  for (final question in questions) {
    rows.add(QuestionRow(question));
  }
  for (final prompt in pending) {
    // DSH's own context for the model is nobody's message (the controller
    // leaves it out already).
    if (prompt.isEngineNote) continue;
    rows.add(PendingRow(prompt));
  }
  return rows;
}

/// 回答自己的思考收进过程行:拆成只有思考的一条和只有正文的一条。
(AssistantChatItem, AssistantChatItem) _splitReasoning(AssistantChatItem item) => (
  AssistantChatItem(
    id: '${item.id}#r',
    rowKey: '${item.key}#r',
    seq: item.seq,
    time: item.time,
    text: '',
    reasoning: item.reasoning,
    model: item.model,
  ),
  AssistantChatItem(
    id: item.id,
    rowKey: item.rowKey,
    seq: item.seq,
    time: item.time,
    text: item.text,
    reasoning: '',
    interrupted: item.interrupted,
    usage: item.usage,
    model: item.model,
    isFinalAnswer: item.isFinalAnswer,
  ),
);
