// The pieces a Bot chat and a group chat share: the floating header, the page
// frame (list under glass, cards and the composer at the bottom), the rows of
// the transcript, and the cards a Bot leaves for the person (a question, a
// view, a model to pick). Messages draw with the chat's own widgets
// (`MarkdownBody`, `UserBubble`).

import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../state/bots_state.dart';
import '../chat/dsh_ui/dsh_ui.dart';
import '../chat/render/markdown_body.dart';
import '../chat/widgets/chat_card.dart';
import '../chat/widgets/message_actions.dart';
import '../chat/widgets/notice_row.dart';
import '../chat/widgets/user_bubble.dart';
import '../common/capsule_chip.dart';
import '../common/side_insets.dart';
import '../common/smooth_size.dart';
import '../common/status_dot.dart';
import '../common/typing_indicator.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'bot_avatar.dart';
import 'bot_format.dart';
import 'bots_page.dart' show BotTag;

// ── Header ───────────────────────────────────────────────────────────────────

/// Three floating chrome-glass pieces, like the chat's own header: back, a
/// title pill (the face, the name, one line of status), details.
///
/// ```
/// (‹) ( ◉ Chief           )             (ⓘ)
///     (   ● 正在运行命令  )
/// ```
class BotChatHeader extends StatelessWidget {
  const BotChatHeader({
    super.key,
    required this.face,
    required this.title,
    required this.status,
    required this.tone,
    required this.onDetails,
    this.scrolledUnder,
    this.action,
  });

  final Widget face;
  final String title;
  final String status;
  final StatusTone tone;
  final VoidCallback onDetails;
  final ValueNotifier<double>? scrolledUnder;

  /// The round key on the right, in place of ⓘ (which repeats the title's
  /// tap): its icon, label and what it does.
  final (IconData, String, VoidCallback)? action;

  static const barHeight = 56.0;
  static const key44 = 44.0;

  /// The face sits in the pill's left end with the same air all round.
  static const faceSize = 32.0;

  /// [barHeight], taller when a large text size needs it for the title and
  /// status lines.
  static double barHeightOf(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final small = Theme.of(context).textTheme.labelSmall!.fontSize!;
    return math.max(barHeight, scaler.scale(15) * 1.3 + scaler.scale(small) * 1.25 + 12);
  }

