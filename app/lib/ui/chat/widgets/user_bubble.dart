// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/material.dart';

import '../../../state/composer_quote.dart' show splitQuote;
import '../../common/expand_reveal.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../media/generate_header.dart';
import '../media/media_format.dart' show mediaParamsLine;
import '../mention/mention_chip.dart';
import '../secret_mask.dart';
import 'message_actions.dart';
import 'message_selection.dart';
import 'quote_chip.dart';

/// 用户消息:**右对齐的软气泡**,比页面深一档,像"按进去"的。
///
/// 禁配:气泡底上只用主文字 / 次级文字;三级文字(4.32)与主色(4.22)
/// 不过 AA。
///
/// 长按气泡里的字就地选字([MessageSelection]);选区上的「更多」打开菜单:复制 /
/// 选择文字 / 引用 / 编辑后重发([onEdit])。
///
/// 以引用块开头的消息(引用追问),引文画在气泡顶部([BubbleQuote]),
/// 下面是正文;复制、选择文字、编辑拿到的仍是发出去的原文。
///
/// 可识别的凭据(API Key、令牌、私钥、地址里的密码)只在屏幕上遮挡
/// ([SecretText]);复制、选择文字、编辑拿到的都是原文。已发送的消息每段
/// 带眼睛可以显示,乐观气泡只遮挡。
class UserBubble extends StatelessWidget {
  const UserBubble({
    super.key,
    required this.text,
    this.attachments,
    this.pendingLabel,
    this.pendingIcon = AppIcons.queued,
    this.pendingActions = const [],
    this.onEdit,
    this.onQuote,
  });

  final String text;

  /// Images and file cards, shown right-aligned above the bubble (附件不塞进
  /// 气泡里)。
  final Widget? attachments;

  /// 非空 = 乐观气泡(还没被 DSH 回显),显示在气泡下方("发送中" / "排队中")。
  final String? pendingLabel;
  final IconData pendingIcon;

  /// Small text actions after the pending label ("改为插话", "撤回").
  final List<(String, VoidCallback)> pendingActions;

  /// "编辑后重发" in the long-press menu; null leaves it out (optimistic
  /// bubbles: they have "撤回" instead).
  final VoidCallback? onEdit;

  /// "引用" in the long-press menu (and in 选择文字); null leaves it out.
  final ValueChanged<String>? onQuote;

  /// What the bubble shows: a generation request without its header.
  String get _shown => GenerateHeader.parse(text)?.description ?? text;

  Future<void> _menu(BuildContext context) async {
    final onEdit = this.onEdit;
    final onQuote = this.onQuote;
    final action = await showMessageMenu(
      context,
      // 菜单顶部的预览也是显示,同样遮挡;预览会把 `**` 当粗体删掉,
      // 所以这里用 •。
      text: maskSecrets(_shown, mark: '•'),
      actions: [
        MessageAction.copy,
        MessageAction.selectText,
        if (onQuote != null) MessageAction.quote,
        if (onEdit != null) MessageAction.edit,
      ],
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case MessageAction.copy:
        await copyMessage(context, _shown);
      case MessageAction.selectText:
        await showSelectTextSheet(context, _shown, onQuote: onQuote);
      case MessageAction.edit:
        onEdit?.call();
      case MessageAction.quote:
        // The message's own words: an earlier quote it opened with stays out.
        onQuote?.call(splitQuote(_shown).body);
      case MessageAction.share || MessageAction.readAloud || MessageAction.regenerate || MessageAction.branch:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final surfaces = DshSurfaces.of(context);
    final style = AppType.chatBody(context, color: surfaces.onUserBubble);
    // A generation request (generation mode's parameter header on the first
    // line): the description is the bubble, the parameters a small line under
    // the bubble; the header itself is for the host's plugin.
    final generate = GenerateHeader.parse(text);
    final shown = generate?.description ?? text;
    final (:quote, :body) = splitQuote(shown);
    final interactive = pendingLabel == null;
    // Long-press selects in place. `@` references draw as chips; text with a
    // credential stays a plain SecretText.
    Widget content = ReferenceText(quote == null ? shown : body, style: style, interactive: interactive);
    if (quote != null) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // The quote is display too: credentials in it stay masked.
          BubbleQuote(maskSecrets(quote, mark: '•')),
          if (body.isNotEmpty) ...[const SizedBox(height: 6), content],
        ],
      );
    }

    // Its own semantics node, carrying the text; a screen reader's long-press
    // opens the menu.
    final bubble = Semantics(
      container: true,
      header: true,
      onLongPress: () => _menu(context),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: surfaces.userBubble, shape: AppShape.bubble),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: MessageSelection(text: _shown, onQuote: onQuote, onMore: () => _menu(context), child: content),
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth * 0.82;
        // Explicit nodes: the bubble's long-press node must not pull the
        // attachments' labels into one merged node.
        return Semantics(
          explicitChildNodes: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (attachments case final a?)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: pendingLabel == null ? a : Opacity(opacity: 0.72, child: a),
                ),
              if (attachments != null && shown.trim().isNotEmpty) const SizedBox(height: 8),
              if (shown.trim().isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: AnimatedOpacity(
                    opacity: pendingLabel == null ? 1 : 0.72,
                    duration: AppMotion.of(context, AppMotion.quick),
                    child: bubble,
                  ),
                ),
              if (generate case (:final header, description: _))
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxWidth),
                  child: Padding(
                    padding: EdgeInsets.only(
                      top: shown.trim().isEmpty && attachments == null ? 0 : GenerateParamsLine.gap,
                      right: GenerateParamsLine.inset,
                    ),
                    child: GenerateParamsLine(header: header),
                  ),
                ),
              _PendingSlot(label: pendingLabel, icon: pendingIcon, actions: pendingActions),
            ],
          ),
        );
      },
    );
  }
}

