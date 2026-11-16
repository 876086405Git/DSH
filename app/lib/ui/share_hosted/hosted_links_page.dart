// 「我的分享链接」, a list page: every hosted link made on this phone, with when it
// stops working, copy and delete. Delete asks first, then can be undone for a
// few seconds before the link is removed from the host.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_hosted/hosted_client.dart' show HostedShareError;
import '../../share_hosted/hosted_link.dart';
import '../../share_hosted/hosted_links_state.dart';
import '../common/app_dialog.dart';
import '../common/list_page_row.dart';
import '../common/smooth_size.dart';
import '../features/feature_kit.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import '../common/brief_notice.dart';

/// 「11 月 24 日到期」「永久有效」「已过期」.
String hostedExpiryText(HostedLink link, DateTime now) => linkExpiryText(link.expiresAt, now);

/// The same for any link that ends at [expiresAt] (null: never).
String linkExpiryText(DateTime? expiresAt, DateTime now) {
  final expires = expiresAt?.toLocal();
  if (expires == null) return appL10n.remoteHostedNeverExpires;
  if (!now.isBefore(expires)) return appL10n.remoteHostedExpired;
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(expires.year, expires.month, expires.day);
  final days = day.difference(today).inDays;
  if (days == 0) return appL10n.remoteHostedExpiresToday;
  if (days == 1) return appL10n.remoteHostedExpiresTomorrow;
  final date = expires.year == now.year
      ? appL10n.remoteHostedMonthDate(expires.month.toString(), expires.day)
      : appL10n.remoteHostedYearDate(expires.year, expires.month.toString(), expires.day);
  return appL10n.remoteHostedExpiresOn(date);
}

class HostedLinksPage extends ConsumerStatefulWidget {
  const HostedLinksPage({super.key, this.clock = DateTime.now});

  final DateTime Function() clock;

  static Route<void> route() => MaterialPageRoute(builder: (_) => const HostedLinksPage());

  @override
  ConsumerState<HostedLinksPage> createState() => _HostedLinksPageState();
}

class _HostedLinksPageState extends ConsumerState<HostedLinksPage> {
  @override
  void initState() {
    super.initState();
    // A previously failed read gets another attempt when the page opens.
    Future.microtask(() {
      if (mounted) {
        final links = ref.read(hostedLinksProvider.notifier);
        if (links.isHarmonyOS) unawaited(links.ensureLoaded());
      }
    });
  }

  void _toast(BuildContext context, String text, {SnackBarAction? action, Duration? duration}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(content: Text(text), action: action, duration: duration ?? const Duration(seconds: 4), persist: false),
    );
  }

  Future<void> _copy(BuildContext context, HostedLink link) async {
    await Clipboard.setData(ClipboardData(text: link.url));
    if (context.mounted) showBriefNotice(context, context.l10n.remoteLinkCopied);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, HostedLink link) async {
    final ok = await showAppDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.remoteHostedDeleteTitle),
        content: Text(context.l10n.remoteHostedDeleteBody(link.title)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DshColors.of(dialog).danger,
              foregroundColor: DshColors.of(dialog).onDanger,
            ),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    // Undo can come after the page closed: hold on to the notifier.
    final links = ref.read(hostedLinksProvider.notifier);
    final removed = await links.remove(link.id);
    if (!context.mounted) return;
    if (links.isHarmonyOS && !removed) {
      _toast(context, context.l10n.remoteHostedDeleteSaveFailed);
      return;
    }
    _toast(
      context,
      context.l10n.remoteHostedLinkDeleted,
      duration: HostedLinksController.undoWindow,
      action: SnackBarAction(
        label: context.l10n.remoteUndo,
        onPressed: () async {
          final result = await links.undo(link.id);
          if (!context.mounted) return;
          if (!links.isHarmonyOS) return;
          if (result == HostedUndoResult.sessionOnly) _toast(context, context.l10n.remoteHostedUndoUnsaved);
          if (result == HostedUndoResult.unavailable) _toast(context, context.l10n.remoteHostedUndoFailed);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    ref.listen(hostedLinksProvider.select((s) => s.failure), (before, failure) {
      if (failure != null && !identical(before, failure)) _toast(context, _failureText(failure));
    });
    final state = ref.watch(hostedLinksProvider);
    final links = state.visible;
    final now = widget.clock();
    return AppPage.list(
      title: l10n.remoteHostedMyLinks,
      children: [
        if (state.storageError != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Column(
              children: [
                Text(state.loaded ? l10n.remoteHostedSaveFailed : l10n.remoteHostedLoadFailed),
                TextButton(
                  onPressed: () => unawaited(ref.read(hostedLinksProvider.notifier).retry()),
                  child: Text(l10n.commonRetry),
                ),
              ],
            ),
          ),
        if (!state.loaded && state.storageError == null)
          const QuietSpinner()
        else if (state.loaded && links.isEmpty)
          EmptyView(
            icon: AppIcons.link,
            title: l10n.remoteHostedNoLinks,
            padding: const EdgeInsets.fromLTRB(32, 40, 32, 24),
          )
        else if (state.loaded)
          SmoothSize(
            duration: AppMotion.of(context, AppMotion.standard),
            curve: AppMotion.std,
            alignment: Alignment.topCenter,
            child: ListPageCard(
              children: [
                for (final (i, link) in links.indexed)
                  FadeSlideIn(
                    key: ValueKey(link.id),
                    index: i,
                    child: HostedLinkRow(
                      link: link,
                      now: now,
                      onCopy: () => unawaited(_copy(context, link)),
                      onDelete: () => unawaited(_delete(context, ref, link)),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  static String _failureText(HostedDeleteFailure failure) => switch (failure.error.kind) {
    HostedShareError.network => appL10n.remoteHostedErrDeleteNetwork,
    HostedShareError.forbidden => appL10n.remoteHostedErrForbidden,
    _ => appL10n.remoteHostedErrDelete,
  };
}

/// One link: title, when it stops working, copy and delete.
class HostedLinkRow extends StatelessWidget {
  const HostedLinkRow({super.key, required this.link, required this.now, required this.onCopy, required this.onDelete});

  final HostedLink link;
  final DateTime now;
  final VoidCallback onCopy;
  final VoidCallback onDelete;

  /// Compact icon button: 40 box, 20 glyph, so 10 of air at each side.
  static const _buttonAir = 10.0;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = DshColors.of(context);
    final expired = link.isExpired(now);
    Widget button(String key, IconData icon, String tooltip, VoidCallback? onPressed) => IconButton(
      key: ValueKey('hosted-$key-${link.id}'),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      color: colors.textTertiary,
      icon: Icon(icon, size: 20),
      onPressed: onPressed,
    );
    return ListPageRow(
      icon: AppIcons.link,
      iconColor: expired ? colors.textDisabled : null,
      title: link.title,
      subtitle: hostedExpiryText(link, now),
      trailing: Transform.translate(
        // The last glyph ends 16 from the card edge, where a row's text ends.
        offset: const Offset(_buttonAir, 0),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            button('copy', AppIcons.copy, l10n.commonCopyLink, expired ? null : onCopy),
            button('delete', AppIcons.delete, l10n.commonDelete, onDelete),
          ],
        ),
      ),
    );
  }
}