  static double heightOf(BuildContext context) => MediaQuery.paddingOf(context).top + barHeightOf(context) + 8;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final faceInset = (key44 - faceSize) / 2;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        if (scrolledUnder case final scrolled?)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: ValueListenableBuilder<double>(
              valueListenable: scrolled,
              builder: (context, t, child) => Opacity(opacity: t, child: child),
              child: TopFade(height: top + barHeightOf(context) + 12),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(12, top, 12, 0),
          child: BackdropGroup(
            child: SizedBox(
              height: barHeightOf(context),
              child: Row(
                children: [
                  _RoundKey(
                    key: const ValueKey('bot-back'),
                    icon: AppIcons.back,
                    tooltip: l10n.commonBack,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Semantics(
                        button: true,
                        hint: l10n.botsViewDetails,
                        child: GlassSurface(
                          key: const ValueKey('bot-title'),
                          tier: GlassTier.chrome,
                          stadium: true,
                          grouped: true,
                          onTap: onDetails,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: key44),
                            child: Padding(
                              padding: EdgeInsets.only(left: faceInset, right: 16),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox.square(key: const ValueKey('bot-face'), dimension: faceSize, child: face),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: SmoothSize(
                                      duration: AppMotion.of(context, AppMotion.standard),
                                      curve: AppMotion.std,
                                      alignment: Alignment.centerLeft,
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.3),
                                          ),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              StatusDot(tone: tone, size: 6),
                                              const SizedBox(width: 5),
                                              Flexible(
                                                child: Text(
                                                  status,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: theme.textTheme.labelSmall?.copyWith(
                                                    color: tone == StatusTone.warn ? dsh.warning : dsh.textTertiary,
                                                    height: 1.25,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (action case (final icon, final label, final onTap))
                    _RoundKey(key: const ValueKey('bot-action'), icon: icon, tooltip: label, onTap: onTap)
                  else
                    _RoundKey(
                      key: const ValueKey('bot-details'),
                      icon: AppIcons.info,
                      tooltip: l10n.commonDetails,
                      onTap: onDetails,
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RoundKey extends StatelessWidget {
  const _RoundKey({super.key, required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: tooltip,
    child: SizedBox.square(
      dimension: BotChatHeader.key44,
      child: GlassSurface(
        tier: GlassTier.chrome,
        circle: true,
        grouped: true,
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Center(child: Icon(icon, size: 22, color: Theme.of(context).colorScheme.onSurface)),
        ),
      ),
    ),
  );
}

// ── Frame ────────────────────────────────────────────────────────────────────

/// The page: the transcript fills the space between the header (floating
/// over it) and the bottom column (cards, error, composer).
class BotChatFrame extends StatelessWidget {
  const BotChatFrame({
    super.key,
    required this.header,
    required this.body,
    required this.bottom,
    this.backdrop,
    this.endDrawer,
    this.scaffoldKey,
  });

  final Widget header;
  final Widget body;
  final List<Widget> bottom;

  /// What the page stands on, around [child]; null: the usual gradient ([AppBackdrop]).
  final Widget Function(Widget child)? backdrop;

  /// A panel that slides in from the right edge (opened through [scaffoldKey]).
  final Widget? endDrawer;
  final GlobalKey<ScaffoldState>? scaffoldKey;

  @override
  Widget build(BuildContext context) {
    final backdrop = this.backdrop ?? (child) => AppBackdrop(child: child);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dshSystemOverlay(Theme.of(context).brightness),
      child: backdrop(
        Scaffold(
          key: scaffoldKey,
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: true,
          endDrawer: endDrawer,
          // A phone on its side: clear of the cutout on both sides.
          body: SideSafeArea(
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(child: body),
                      Positioned(left: 0, right: 0, top: 0, child: header),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  minimum: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: bottom,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An error over the composer, or nothing.
class BotErrorSlot extends StatelessWidget {
  const BotErrorSlot({super.key, required this.error, required this.onDismiss});

  final String? error;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => SmoothSize(
    duration: AppMotion.of(context, AppMotion.standard),
    curve: AppMotion.std,
    alignment: Alignment.bottomCenter,
    child: error == null
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ErrorBanner(message: error!, onDismiss: onDismiss),
          ),
  );
}

// ── Transcript ───────────────────────────────────────────────────────────────

/// One row of a transcript, newest last.
sealed class BotRow {
  const BotRow();
}

final class BotItemRow extends BotRow {
  const BotItemRow(this.item, {this.continued = false});
  final DsBotItem item;

  /// Same speaker as the row above: no face, no name.
  final bool continued;
}

final class BotTimeRow extends BotRow {
  const BotTimeRow(this.time);
  final DateTime time;
}

final class BotPendingRow extends BotRow {
  const BotPendingRow(this.pending);
  final DsBotPending pending;
}

final class BotStreamingRow extends BotRow {
  const BotStreamingRow(this.text);
  final String text;
}

final class BotTypingRow extends BotRow {
  const BotTypingRow(this.bot, this.label);
  final DsBot bot;
  final String label;
}

/// Rows for [items]: a time line before a message more than 15 minutes after
/// the one before it, and [continued] runs of one speaker.
List<BotRow> transcriptRows(
  List<DsBotItem> items, {
  List<DsBotPending> pending = const [],
  String? streaming,
  BotTypingRow? typing,
}) {
  final rows = <BotRow>[];
  DateTime? last;
  String? speaker;
  for (final item in items) {
    final time = item.time;
    if (time != null && (last == null || time.difference(last) > const Duration(minutes: 15))) {
      rows.add(BotTimeRow(time));
      speaker = null;
    }
    if (time != null) last = time;
    final who = item.kind == DsBotItemKind.bot ? 'bot:${item.botId ?? item.name}' : item.kind.name;
    final continued = item.kind == DsBotItemKind.bot && who == speaker;
    rows.add(BotItemRow(item, continued: continued));
    speaker = item.kind == DsBotItemKind.event || item.kind == DsBotItemKind.divider ? null : who;
  }
  for (final entry in pending) {
    rows.add(BotPendingRow(entry));
  }
  if (streaming != null) rows.add(BotStreamingRow(streaming));
  if (typing != null) rows.add(typing);
  return rows;
}

/// The transcript, newest at the bottom; scrolling up to the oldest row asks
/// for the page before.
class BotTranscript extends StatefulWidget {
  const BotTranscript({
    super.key,
    required this.rows,
    required this.rowBuilder,
    required this.topInset,
    this.hasEarlier = false,
    this.loadingEarlier = false,
    this.onEarlier,
    this.scrolledUnder,
    this.empty,
  });

  final List<BotRow> rows;
  final Widget Function(BuildContext context, BotRow row) rowBuilder;
  final double topInset;
  final bool hasEarlier;
  final bool loadingEarlier;
  final VoidCallback? onEarlier;
  final ValueNotifier<double>? scrolledUnder;

  /// Shown when there are no rows.
  final Widget? empty;

  @override
  State<BotTranscript> createState() => _BotTranscriptState();
}

class _BotTranscriptState extends State<BotTranscript> {
  bool _onScroll(ScrollNotification note) {
    final metrics = note.metrics;
    // Reversed: content above the top edge is what lies past the scroll end.
    final above = metrics.maxScrollExtent - metrics.pixels;
    widget.scrolledUnder?.value = (above / 24).clamp(0.0, 1.0);
    if (above < 400 && widget.hasEarlier && !widget.loadingEarlier) widget.onEarlier?.call();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    if (rows.isEmpty && widget.empty != null) {
      return Padding(
        padding: EdgeInsets.only(top: widget.topInset),
        child: Center(child: widget.empty),
      );
    }
    final extra = widget.hasEarlier ? 1 : 0;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ListView.builder(
        reverse: true,
        padding: EdgeInsets.fromLTRB(0, widget.topInset, 0, 8),
        itemCount: rows.length + extra,
        itemBuilder: (context, index) {
          if (index == rows.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          final row = rows[rows.length - 1 - index];
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppSpace.readingWidth),
              child: widget.rowBuilder(context, row),
            ),
          );
        },
      ),
    );
  }
}

/// Space above a row: tight inside one speaker's run, wider between turns.
EdgeInsets rowPadding(BotRow row) => switch (row) {
  BotItemRow(continued: true) => const EdgeInsets.fromLTRB(16, 4, 16, 0),
  BotTimeRow() => const EdgeInsets.fromLTRB(16, 20, 16, 4),
  _ => const EdgeInsets.fromLTRB(16, 16, 16, 0),
};

/// 「14:05」 between messages far apart.
class BotTimeLine extends StatelessWidget {
  const BotTimeLine(this.time, {super.key});

  final DateTime time;

  @override
  Widget build(BuildContext context) => Center(
    child: Text(
      shortTime(time),
      style: AppType.tabular(
        Theme.of(context).textTheme.labelSmall!.copyWith(color: DshColors.of(context).textTertiary),
      ),
    ),
  );
}

/// A quiet centred line: something that happened, not something said.
class BotEventLine extends StatelessWidget {
  const BotEventLine({super.key, required this.text, this.icon, this.danger = false});

  final String text;
  final IconData? icon;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    final color = danger ? dsh.danger : dsh.textTertiary;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: color, height: 1.45);
    return Center(
      child: Text.rich(
        TextSpan(
          children: [
            if (icon != null) ...[
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Icon(icon, size: 14, color: color),
              ),
              const TextSpan(text: ' '),
            ],
            TextSpan(text: text),
          ],
        ),
        textAlign: TextAlign.center,
        style: style,
      ),
    );
  }
}

/// A Bot's words in its own chat: bare full-width Markdown, like the chat's
/// replies; long-press copies or selects.
class BotReplyText extends StatelessWidget {
  const BotReplyText({super.key, required this.text, this.streaming = false});

  final String text;
  final bool streaming;

  Future<void> _menu(BuildContext context) async {
    final action = await showMessageMenu(
      context,
      text: text,
      actions: const [MessageAction.copy, MessageAction.selectText],
    );
    if (!context.mounted || action == null) return;
    if (action == MessageAction.copy) {
      await copyMessage(context, text);
    } else if (action == MessageAction.selectText) {
      await showSelectTextSheet(context, text, markdown: true);
    }
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPress: streaming ? null : () => _menu(context),
    child: MarkdownBody(text: text, streaming: streaming, selectable: false, repairBareViews: true),
  );
}

/// One message in a group: the speaker's face and name on the first of a
/// run, then the text beside the face's column.
///
/// ```
/// ◉  Chief  管理员  14:05
///    @Writer 写个初稿
///    第二句接着同一个人
/// ```
class GroupMessage extends StatelessWidget {
  const GroupMessage({
    super.key,
    required this.item,
    required this.bot,
    required this.continued,
    this.admin = false,
    this.onOpenBot,
    this.onShowAll,
  });

  final DsBotItem item;

  /// Null when the speaker is no longer on the team.
  final DsBot? bot;
  final bool continued;
  final bool admin;
  final VoidCallback? onOpenBot;

  /// A long post sent as a file: reads it whole.
  final VoidCallback? onShowAll;

  static const face = 28.0;
  static const gap = 10.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final name = bot?.name ?? item.name ?? 'Bot';
    final color = bot?.ink ?? item.color ?? dsBotDefaultColor(item.botId ?? name);
    final avatar = bot == null ? BotMonogram(name: name, color: color, size: face) : BotAvatar(bot: bot!, size: face);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!continued)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: botNameInk(context, color),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (admin) ...[const SizedBox(width: 6), BotTag(l10n.botsAdmin)],
                if (item.time != null) ...[
                  const SizedBox(width: 6),
                  Text(
                    shortTime(item.time),
                    style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                  ),
                ],
              ],
            ),
          ),
        BotReplyText(text: item.text),
        if (onShowAll != null)
          TextButton(
            onPressed: onShowAll,
            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            child: Text(l10n.botsShowAll),
          ),
      ],
    );
    return Semantics(
      label: name,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: face,
            child: continued ? null : GestureDetector(onTap: onOpenBot, child: avatar),
          ),
          const SizedBox(width: gap),
          Expanded(child: body),
        ],
      ),
    );
  }
}

