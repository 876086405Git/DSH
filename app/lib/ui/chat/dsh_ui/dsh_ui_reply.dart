// SPDX-FileCopyrightText: 2026 Fei2411 and the DS Bot contributors
// SPDX-License-Identifier: Apache-2.0
// See THIRD_PARTY_NOTICES.md.
// Modified: the `validateOptions` selection rules translated to Dart; the
// answer travels as a readable user message built only from visible labels
// (`[dsh-ui reply]` + `选择：…`), and the card's state is derived from the
// message order instead of being stored.

import 'package:dsh_client/dsh_client.dart';

import '../../../l10n/l10n.dart';
import 'dsh_ui_model.dart';

/// 回复消息首行的标记。用户点了视图里的按钮，App 发出的消息以它开头。
const dshUiReplyMarker = '[dsh-ui reply]';

enum DshUiReplyKind {
  /// `选择：方案 A`（多选用「、」连接）。
  choice,

  /// `确认` / `确认：开始`。
  confirm,

  /// `取消` / `取消：再想想`。
  cancel,

  /// 首行有标记，第二行不认识（手改过或以后的格式）。
  other,
}

/// 一条 `[dsh-ui reply]` 消息。
final class DshUiReply {
  const DshUiReply({required this.kind, this.title, this.value, this.freetext});

  /// 选择：[labels] 用「、」连接；[freetext] 是「其他」里自己填的那句。
  factory DshUiReply.choice(List<String> labels, {String? title, String? freetext}) {
    final chosen = labels.map(_flat).whereType<String>().join(_join);
    return DshUiReply(
      kind: DshUiReplyKind.choice,
      title: _flat(title),
      value: chosen.isEmpty ? null : chosen,
      freetext: _flat(freetext),
    );
  }

  /// 确认 / 取消。[label] 是按钮上的字；与默认的「确认」「取消」相同时不重复写。
  factory DshUiReply.confirm(bool confirmed, {String? label, String? title}) {
    final kind = confirmed ? DshUiReplyKind.confirm : DshUiReplyKind.cancel;
    final fallback = confirmed ? DshUiConfirm.defaultConfirm : DshUiConfirm.defaultCancel;
    final flat = _flat(label);
    return DshUiReply(kind: kind, title: _flat(title), value: flat == null || flat == fallback ? null : flat);
  }

  final DshUiReplyKind kind;

  /// 视图的标题（根节点的 `title`），用来认出答的是哪张卡。
  final String? title;

  /// 选择：所选 label；确认 / 取消：按钮上的字（默认字时为 null）；
  /// other：第二行原文。
  final String? value;

  /// 选择：用户在「其他」里自己填的那句（没填时 null）。
  final String? freetext;

  /// 发出去的完整文字。只由用户看得到的字拼成，不带隐藏值。
  String get text {
    final head = title == null ? dshUiReplyMarker : '$dshUiReplyMarker $title';
    final body = switch (kind) {
      DshUiReplyKind.choice => [
        if (value != null && value!.isNotEmpty) appL10n.viewUiReplyChoice(value!),
        if (freetext != null && freetext!.isNotEmpty) appL10n.viewUiReplyOther(freetext!),
      ].join('\n'),
      DshUiReplyKind.confirm => value == null ? appL10n.commonConfirm : appL10n.viewUiReplyConfirm(value!),
      DshUiReplyKind.cancel => value == null ? appL10n.commonCancel : appL10n.viewUiReplyCancel(value!),
      DshUiReplyKind.other => value ?? '',
    };
    return body.isEmpty ? head : '$head\n$body';
  }

  /// 用户气泡上的小标签：「已选择：方案 A」「已确认：开始」「已取消」。
  String get chipLabel => switch (kind) {
    DshUiReplyKind.choice => switch ((value, freetext)) {
      (final chosen?, final typed?) when chosen.isNotEmpty && typed.isNotEmpty =>
        '${appL10n.viewUiChosen(chosen)} · ${appL10n.viewUiChosenOther(typed)}',
      (_, final typed?) when typed.isNotEmpty => appL10n.viewUiChosenOther(typed),
      _ => appL10n.viewUiChosen(value ?? ''),
    },
    DshUiReplyKind.confirm => value == null ? appL10n.viewUiConfirmed : appL10n.viewUiConfirmedValue(value!),
    DshUiReplyKind.cancel => value == null ? appL10n.commonCancelled : appL10n.viewUiCancelledValue(value!),
    DshUiReplyKind.other => value == null || value!.isEmpty ? appL10n.viewUiReplied : value!,
  };

