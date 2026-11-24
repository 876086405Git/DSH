// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../speech/read_aloud.dart';
import '../../speech/speech_ui.dart';
import '../../common/expand_reveal.dart';
import '../../common/typing_indicator.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../dsh_ui/dsh_ui.dart';
import '../../plugins/native/message_plugin_menu.dart';
import '../../share/share_entry.dart' show shareReply;
import '../render/markdown_body.dart';
import 'message_actions.dart';
import 'message_selection.dart';
import 'stream_row.dart';
import 'theme_role_tag.dart';
import 'thinking_pill.dart';

/// 三个点交给下一块内容:旧的线性淡出,新的淡入并上移一点。
const _handOffOut = Duration(milliseconds: 90);
const _handOffIn = AppMotion.quick;
const _handOffCurve = Cubic(0.23, 1, 0.32, 1);
const _handOffRise = 3.0;

/// 思考之后的第一段正文淡入。
const _firstTextIn = Duration(milliseconds: 200);

/// 助手消息:**无框裸排的全宽正文**,没有头像也没有署名。
///
/// ```
/// (思考过程 ⌄)
/// 正文 Markdown…▍
/// ⚠ 响应已中断
/// ⧉ ⇪ ⑂ ↻ ⋯        ← 一轮的最后一条才有(分叉视 DSH 是否支持;
///                    ↻ 重新回答只给整个对话的最后一条)
/// ```
///
/// ⇪ 和菜单里的「分享」打开同一个分享面板。⋯:消息菜单(复制 / 选择文字 / 引用 /
/// 分享 / 重新回答 / 从这里分叉)。正文长按就地选字([MessageSelection]),选区上的
/// 「更多」也打开这个菜单。
class AssistantMessage extends StatefulWidget {
  const AssistantMessage({
    super.key,
    required this.item,
    this.showActions = false,
    this.onBranch,
    this.branching = false,
    this.onRegenerate,
    this.regenerating = false,
    this.onQuote,
    this.footnote,
  });

  final AssistantChatItem item;

  /// 是否在正文下方显示复制等操作(只给一轮里最后一条助手正文)。
  final bool showActions;

  /// "从这里分叉";null = 这条不是已完成一轮的最后一条回复。
  final VoidCallback? onBranch;

  /// 正在从这里分叉:分叉键转圈,不能再点。
  final bool branching;

  /// 「重新回答」;null = 这条不是对话的最后一条回复,或提问发不了第二次。
  final VoidCallback? onRegenerate;

  /// 正在准备重新回答:重答键转圈,不能再点。
  final bool regenerating;

  /// 「引用」:整条回复,或「选择文字」里选中的一段,放到输入框上方。
  final ValueChanged<String>? onQuote;

  /// 回合脚注(这一轮在这条回复处结束),挂在操作行右端。
  final Widget? footnote;

  @override
  State<AssistantMessage> createState() => _AssistantMessageState();
}

class _AssistantMessageState extends State<AssistantMessage> {
  ThinkingPill? _thinking;
  Widget? _body;
  String? _bodyText;
  bool? _bodyStreaming;
  bool? _bodyReveal;

  /// 这条回复在这里等过(画过三个点)。只有它才包交接动画:打开会话时已有的、
  /// 翻回去重建的回复都不多这一层。
  bool _waited = false;

  /// 正文是思考之后才开始的:第一段淡入。
  bool _textAfterThinking = false;

  static bool _waiting(AssistantChatItem item) =>
      item.streaming && item.text.trimRight().isEmpty && item.reasoning.trim().isEmpty;

  /// This reply started empty here, so all of it can be revealed as it arrives. One
  /// mounted halfway (the chat opened mid-stream, scrolled back to) shows what is there.
  bool _startedEmpty = false;

  /// The fluid tier's reveal, once it started it stays for this reply: see
  /// [MarkdownBody.reveal].
  bool _reveal = false;

  @override
  void initState() {
    super.initState();
    _waited = _waiting(widget.item);
    _startedEmpty = widget.item.text.trimRight().isEmpty;
  }

