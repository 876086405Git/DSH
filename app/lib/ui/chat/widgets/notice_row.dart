import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/subscriptions_state.dart' show subscriptionLabel;
import '../../common/expand_reveal.dart';
import '../../onboarding/api_key_page.dart';
import '../../providers/providers_page.dart';
import '../../providers/subscription_sheet.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'stream_row.dart';
import 'turn_failure_text.dart';

/// pi-ai's wording when a subscription's stored grant can't be refreshed
/// (revoked, expired, signed out elsewhere) or is gone from its route.
final _grantLost = RegExp(
  r'OAuth (?:refresh failed|refresh returned a token that expires too soon'
  r'|auth derivation failed) for ([\w.-]+)'
  r'|no credential for provider route "([\w.-]+)"',
);

/// The subscription (ChatGPT, Claude) whose sign-in a turn [failure] says
/// has lapsed; null for any other failure.
Subscription? lapsedSubscription(LlmFailure? failure, [String text = '']) {
  for (final source in [?failure?.message, text]) {
    final m = _grantLost.firstMatch(source);
    if (m == null) continue;
    return Subscription.fromWire(m.group(1) ?? m.group(2));
  }
  return null;
}

/// 说明行行尾的一个键(「重试」「继续」)。
typedef NoticeAction = ({String label, VoidCallback onPressed});

/// 一轮结束时的说明行:出错 / 停止 / 重试 / 输出上限……
///
/// 和过程行同一套几何([StreamRow]):图标在 24 的图形列里居中,文字从 32 起。
/// 出错时图形是 danger 浅底的小方块、文字 danger 色;其余只是一行三级文字,
/// 不打断阅读。带错误详情的点一下,下面展开原始的错误码和消息。
class NoticeRow extends StatefulWidget {
  const NoticeRow({super.key, required this.item, this.action});

  final NoticeChatItem item;
  final NoticeAction? action;

  @override
  State<NoticeRow> createState() => _NoticeRowState();
}

class _NoticeRowState extends State<NoticeRow> {
  bool _expanded = false;
  NoticeChatItem get item => widget.item;

  static final _retryCount = RegExp(r'\((\d+)(?:/(\d+))?\)');

