import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../render/code_block.dart';
import 'dsh_ui_dialect_card.dart';
import 'dsh_ui_model.dart';
import 'dsh_ui_reply.dart';
import 'dsh_ui_scope.dart';
import 'dsh_ui_skeleton.dart';
import 'dsh_ui_widgets.dart';
import '../../common/smooth_size.dart';

/// 一个 ```` ```dsh-ui ```` 围栏代码块，接在 `MarkdownBody` 的 `codeBuilder`
/// 后面：
///
/// | 情况 | 显示 |
/// |---|---|
/// | 围栏没闭合、还在流式（代码里有光标哨兵） | 骨架（按半截文本猜形状） |
/// | 围栏没闭合、不在流式（被中断） | 降级：「视图没有生成完」+ 原始代码 |
/// | 闭合，解析失败 / 根节点不认识 / 太大 | 降级：「这个视图格式有误」+ 原始代码 + 「让它重发」 |
/// | 闭合，genui 格式（`DshUiView.dialect`） | 只读的插件视图；整块画不了时降级，但不给「让它重发」 |
/// | 闭合，能画 | 视图卡片 |
///
/// 交互需要的上下文从 [DshUiScope] 读；没有就只读。
class DshUiBlock extends StatefulWidget {
  const DshUiBlock({super.key, required this.source, this.streaming = false, this.closed = true});

  /// 围栏里的文字（已去掉光标哨兵）。
  final String source;

  /// 这条回复还在流式输出，并且光标在这个块里。
  final bool streaming;

  /// 围栏已闭合（gpt_markdown `codeBuilder` 的 `closed`）。
  final bool closed;

  @override
  State<DshUiBlock> createState() => _DshUiBlockState();
}

class _DshUiBlockState extends State<DshUiBlock> {
  /// 这个块在本次显示中流式过：生成完时才播图表生长。翻历史不播。
  bool _sawStreaming = false;
  DshUiSkeleton? _skeleton;
  bool _resending = false;
  bool _resent = false;

  Future<void> _resend(DshUiSend send, String text) async {
    if (_resending || _resent) return;
    setState(() => _resending = true);
    var ok = false;
    try {
      ok = await send(text);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _resending = false;
      _resent = ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final source = widget.source;
    final Widget child;
    final String key;
    if (!widget.closed && widget.streaming) {
      _sawStreaming = true;
      key = 'skeleton';
      final shape = guessDshUiShape(source);
      final previous = _skeleton;
      child = previous != null && previous.shape.title == shape.title && listEquals(previous.shape.parts, shape.parts)
          ? previous
          : DshUiSkeleton(shape: shape);
    } else if (!widget.closed) {
      key = 'interrupted';
      child = DshUiFallback(source: source, message: l10n.viewUiIncomplete);
    } else {
      switch (parseDshUi(source)) {
        case DshUiParsed(:final view) when view.dialect != null:
          key = 'view';
          child = DshUiDialectCard(key: ValueKey(source), view: view, animate: _sawStreaming);
        case DshUiParsed(:final view):
          key = 'view';
          child = DshUiCard(key: ValueKey(source), view: view, animate: _sawStreaming);
        case DshUiInvalid(dialect: _?):
          // Another plugin's format that maps to nothing here: fine where it
          // came from, so no resend.
          key = 'invalid';
          child = DshUiFallback(source: source, message: l10n.viewUiDialectInvalid);
        case DshUiInvalid(:final resendText):
          key = 'invalid';
          final scope = DshUiScope.maybeOf(context);
          final send = scope?.onAskResend;
          final canSend = send != null && scope!.state.canAnswer && !_resent;
          child = DshUiFallback(
            source: source,
            message: l10n.viewUiInvalid,
            busy: _resending,
            onResend: canSend ? () => _resend(send, resendText) : null,
          );
      }
    }
    final duration = AppMotion.of(context, AppMotion.standard);
    _skeleton = child is DshUiSkeleton ? child : null;
    return SmoothSize(
      duration: duration,
      curve: AppMotion.std,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        layoutBuilder: (current, previous) => Stack(alignment: Alignment.topCenter, children: [...previous, ?current]),
        child: KeyedSubtree(key: ValueKey(key), child: child),
      ),
    );
  }
}

/// 降级：一行小字 + 原始代码（JSON 高亮）+ 可选的「让它重发」。
class DshUiFallback extends StatelessWidget {
  const DshUiFallback({super.key, required this.source, required this.message, this.onResend, this.busy = false});

  final String source;
  final String message;

  /// null 时不显示按钮（没有 scope、这一轮还在跑、已经发过或已失效）。
  final VoidCallback? onResend;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              Icon(AppIcons.info, size: 16, color: dsh.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(message, style: theme.textTheme.bodySmall?.copyWith(color: dsh.textTertiary)),
              ),
              if (onResend != null || busy)
                TextButton(
                  onPressed: busy ? null : onResend,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: const StadiumBorder(),
                  ),
                  child: busy
                      ? SizedBox.square(
                          dimension: 14,
                          child: CircularProgressIndicator(strokeWidth: 2, color: theme.colorScheme.primary),
                        )
                      : Text(l10n.viewUiResend),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        CodeBlock(code: source.trim(), language: 'json'),
      ],
    );
  }
}

/// 一条用户消息若是 `[dsh-ui reply]`，给气泡用的小标签文字（「已选择：方案 A」）；
/// 不是返回 null。
String? dshUiReplyChip(String text) => parseDshUiReply(text)?.chipLabel;