  /// 选择的 label（按「、」切开）。label 本身含「、」时用 [selectedIn] 更准。
  List<String> get choices => kind == DshUiReplyKind.choice && value != null
      ? [
          for (final part in value!.split(_join))
            if (part.trim().isNotEmpty) part.trim(),
        ]
      : const [];

  /// [labels] 里被这条回复选中的（保持 [labels] 的顺序）。按整段匹配，
  /// 含「、」的 label 也认得出来。
  List<String> selectedIn(List<String> labels) {
    if (kind != DshUiReplyKind.choice || value == null) return const [];
    final padded = '$_join$value$_join';
    return [
      for (final label in labels)
        if (padded.contains('$_join$label$_join')) label,
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is DshUiReply &&
      other.kind == kind &&
      other.title == title &&
      other.value == value &&
      other.freetext == freetext;

  @override
  int get hashCode => Object.hash(kind, title, value, freetext);

  @override
  String toString() => text;
}

const _join = '、'; // l10n:keep reply selection protocol delimiter

/// 「其他」那一行：用户自己填的答案。中英文都认（发出去时按界面语言写）。
final _otherLine = RegExp(r'^(其他|Other)\s*[：:]\s*(.*)$');

/// 换行压成空格：label 和标题都要留在一行里，第二行才认得出来。
String? _flat(String? text) {
  final flat = text?.replaceAll(RegExp(r'\s*[\r\n]+\s*'), ' ').trim();
  return flat == null || flat.isEmpty ? null : flat;
}

/// 认 `[dsh-ui reply]` 消息；不是的返回 null。
DshUiReply? parseDshUiReply(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith(dshUiReplyMarker)) return null;
  final lines = trimmed.split(RegExp(r'\r?\n'));
  final head = lines.first.trim();
  final title = _flat(head.substring(dshUiReplyMarker.length));
  final body = [
    for (final line in lines.skip(1))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (body.isEmpty) return DshUiReply(kind: DshUiReplyKind.other, title: title);
  final first = body.first;
  // 只填了「其他」：仍然是一次选择，答案就是那句自己填的。
  if (_otherLine.firstMatch(first) case final other?) {
    return DshUiReply(kind: DshUiReplyKind.choice, title: title, freetext: _flat(other.group(2)));
  }
  // l10n:keep legacy reply protocol parser
  final colon = RegExp(r'^(选择|确认|取消|Select|Confirm|Cancel)\s*(?:[：:]\s*(.*))?$').firstMatch(first);
  if (colon == null) {
    return DshUiReply(kind: DshUiReplyKind.other, title: title, value: first);
  }
  final value = _flat(colon.group(2));
  final kind = switch (colon.group(1)) {
    // l10n:keep legacy reply protocol value
    '选择' || 'Select' => DshUiReplyKind.choice,
    // l10n:keep legacy reply protocol value
    '确认' || 'Confirm' => DshUiReplyKind.confirm,
    _ => DshUiReplyKind.cancel,
  };
  // 「其他：…」跟在同一行后面：只对选择有意义。
  final freetext = kind == DshUiReplyKind.choice && body.length > 1
      ? _flat(_otherLine.firstMatch(body[1])?.group(2))
      : null;
  return DshUiReply(kind: kind, title: title, value: value, freetext: freetext);
}

// ───────────────────────── 交互状态 ─────────────────────────

enum DshUiInteraction {
  /// 可以点：会话里最后一条助手消息，这一轮已结束，之后没有用户消息。
  live,

  /// 这一轮还在跑：禁用，免得点一下变成插话。
  running,

  /// 之后第一条用户消息是 `[dsh-ui reply]`：高亮所选，只读。
  answered,

  /// 之后是普通消息（或者模型已经接着说了别的）：只读，不标答案。
  expired,
}

/// 一条助手消息里视图的交互状态。不另存，从消息顺序推出来。
final class DshUiState {
  const DshUiState(this.interaction, {this.reply});

  static const live = DshUiState(DshUiInteraction.live);
  static const running = DshUiState(DshUiInteraction.running);
  static const expired = DshUiState(DshUiInteraction.expired);

  final DshUiInteraction interaction;

  /// [DshUiInteraction.answered] 时的那条回复。
  final DshUiReply? reply;

  bool get canAnswer => interaction == DshUiInteraction.live;

  @override
  bool operator ==(Object other) => other is DshUiState && other.interaction == interaction && other.reply == reply;

  @override
  int get hashCode => Object.hash(interaction, reply);

  @override
  String toString() => 'DshUiState(${interaction.name}, $reply)';
}

/// 按 [DshUiInteraction] 的四种情况推出 [messageId] 这条助手消息里视图的状态。
///
/// [items] 是会话的消息（`ChatState.items`），[running] 是这一轮是否还在跑
/// （`ChatState.running`），[pending] 是已发出、还没出现在记录里的消息正文
/// （`ChatState.pending` 的 `text`，按发送顺序）：刚点完按钮、服务端还没回显
/// 时就已经算「已答」。
DshUiState dshUiStateFor({
  required List<ChatItem> items,
  required String messageId,
  required bool running,
  List<String> pending = const [],
}) {
  final index = items.indexWhere((item) => item is AssistantChatItem && item.id == messageId);
  if (index < 0) return DshUiState.expired;
  final message = items[index] as AssistantChatItem;
  return dshUiStateAfter(
    items
        .skip(index + 1)
        .map(
          (item) => switch (item) {
            UserChatItem() => (user: true, text: item.text),
            AssistantChatItem() => (user: false, text: item.text),
            _ => null,
          },
        )
        .nonNulls,
    running: running || message.streaming,
    pending: pending,
  );
}

/// [dshUiStateFor] for any transcript (a DS Bot's too): [later] is what came after the
/// message, in order, the person's and the assistant's.
DshUiState dshUiStateAfter(
  Iterable<({bool user, String text})> later, {
  required bool running,
  List<String> pending = const [],
}) {
  var laterReply = false;
  for (final item in later) {
    if (item.user) return _after(item.text);
    if (item.text.trim().isNotEmpty) laterReply = true;
  }
  if (pending.isNotEmpty) return _after(pending.first);
  if (laterReply) return DshUiState.expired;
  return running ? DshUiState.running : DshUiState.live;
}

DshUiState _after(String userText) {
  final reply = parseDshUiReply(userText);
  return reply == null ? DshUiState.expired : DshUiState(DshUiInteraction.answered, reply: reply);
}

/// [reply] 答的是不是 [view]，答了什么。标题对不上（两边都有标题且不同），或者
/// 答案在视图里找不到，返回 null：那张卡按「失效」画。
DshUiAnswer? dshUiAnswerFor(DshUiView view, DshUiReply reply) {
  final title = reply.title;
  if (title != null && view.title != null && title != view.title) return null;
  switch (reply.kind) {
    case DshUiReplyKind.choice:
      for (final node in view.answerNodes) {
        if (node is! DshUiOptions) continue;
        final picked = reply.selectedIn(node.labels);
        // 自己填的那句只对开了 freetext 的选项卡有意义。
        final typed = node.freetext ? reply.freetext : null;
        if (picked.isEmpty && (typed == null || typed.isEmpty)) continue;
        // 单选只认一个（照 DS Bot 的选择规则）。
        return DshUiAnswer(
          nodePath: node.path,
          selected: node.multi ? picked : picked.take(1).toList(),
          freetext: typed,
        );
      }
      return null;
    case DshUiReplyKind.confirm:
    case DshUiReplyKind.cancel:
      for (final node in view.answerNodes) {
        if (node is DshUiConfirm) {
          return DshUiAnswer(nodePath: node.path, confirmed: reply.kind == DshUiReplyKind.confirm);
        }
      }
      return null;
    case DshUiReplyKind.other:
      return null;
  }
}

/// 已答视图里要高亮的东西。
final class DshUiAnswer {
  const DshUiAnswer({required this.nodePath, this.selected = const [], this.freetext, this.confirmed});

  /// 被回答的组件（`view.children[1]`）。
  final String nodePath;

  /// `options` 选中的 label。
  final List<String> selected;

  /// `options` 里「其他」自己填的那句（没填时 null）。
  final String? freetext;

  /// `confirm`：true 确认，false 取消；不是 confirm 时为 null。
  final bool? confirmed;
}