  (IconData, String) _content(Subscription? lapsed) {
    final failure = item.failure;
    switch (item.kind) {
      case 'error':
        if (lapsed != null) {
          return (AppIcons.noApiKey, appL10n.chatSubscriptionExpired(subscriptionLabel(lapsed)));
        }
        if (failure?.code == 'MISSING_CREDENTIAL') {
          // pi-ai routes are the 模型渠道; the bare one is DeepSeek's key.
          if (failure!.message.startsWith('llm-pi-ai')) {
            return (AppIcons.noApiKey, appL10n.chatProviderKeyMissing);
          }
          return (AppIcons.noApiKey, appL10n.chatDeepSeekKeyMissing);
        }
        return (AppIcons.error, turnFailureText(failure?.code, message: failure?.message));
      case 'aborted':
        return (AppIcons.stopped, appL10n.commonStopped);
      case 'max-tokens':
        return (AppIcons.outputLimit, appL10n.chatOutputLimitReached);
      case 'blocked':
        return (AppIcons.blocked, appL10n.chatTurnBlocked);
      case 'interrupted':
        return (AppIcons.restart, appL10n.chatTurnEngineRestarted);
      case 'retry':
        final m = _retryCount.firstMatch(item.text);
        final text = m == null
            ? appL10n.chatRequestRetrying
            : m.group(2) == null
            ? appL10n.chatRequestRetryAttempt(int.parse(m.group(1)!))
            : appL10n.chatRequestRetryLimit(int.parse(m.group(1)!), int.parse(m.group(2)!));
        return (AppIcons.retry, text);
      default:
        return (AppIcons.info, item.text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final dsh = DshColors.of(context);
    final isError = item.kind == 'error';
    final lapsed = isError ? lapsedSubscription(item.failure, item.text) : null;
    final (icon, text) = _content(lapsed);
    final style = StreamRow.detail(context)?.copyWith(height: 1.45, color: isError ? dsh.danger : null);

    // 一行最多一个键:登录失效、缺 Key 有自己的去处,其余用列表给的。
    final NoticeAction? action;
    if (lapsed != null) {
      action = (label: l10n.chatSignInAgain, onPressed: () => showSubscriptionLogin(context, lapsed));
    } else if (isError && item.failure?.code == 'MISSING_CREDENTIAL') {
      final pi = item.failure!.message.startsWith('llm-pi-ai');
      action = (
        label: l10n.chatGoToSettings,
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => pi ? const ProvidersPage() : const ApiKeyPage(onboarding: false)),
        ),
      );
    } else {
      action = widget.action;
    }
    final failure = item.failure;
    final details = failure == null ? null : '${failure.code}\n${failure.message}'.trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        StreamRowFrame(
          onTap: details == null ? null : () => setState(() => _expanded = !_expanded),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox.square(
                dimension: StreamRow.lead,
                child: DecoratedBox(
                  // 出错时图形块是 danger 浅底(和工具图标块同形),其余不铺底。
                  decoration: ShapeDecoration(
                    color: isError ? dsh.dangerContainer : null,
                    shape: Squircle.border(StreamRow.lead * 0.32),
                  ),
                  child: Icon(
                    icon,
                    size: isError ? StreamRow.lead * 0.6 : 16,
                    color: isError ? dsh.onDangerContainer : dsh.textTertiary,
                  ),
                ),
              ),
              const SizedBox(width: StreamRow.gap),
              Expanded(
                // 文字首行与 24 的图形格竖直居中。
                child: Padding(
                  padding: const EdgeInsets.only(top: 2.5),
                  child: Text(text, style: style),
                ),
              ),
              AnimatedSwitcher(
                duration: AppMotion.of(context, AppMotion.quick),
                child: action == null
                    ? const SizedBox.shrink()
                    : Padding(
                        key: ValueKey(action.label),
                        padding: const EdgeInsets.only(left: 8),
                        child: _NoticeKey(label: action.label, onPressed: action.onPressed),
                      ),
              ),
            ],
          ),
        ),
        ExpandReveal(
          open: _expanded,
          child: Padding(
            padding: const EdgeInsets.only(left: StreamRow.indent, bottom: 8),
            child: SelectableText(details ?? '', style: StreamRow.detail(context)),
          ),
        ),
      ],
    );
  }
}

/// 行尾的键:和图形格同高(24)的胶囊。
class _NoticeKey extends StatelessWidget {
  const _NoticeKey({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: StreamRow.lead,
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, StreamRow.lead),
          tapTargetSize: MaterialTapTargetSize.padded,
          visualDensity: VisualDensity.compact,
          shape: const StadiumBorder(),
          textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 13),
        ),
        child: Text(label),
      ),
    );
  }
}

/// `ChatState.error` 的行内横幅:浮在输入条上方,可关闭。
/// [info] 用于 `ChatState.notice`:提示而非失败,换成信息色和图标。
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({
    super.key,
    required this.message,
    this.onDismiss,
    this.info = false,
    this.action,
    this.maxLines = 3,
  });

  final String message;
  final VoidCallback? onDismiss;
  final bool info;
  final NoticeAction? action;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final container = info ? dsh.infoContainer : dsh.dangerContainer;
    final accent = info ? dsh.info : dsh.danger;
    final onContainer = info ? dsh.onInfoContainer : dsh.onDangerContainer;
    return Semantics(
      liveRegion: true,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: Color.alphaBlend(container.withValues(alpha: 0.92), theme.colorScheme.surface),
          shape: Squircle.border(AppShape.md, side: BorderSide(color: accent.withValues(alpha: 0.3), width: 0.5)),
          shadows: [
            BoxShadow(
              color: NeutralTones.current(context).shadowInk.withValues(alpha: 0.08),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
          child: Row(
            children: [
              Icon(info ? AppIcons.info : AppIcons.error, size: 17, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  maxLines: maxLines,
                  overflow: maxLines == null ? TextOverflow.visible : TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: onContainer),
                ),
              ),
              if (action case final action?)
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48), foregroundColor: onContainer),
                  onPressed: action.onPressed,
                  child: Text(action.label),
                ),
              if (onDismiss != null)
                IconButton(
                  tooltip: l10n.commonClose,
                  onPressed: onDismiss,
                  iconSize: 18,
                  style: IconButton.styleFrom(minimumSize: const Size(40, 40), foregroundColor: onContainer),
                  icon: const Icon(AppIcons.close),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