  @override
  void didUpdateWidget(AssistantMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget.item;
    final item = widget.item;
    _waited = _waited || _waiting(item);
    if (!_textAfterThinking &&
        old.streaming &&
        old.text.trimRight().isEmpty &&
        old.reasoning.trim().isNotEmpty &&
        item.text.trimRight().isNotEmpty) {
      _textAfterThinking = true;
    }
  }

  /// 正文还在长、思考没变时复用同一个思考栏实例,Flutter 不会再往下走。
  ThinkingPill _thinkingPill(String reasoning, bool active, bool streaming) {
    final pill = _thinking;
    if (pill != null &&
        pill.reasoning == reasoning &&
        pill.active == active &&
        pill.streaming == streaming &&
        pill.growIn == _waited) {
      return pill;
    }
    return _thinking = ThinkingPill(reasoning: reasoning, active: active, streaming: streaming, growIn: _waited);
  }

  /// 同一段文字只建一次 Markdown 子树:列表每 32ms 重建一次时,
  /// 没变的消息直接复用同一个 widget 实例,Flutter 不会再往下走。
  Widget _markdown(String text, bool streaming) {
    final reveal = _reveal = _reveal || (streaming && _startedEmpty && AppMotion.fluid(context));
    if (_body == null || _bodyText != text || _bodyStreaming != streaming || _bodyReveal != reveal) {
      // Selection is the message's own (MessageSelection around the text).
      // repairBareViews: a model that forgets the ```dsh-ui fence still gets
      // its view drawn instead of a wall of JSON.
      _body = MarkdownBody(
        text: text,
        streaming: streaming,
        reveal: reveal,
        selectable: false,
        repairBareViews: true,
        replyTypography: true,
      );
      _bodyText = text;
      _bodyStreaming = streaming;
      _bodyReveal = reveal;
    }
    if (!reveal) return _body!;
    // The reveal has no cursor: a long pause gets a quiet dot under the text instead.
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _body!,
        if (streaming)
          PositionedDirectional(
            start: 1,
            bottom: -_StallDot.size - 6,
            child: _StallDot(text: text),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final item = widget.item;
    final text = item.text.trimRight();
    final reasoning = item.reasoning.trim();
    final streaming = item.streaming;

    if (text.isEmpty && reasoning.isEmpty) {
      if (streaming) {
        return _HandOff(
          waiting: true,
          child: Align(
            key: const ValueKey('dots'),
            alignment: Alignment.centerLeft,
            heightFactor: 1,
            child: Semantics(label: l10n.chatReplying, child: const TypingIndicator()),
          ),
        );
      }
      if (!item.interrupted) return const SizedBox.shrink();
    }

    final actions = widget.showActions && !streaming && text.isNotEmpty;
    final reply = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (reasoning.isNotEmpty) ...[
          _thinkingPill(reasoning, streaming && text.isEmpty, streaming),
          if (text.isNotEmpty && !_textAfterThinking) const SizedBox(height: 8),
        ],
        // Always wrapped, streaming too: the Markdown subtree keeps its place
        // when the turn ends.
        if (text.isNotEmpty)
          _wrapAssistantBody(
            context,
            MessageSelection(
              text: text,
              onQuote: widget.onQuote,
              onMore: () => _menu(text),
              live: streaming,
              child: _textAfterThinking ? _FirstTextIn(child: _markdown(text, streaming)) : _markdown(text, streaming),
            ),
          ),
        if (item.interrupted) const _InterruptedMark(),
        // 一轮结束时和输入条上的胶囊同一节奏展开:胶囊收回多少,这里长出
        // 多少,回答不会先被顶上去再落回来。打开对话时已结束的轮直接展开。
        ExpandReveal(
          open: actions,
          duration: AppMotion.standard,
          curve: AppMotion.std,
          child: actions
              ? Consumer(
                  builder: (context, ref, _) => ReplyActionRow(
                    // Copy / share carry a one-line summary of each visual
                    // reply, never its raw JSON.
                    text: () => dshUiPlainText(text),
                    onBranch: widget.onBranch,
                    branching: widget.branching,
                    onShare: () => shareReply(context, widget.item),
                    onReadAloud: () => readAloudReply(context, widget.item.key, dshUiPlainText(text)),
                    reading: ref.watch(readAloudProvider.select((s) => s.phaseOf(widget.item.key))),
                    onRegenerate: widget.onRegenerate,
                    regenerating: widget.regenerating,
                    onMore: () => _menu(text),
                    trailing: widget.footnote,
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
    // 一条回复是读屏里的一个分组,里面的段落、标题照常逐个读。
    // A screen reader's long-press opens the menu (a finger's selects text).
    final message = Semantics(
      key: const ValueKey('reply'),
      container: true,
      explicitChildNodes: true,
      onLongPress: streaming || text.isEmpty ? null : () => _menu(text),
      child: reply,
    );
    return _waited ? _HandOff(waiting: false, child: message) : message;
  }

  Widget _wrapAssistantBody(BuildContext context, Widget child) {
    final themeStyle = DshThemeStyle.of(context);
    if (themeStyle.pack == null) return child;
    final scheme = Theme.of(context).colorScheme;
    final rule = themeStyle.rule ?? scheme.primary.withValues(alpha: 0.65);
    final Widget body = switch (themeStyle.components.assistantStyle) {
      ThemeAssistantStyle.plain => child,
      // Full width: a short reply's card is as wide as a long one's.
      ThemeAssistantStyle.card => SizedBox(
        width: double.infinity,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: themeStyle.assistantBubble ?? DshSurfaces.of(context).card.fill,
            shape: themeStyle.cardShape(themeStyle.assistantBorder ?? scheme.outlineVariant, themeStyle.borderWidth),
          ),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: child),
        ),
      ),
      ThemeAssistantStyle.leftRule => DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: rule, width: 2.5)),
        ),
        child: Padding(padding: const EdgeInsets.only(left: 12), child: child),
      ),
      // Only the tint and the rule are clipped to the card's corners; the
      // text is not, so nothing in it is cut.
      ThemeAssistantStyle.quote => SizedBox(
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(
              child: themeStyle.clipFor(
                themeStyle.cardRadius,
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.06),
                    border: Border(left: BorderSide(color: rule, width: 3)),
                  ),
                ),
              ),
            ),
            if (themeStyle.assistantBorder case final border?)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: ShapeDecoration(shape: themeStyle.cardShape(border, themeStyle.borderWidth)),
                ),
              ),
            Padding(padding: const EdgeInsets.fromLTRB(15, 10, 12, 10), child: child),
          ],
        ),
      ),
    };
    final tag = themeRoleTag(context, themeStyle, user: false);
    if (tag == null) return body;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [tag, body]);
  }

  Future<void> _menu(String markdown) async {
    final text = dshUiPlainText(markdown);
    final onBranch = widget.onBranch;
    final onRegenerate = widget.onRegenerate;
    final onQuote = widget.onQuote;
    final action = await showMessageMenu(
      context,
      text: text,
      // Plugins' items for this reply, under each plugin's name.
      extra: nativeMessageMenuGroups(context, widget.item, text: markdown),
      actions: [
        MessageAction.copy,
        MessageAction.selectText,
        if (onQuote != null) MessageAction.quote,
        MessageAction.share,
        MessageAction.readAloud,
        if (onRegenerate != null && !widget.regenerating) MessageAction.regenerate,
        if (onBranch != null && !widget.branching) MessageAction.branch,
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case MessageAction.copy:
        await copyMessage(context, text);
      case MessageAction.selectText:
        await showSelectTextSheet(context, text, markdown: true, onQuote: onQuote);
      case MessageAction.quote:
        onQuote?.call(text);
      case MessageAction.share:
        await shareReply(context, widget.item);
      case MessageAction.readAloud:
        readAloudReply(context, widget.item.key, text);
      case MessageAction.regenerate:
        onRegenerate?.call();
      case MessageAction.branch:
        onBranch?.call();
      case MessageAction.edit:
        break;
    }
  }
}