/// 「Writer 正在输入…」 under the last message while a member speaks.
class BotTypingLine extends StatelessWidget {
  const BotTypingLine({super.key, required this.bot, required this.label});

  final DsBot bot;
  final String label;

  @override
  Widget build(BuildContext context) {
    final dsh = DshColors.of(context);
    return Row(
      children: [
        BotAvatar(bot: bot, size: GroupMessage.face, working: true),
        const SizedBox(width: GroupMessage.gap),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: dsh.textTertiary),
          ),
        ),
        const SizedBox(width: 6),
        TypingIndicator(color: dsh.textTertiary),
      ],
    );
  }
}

/// The person's message.
class BotUserMessage extends StatelessWidget {
  const BotUserMessage({super.key, required this.text, this.pending = false, this.images = 0});

  final String text;
  final bool pending;
  final int images;

  @override
  Widget build(BuildContext context) {
    if (dshUiReplyChip(text) case final label?) return DshUiReplyChip(label: label, pending: pending);
    final l10n = context.l10n;
    final shown = images > 0 && text.isEmpty ? l10n.botsImagePlaceholder : text;
    return Align(
      alignment: Alignment.centerRight,
      child: UserBubble(text: shown, pendingLabel: pending ? l10n.botsSending : null),
    );
  }
}

