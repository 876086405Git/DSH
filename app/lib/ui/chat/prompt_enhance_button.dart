// 提示词增强按钮（composer 右侧、发送键左边）。
//
// 三态由内容推导，不做独立开关：
//   idle  ✨  —— 输入框有内容时点一下发起增强
//   busy  ✨  —— 请求在途，1.6s 周期在 0.3~1 不透明度之间闪烁；再点取消
//   undo  ↺   —— 当前草稿仍等于刚填入的结果，点一下恢复原文
//
// 无边框、透明背景、无描边与焦点光圈；系统开启「减少动态效果」时静止显示。

import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../state/prompt_enhance_state.dart';
import '../theme/theme.dart';

class PromptEnhanceButton extends StatefulWidget {
  const PromptEnhanceButton({
    super.key,
    required this.controller,
    required this.phase,
    required this.undoResult,
    required this.connected,
    required this.ready,
    required this.onEnhance,
    required this.onCancel,
    required this.onUndo,
  });

  /// 当前输入框：撤销是否成立、是否可点都由它的内容决定。
  final TextEditingController controller;
  final PromptEnhancePhase phase;

  /// 刚填入的增强结果（`undo` 时非空）。
  final String? undoResult;
  final bool connected;

  /// 会话/连接已就绪，可以发请求。
  final bool ready;
  final VoidCallback onEnhance;
  final VoidCallback onCancel;
  final VoidCallback onUndo;

  /// 闪烁周期（与桌面版一致）。
  static const Duration blinkPeriod = Duration(milliseconds: 1600);
  static const double _size = 36;

  @override
  State<PromptEnhanceButton> createState() => _PromptEnhanceButtonState();
}

class _PromptEnhanceButtonState extends State<PromptEnhanceButton> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: PromptEnhanceButton.blinkPeriod ~/ 2,
  );

  @override
  void didUpdateWidget(PromptEnhanceButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncBlink();
  }

  @override
  void initState() {
    super.initState();
    // 这里不能读 MediaQuery（initState 里做 inherited 查询会报错）：
    // didChangeDependencies 紧随其后执行，闪烁状态在那里同步。
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统的「减少动态效果」可能在页面存续期间被切换。
    _syncBlink();
  }

  void _syncBlink() {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final busy = widget.phase == PromptEnhancePhase.busy;
    if (busy && !reduceMotion && !_blink.isAnimating) {
      _blink.repeat(reverse: true);
    } else if ((!busy || reduceMotion) && _blink.isAnimating) {
      _blink.stop();
      _blink.value = 1;
    } else if (_blink.value != 1 && (!busy || reduceMotion)) {
      _blink.value = 1;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final text = value.text;
        final canUndo = widget.undoResult != null && widget.undoResult == text;
        final busy = widget.phase == PromptEnhancePhase.busy;
        final idleEnabled = widget.connected && widget.ready && text.trim().isNotEmpty;
        final enabled = busy || canUndo || idleEnabled;
        final icon = canUndo
            ? Icons.undo_rounded
            // busy 与 idle 是同一个 ✨：生成中靠闪烁，不换图标。
            : Icons.auto_awesome_outlined;
        final label = canUndo
            ? l10n.chatEnhanceUndoAction
            : busy
            ? l10n.chatEnhanceCancelAction
            : l10n.chatEnhanceAction;
        final tint = enabled ? colors.onSurfaceVariant : DshColors.of(context).textTertiary;
        return Semantics(
          button: enabled,
          label: label,
          excludeSemantics: true,
          child: InkResponse(
            onTap: !enabled
                ? null
                : canUndo
                ? widget.onUndo
                : busy
                ? widget.onCancel
                : widget.onEnhance,
            radius: 24,
            containedInkWell: false,
            highlightShape: BoxShape.circle,
            child: SizedBox(
              width: PromptEnhanceButton._size,
              height: PromptEnhanceButton._size,
              child: Center(
                child: FadeTransition(
                  opacity: busy && !reduceMotion
                      ? Tween<double>(begin: 0.3, end: 1).animate(CurvedAnimation(parent: _blink, curve: Curves.easeInOut))
                      : const AlwaysStoppedAnimation<double>(1),
                  child: Icon(icon, size: 20, color: enabled ? tint : tint.withValues(alpha: 0.55)),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