/// 等待的三个点和接上来的内容之间的交接:一个槽,叠着交叉淡入淡出。
///
/// 等待时占住思考行的高度:接上来的是思考行,这一行的高度不变,贴底的列表不用
/// 追;接上来的是矮一点的正文,多出来的几像素在淡入的同时缓缓还回去。
class _HandOff extends StatelessWidget {
  const _HandOff({required this.waiting, required this.child});

  final bool waiting;
  final Widget child;

  static Widget _transition(Widget child, Animation<double> animation) => FadeTransition(
    opacity: animation,
    child: AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (context, child) => Transform.translate(
        // 只有进来的上移;出去的原地淡掉。
        offset: Offset(0, animation.status == AnimationStatus.reverse ? 0 : _handOffRise * (1 - animation.value)),
        child: child,
      ),
    ),
  );

  // passthrough:回复拿到的约束和不包这一层时一样(整行宽,长按的落点不缩)。
  static Widget _layout(Widget? current, List<Widget> previous) => Stack(
    fit: StackFit.passthrough,
    alignment: AlignmentDirectional.topStart,
    clipBehavior: Clip.none,
    children: [...previous, ?current],
  );

  @override
  Widget build(BuildContext context) {
    final body = AppType.chatBody(context);
    final line = MediaQuery.textScalerOf(context).scale(body.fontSize ?? 16) * (body.height ?? 1.65);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: waiting ? StreamRow.minHeight : line),
      duration: AppMotion.of(context, _handOffIn),
      curve: AppMotion.std,
      builder: (context, height, child) => ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: child,
      ),
      child: AnimatedSwitcher(
        duration: AppMotion.of(context, _handOffIn),
        reverseDuration: AppMotion.of(context, _handOffOut),
        switchInCurve: _handOffCurve,
        switchOutCurve: Curves.linear,
        transitionBuilder: _transition,
        layoutBuilder: _layout,
        child: child,
      ),
    );
  }
}