// ── Cards ────────────────────────────────────────────────────────────────────

/// A question card from `ask_user`: the options as capsules (one or several),
/// an own answer when the Bot allows it, 「发送」.
class BotQuestionCard extends StatefulWidget {
  const BotQuestionCard({super.key, required this.question, required this.onAnswer, required this.onDismiss});

  final DsBotQuestion question;
  final Future<bool> Function(List<String> selected, String? custom) onAnswer;
  final VoidCallback onDismiss;

  @override
  State<BotQuestionCard> createState() => _BotQuestionCardState();
}

class _BotQuestionCardState extends State<BotQuestionCard> {
  final Set<String> _picked = {};
  final _custom = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final custom = _custom.text.trim();
    setState(() => _sending = true);
    final ok = await widget.onAnswer(_picked.toList(), custom.isEmpty ? null : custom);
    if (mounted && !ok) setState(() => _sending = false);
  }

  void _tap(String label) {
    HapticFeedback.selectionClick();
    setState(() {
      if (widget.question.multiSelect) {
        _picked.contains(label) ? _picked.remove(label) : _picked.add(label);
      } else {
        _picked
          ..clear()
          ..add(label);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final q = widget.question;
    final ready = _picked.isNotEmpty || _custom.text.trim().isNotEmpty;
    return ChatCard(
      icon: AppIcons.question,
      title: q.question,
      titleMaxLines: 3,
      tone: ChatCardTone.ask,
      trailing: CardCloseKey(onTap: widget.onDismiss),
      children: [
        if (q.detail case final detail?)
          Padding(
            padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, 8),
            child: Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in q.options)
                Tooltip(
                  message: option.description ?? '',
                  child: CapsuleChoiceChip(
                    label: option.label,
                    selected: _picked.contains(option.label),
                    onSelected: () {
                      if (!_sending) _tap(option.label);
                    },
                  ),
                ),
            ],
          ),
        ),
        if (q.allowCustom)
          Padding(
            padding: const EdgeInsets.fromLTRB(ChatCard.inset, 8, ChatCard.inset, 0),
            child: TextField(
              controller: _custom,
              enabled: !_sending,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: l10n.botsWriteOwn, isDense: true),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(ChatCard.inset, 12, ChatCard.inset, ChatCard.inset),
          child: Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              style: cardButton,
              onPressed: ready && !_sending ? _send : null,
              child: Text(l10n.commonSend),
            ),
          ),
        ),
      ],
    );
  }
}