/// [_PendingMeta] 的位置:回显时(同一行,标签变成 null)这一行和输入条上
/// 的胶囊同一节奏收起,气泡平稳落位,不会"啪"地矮一截。收起途中还画着
/// 最后一次的状态。
class _PendingSlot extends StatefulWidget {
  const _PendingSlot({required this.label, required this.icon, required this.actions});

  final String? label;
  final IconData icon;
  final List<(String, VoidCallback)> actions;

  @override
  State<_PendingSlot> createState() => _PendingSlotState();
}

class _PendingSlotState extends State<_PendingSlot> {
  late _PendingMeta? _last = _meta();

  _PendingMeta? _meta() => switch (widget.label) {
    final label? => _PendingMeta(label: label, icon: widget.icon, actions: widget.actions),
    null => null,
  };

  @override
  void didUpdateWidget(_PendingSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Echoed: keep the last line (without its buttons) while it folds away.
    _last =
        _meta() ??
        switch (_last) {
          final last? => _PendingMeta(label: last.label, icon: last.icon, actions: const []),
          null => null,
        };
  }

  @override
  Widget build(BuildContext context) => ExpandReveal(
    open: widget.label != null,
    duration: AppMotion.standard,
    curve: AppMotion.std,
    child: Align(alignment: Alignment.centerRight, child: _last ?? const SizedBox.shrink()),
  );
}

/// 乐观气泡下方的状态与文字操作;放不下时按可用宽度换行。
///
/// 右端与气泡的直边对齐(缩进 8):只有状态时状态文字留 8;有操作时最后
/// 一个操作自带左右 8 的点按区,文字同样停在 8 处。
class _PendingMeta extends StatelessWidget {
  const _PendingMeta({required this.label, required this.icon, required this.actions});

  final String label;
  final IconData icon;
  final List<(String, VoidCallback)> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = DshColors.of(context).textTertiary;
    final style = theme.textTheme.labelSmall?.copyWith(color: muted);
    return Padding(
      padding: EdgeInsets.only(top: actions.isEmpty ? 4 : 0, right: actions.isEmpty ? 8 : 0),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: muted),
              const SizedBox(width: 4),
              Flexible(child: Text(label, style: style)),
            ],
          ),
          for (final (text, onTap) in actions)
            TextButton(
              onPressed: onTap,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.padded,
                visualDensity: VisualDensity.compact,
                textStyle: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
              ),
              child: Text(text),
            ),
        ],
      ),
    );
  }
}

/// 「图像 · 3:4 · 2 张」 under a generation request: the pending line's look
/// (12 icon, small tertiary text), its right end 8 in from the bubble's
/// straight edge.
class GenerateParamsLine extends StatelessWidget {
  const GenerateParamsLine({super.key, required this.header});

  final GenerateHeader header;

  /// Bubble → line.
  static const gap = 4.0;

  /// The bubble's right edge → the line's end.
  static const inset = 8.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = DshColors.of(context).textTertiary;
    final video = header.kind == GenerateKind.video;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(video ? AppIcons.generateVideo : AppIcons.generateImage, size: 12, color: muted),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            mediaParamsLine(
              video: video,
              aspect: header.aspect,
              count: header.count,
              seconds: header.seconds,
              resolution: header.resolution,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: muted)),
          ),
        ),
      ],
    );
  }
}