/// 思考之后的第一段正文:淡入,连上面的间距一起从 0 长到全高。思考窗口此刻正在
/// 收起,一边收、一边长,贴底的列表只朝一个方向走,不会先被顶上去再落回来。
class _FirstTextIn extends StatelessWidget {
  const _FirstTextIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: AppMotion.of(context, _firstTextIn),
    curve: AppMotion.collapseCurve,
    builder: (context, t, child) => ClipRect(
      // 落定后同一层包装、不再裁剪(正文里的代码块会溢出到两侧)。
      clipBehavior: t < 1 ? Clip.hardEdge : Clip.none,
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: t,
        child: SizedBox(
          width: double.infinity,
          child: Opacity(opacity: t, child: child),
        ),
      ),
    ),
    child: Padding(padding: const EdgeInsets.only(top: 8), child: child),
  );
}

/// 被取消 / 中断:正文末尾一行 danger 小字,不改正文颜色。
class _InterruptedMark extends StatelessWidget {
  const _InterruptedMark();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final danger = DshColors.of(context).danger;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(AppIcons.stopped, size: 16, color: danger),
          const SizedBox(width: 4),
          Text(
            l10n.chatInterrupted,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: danger, height: 1.3),
          ),
        ],
      ),
    );
  }
}

/// A reply that has gone quiet but isn't over: after a moment with no new text, one
/// small dot breathes where the next line would start. New text puts it away.
class _StallDot extends StatefulWidget {
  const _StallDot({required this.text});

  /// What has arrived so far: a change is the stream moving.
  final String text;

  static const size = 5.0;
  static const _after = Duration(milliseconds: 900);

  @override
  State<_StallDot> createState() => _StallDotState();
}

class _StallDotState extends State<_StallDot> with SingleTickerProviderStateMixin {
  late final AnimationController _breath = AnimationController(vsync: this, duration: AppMotion.breath ~/ 2);
  late final Animation<double> _level = Tween(
    begin: 0.25,
    end: 1.0,
  ).animate(CurvedAnimation(parent: _breath, curve: Curves.easeInOut));
  Timer? _wait;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _wait?.cancel();
    _wait = Timer(_StallDot._after, () {
      if (!mounted) return;
      setState(() => _shown = true);
      unawaited(_breath.repeat(reverse: true));
    });
  }

  @override
  void didUpdateWidget(_StallDot old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text) return;
    _breath.stop();
    if (_shown) setState(() => _shown = false);
    _arm();
  }

  @override
  void dispose() {
    _wait?.cancel();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = DshColors.of(context).textTertiary;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _shown ? 1 : 0,
        duration: AppMotion.of(context, AppMotion.standard),
        child: RepaintBoundary(
          child: FadeTransition(
            opacity: _level,
            child: Container(
              width: _StallDot.size,
              height: _StallDot.size,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}