/// A view card from `show_view` that waits: its text, then the first thing to
/// answer (options, a confirmation or a short form).
class BotViewCard extends StatefulWidget {
  const BotViewCard({super.key, required this.view, required this.onAnswer, required this.onDismiss, this.onOpenInWeb});

  final DsBotViewCard view;
  final VoidCallback? onOpenInWeb;
  final Future<bool> Function(String action, Map<String, Object?> values) onAnswer;
  final VoidCallback onDismiss;

  @override
  State<BotViewCard> createState() => _BotViewCardState();
}

// Unseen inputs must never turn into silently submitted server defaults.
bool canRenderBotView(Map<String, Object?> view) => !_viewFormula(view) && _nativeViewNode(view);

bool _viewFormula(Object? value) {
  if (value is Map) {
    if (value.containsKey('=') ||
        (value['let'] != null && (value['let'] is! Map || (value['let'] as Map).isNotEmpty))) {
      return true;
    }
    return value.values.any(_viewFormula);
  }
  return value is List && value.any(_viewFormula);
}

bool _viewScalar(Object? value) => value is String || value is bool || (value is num && value.isFinite);
bool _optionalViewText(Object? value) => value == null || value is String;

bool _nativeViewNode(Object? node, [int depth = 0]) {
  if (node is! Map || depth > 6) return false;
  final id = node['id'];
  final actionId = id is String && id.isNotEmpty;
  return switch (node['type']) {
    'text' => node['text'] is String,
    'metric' => node['label'] is String && _viewScalar(node['value']) && node['caption'] == null,
    'progress' =>
      node['percent'] is num &&
          (node['percent'] as num).isFinite &&
          _optionalViewText(node['label']) &&
          node['value'] == null &&
          node['max'] == null &&
          node['valueLabel'] == null,
    'submit' => actionId && _optionalViewText(node['label']),
    'confirm' => actionId && _optionalViewText(node['confirmLabel']) && _optionalViewText(node['cancelLabel']),
    'options' =>
      actionId &&
          node['options'] is List &&
          (node['options'] as List).isNotEmpty &&
          (node['options'] as List).every(
            (option) => option is Map && option['label'] is String && _optionalViewText(option['description']),
          ),
    'form' =>
      actionId &&
          _optionalViewText(node['submitLabel']) &&
          node['fields'] is List &&
          (node['fields'] as List).every(
            (field) =>
                field is Map &&
                field['id'] is String &&
                field['label'] is String &&
                _optionalViewText(field['placeholder']),
          ),
    'choice' => _validViewChoice(node),
    'stack' ||
    'row' => node['children'] is List && (node['children'] as List).every((child) => _nativeViewNode(child, depth + 1)),
    _ => false,
  };
}

Object? _viewChoiceValue(Map option) => option['value'] ?? option['label'];

bool _validViewChoice(Map node) {
  if (node['id'] is! String || (node['id'] as String).isEmpty || node['label'] is! String) return false;
  final options = node['options'];
  if (options is! List || options.isEmpty) return false;
  final values = <Object?>{};
  final labels = <String>{};
  for (final option in options) {
    if (option is! Map || option['label'] is! String || (option['label'] as String).trim().isEmpty) return false;
    final value = _viewChoiceValue(option);
    if (value is! String && value is! bool && !(value is num && value.isFinite)) return false;
    if (!values.add(value) || !labels.add(option['label'] as String)) return false;
  }
  return values.contains(node['value'] ?? _viewChoiceValue(options.first as Map));
}

List<Map<String, Object?>> _viewChoices(Map<String, Object?> view) {
  if (!canRenderBotView(view)) return const [];
  final choices = <Map<String, Object?>>[];
  void walk(Map node) {
    if (node['type'] == 'choice') choices.add(node.cast<String, Object?>());
    if (node['type'] == 'stack' || node['type'] == 'row') {
      for (final child in node['children'] as List) {
        walk(child as Map);
      }
    }
  }

  walk(view);
  return choices;
}

/// What a view card shows: its lines and the component to answer.
({List<String> lines, Map<String, Object?>? control}) readView(Map<String, Object?> view) {
  final lines = <String>[];
  if (!canRenderBotView(view)) return (lines: lines, control: null);
  Map<String, Object?>? control;
  void walk(Object? node, int depth) {
    if (node is! Map || depth > 6) return;
    final type = node['type'];
    switch (type) {
      case 'text':
        if (node['text'] case final String text when text.trim().isNotEmpty) lines.add(text.trim());
      case 'metric':
        lines.add(appL10n.botsViewMetric(node['label'] ?? '', node['value'] ?? ''));
      case 'progress':
        final label = node['label'];
        lines.add('${label is String && label.isNotEmpty ? '$label ' : ''}${node['percent'] ?? 0}%');
      case 'options' || 'confirm' || 'form' || 'submit':
        control ??= node.cast<String, Object?>();
      default:
        break;
    }
    final children = node['children'];
    if (children is List) {
      for (final child in children) {
        walk(child, depth + 1);
      }
    }
  }

  walk(view, 0);
  return (lines: lines, control: control);
}

class _BotViewCardState extends State<BotViewCard> {
  final Set<String> _picked = {};
  final Map<String, Object?> _choiceValues = {};
  final Map<String, TextEditingController> _fields = {};
  bool _sending = false;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _answer(String action, Map<String, Object?> values) async {
    if (_sending || !canRenderBotView(widget.view.view)) return;
    final choices = _viewChoices(widget.view.view);
    final answer = {
      ...values,
      if (choices.isNotEmpty)
        'inputs': {for (final choice in choices) choice['id'] as String: _choiceValues[choice['id']]},
    };
    setState(() => _sending = true);
    final ok = await widget.onAnswer(action, answer);
    if (mounted && !ok) setState(() => _sending = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    if (!canRenderBotView(widget.view.view)) {
      return ChatCard(
        icon: AppIcons.panel,
        title: widget.view.title,
        titleMaxLines: 2,
        tone: ChatCardTone.ask,
        trailing: CardCloseKey(onTap: widget.onDismiss),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(ChatCard.inset, 4, ChatCard.inset, ChatCard.inset),
            child: FilledButton(
              key: const ValueKey('bot-view-open-web'),
              onPressed: widget.onOpenInWeb,
              child: Text(l10n.commonOpenInWeb, textAlign: TextAlign.center),
            ),
          ),
        ],
      );
    }
    final (:lines, :control) = readView(widget.view.view);
    final id = control?['id'] as String? ?? '';
    final choices = _viewChoices(widget.view.view);
    final children = <Widget>[
      for (final line in lines)
        Padding(
          padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, 6),
          child: Text(line, style: theme.textTheme.bodyMedium),
        ),
    ];
    for (final choice in choices) {
      final choiceId = choice['id'] as String;
      final options = (choice['options'] as List).cast<Map>();
      _choiceValues.putIfAbsent(choiceId, () => choice['value'] ?? _viewChoiceValue(options.first));
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(ChatCard.inset, 4, ChatCard.inset, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(choice['label'] as String, style: theme.textTheme.bodyMedium),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final option in options)
                    CapsuleChoiceChip(
                      label: option['label'] as String,
                      selected: _choiceValues[choiceId] == _viewChoiceValue(option),
                      onSelected: () {
                        if (_sending) return;
                        setState(() => _choiceValues[choiceId] = _viewChoiceValue(option));
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    switch (control?['type']) {
      case 'submit':
        children.add(
          _CardActions(
            children: [
              Flexible(
                child: FilledButton(
                  style: cardButton,
                  onPressed: _sending ? null : () => _answer(id, const {}),
                  child: Text(control!['label'] as String? ?? l10n.commonSend, textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        );
      case 'options':
        final multi = control!['multi'] == true;
        final options = [
          for (final o in (control['options'] as List?) ?? const [])
            if (o is Map && o['label'] is String) o['label'] as String,
        ];
        children
          ..add(
            Padding(
              padding: const EdgeInsets.fromLTRB(ChatCard.inset, 4, ChatCard.inset, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final label in options)
                    CapsuleChoiceChip(
                      label: label,
                      selected: _picked.contains(label),
                      onSelected: () {
                        if (_sending) return;
                        setState(() {
                          if (multi) {
                            _picked.contains(label) ? _picked.remove(label) : _picked.add(label);
                          } else {
                            _picked
                              ..clear()
                              ..add(label);
                          }
                        });
                      },
                    ),
                ],
              ),
            ),
          )
          ..add(
            _CardActions(
              children: [
                FilledButton(
                  style: cardButton,
                  onPressed: _picked.isEmpty || _sending ? null : () => _answer(id, {'selected': _picked.toList()}),
                  child: Text(l10n.commonSend),
                ),
              ],
            ),
          );
      case 'confirm':
        children.add(
          _CardActions(
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: _sending ? null : () => _answer(id, {'confirmed': false}),
                child: Text(control!['cancelLabel'] as String? ?? l10n.commonCancel),
              ),
              FilledButton(
                style: cardButton,
                onPressed: _sending ? null : () => _answer(id, {'confirmed': true}),
                child: Text(control['confirmLabel'] as String? ?? l10n.commonConfirm),
              ),
            ],
          ),
        );
      case 'form':
        final fields = [
          for (final f in (control!['fields'] as List?) ?? const [])
            if (f is Map && f['id'] is String) f.cast<String, Object?>(),
        ];
        for (final field in fields) {
          final controller = _fields.putIfAbsent(field['id']! as String, TextEditingController.new);
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(ChatCard.inset, 4, ChatCard.inset, 4),
              child: TextField(
                controller: controller,
                enabled: !_sending,
                decoration: InputDecoration(
                  labelText: field['label'] as String? ?? '',
                  hintText: field['placeholder'] as String?,
                  isDense: true,
                ),
              ),
            ),
          );
        }
        children.add(
          _CardActions(
            children: [
              FilledButton(
                style: cardButton,
                onPressed: _sending
                    ? null
                    : () => _answer(id, {
                        'fields': {for (final e in _fields.entries) e.key: e.value.text},
                      }),
                child: Text(control['submitLabel'] as String? ?? l10n.botsSubmit),
              ),
            ],
          ),
        );
      default:
        children.add(const SizedBox(height: ChatCard.inset - 6));
    }
    return ChatCard(
      icon: AppIcons.panel,
      title: widget.view.title,
      titleMaxLines: 2,
      tone: ChatCardTone.ask,
      trailing: CardCloseKey(onTap: widget.onDismiss),
      children: children,
    );
  }
}

class _CardActions extends StatelessWidget {
  const _CardActions({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(ChatCard.inset, 12, ChatCard.inset, ChatCard.inset),
    child: Row(mainAxisAlignment: MainAxisAlignment.end, spacing: 8, children: children),
  );
}

/// A Bot that waits for its model before it greets.
class BotModelCard extends StatelessWidget {
  const BotModelCard({super.key, required this.name, required this.onPick});

  final String name;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) => ChatCard(
    icon: AppIcons.model,
    title: context.l10n.botsChooseModelFor(name),
    tone: ChatCardTone.ask,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(ChatCard.inset, 0, ChatCard.inset, ChatCard.inset),
        child: Row(
          children: [
            Expanded(
              child: Text(
                context.l10n.botsModelGreeting,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
              ),
            ),
            FilledButton(onPressed: onPick, child: Text(context.l10n.botsChooseModel)),
          ],
        ),
      ),
    ],
  );
}

/// The ✕ at the end of a card's title row, the size of the title's icon so the
/// two line up.
class CardCloseKey extends StatelessWidget {
  const CardCloseKey({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: context.l10n.botsSkipAnswer,
    child: InkResponse(
      onTap: onTap,
      radius: 18,
      child: SizedBox.square(
        dimension: 20,
        child: Icon(AppIcons.close, size: 18, color: DshColors.of(context).textTertiary),
      ),
    ),
  );
}

/// The compact buttons at the foot of a card.
final cardButton = FilledButton.styleFrom(
  minimumSize: const Size(0, 36),
  padding: const EdgeInsets.symmetric(horizontal: 20),
  visualDensity: VisualDensity.compact,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
);
