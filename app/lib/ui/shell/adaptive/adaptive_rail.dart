// The folded conversation list of a wide window: a
// column of round keys, like DSH Web's 56px sidebar rail.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/connection_state.dart' show hostNameProvider;
import '../../../state/hosts_state.dart' show activeHostProvider;
import '../../chat/chat_header.dart';
import '../../common/status_dot.dart';
import '../../remote/host_status.dart';
import '../../theme/app_icons.dart';
import '../page_frame.dart' show GlassIconButton;
import 'adaptive_layout.dart';

/// The rail: ≡ (the whole list) and search on top, level with the chat
/// header's keys; the host, 网页版 and 设置 at the bottom, level with the
/// composer's lower edge — the same three the drawer's identity bar holds.
///
/// ```
///  (≡)  ( 修复登录重复提交 )
///  (⌕)
///
///  (▢)
///  (◎)
///  (⚙)  ( 输入消息…        )
/// ```
///
/// No strip behind the keys: they float on the page like the header's.
class AdaptiveRail extends ConsumerWidget {
  const AdaptiveRail({
    super.key,
    required this.onMenu,
    required this.menuTooltip,
    required this.onSearch,
    required this.onHost,
    required this.onWeb,
    required this.onSettings,
  });

  final VoidCallback onMenu;
  final String menuTooltip;
  final VoidCallback onSearch;
  final VoidCallback onHost;
  final VoidCallback onWeb;
  final VoidCallback onSettings;

  /// Top of the first key: centred on the chat header's bar.
  static double topOf(BuildContext context) =>
      MediaQuery.paddingOf(context).top + (ChatHeader.barHeightOf(context) - AdaptiveMetrics.key) / 2;

  /// Gap under the last key: the composer's (8 above the gesture bar, or the
  /// screen edge, plus its own 8).
  static double bottomOf(BuildContext context) => math.max(MediaQuery.paddingOf(context).bottom, 8) + 8;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final host = ref.watch(activeHostProvider);
    final name = ref.watch(hostNameProvider(host)) ?? (host.isLocal ? l10n.commonThisPhone : l10n.commonRemoteHost);
    final status = watchHostStatus(ref, host, showRelayPath: true);
    const gap = SizedBox(height: AdaptiveMetrics.gap);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        MediaQuery.paddingOf(context).left + AdaptiveMetrics.edge,
        topOf(context),
        AdaptiveMetrics.edge,
        bottomOf(context),
      ),
      // Two groups pinned to the ends (no Spacer: a very short window
      // overlaps them instead of overflowing).
      child: BackdropGroup(
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassIconButton(
                    key: const ValueKey('rail-menu'),
                    icon: AppIcons.menu,
                    tooltip: menuTooltip,
                    onPressed: onMenu,
                  ),
                  gap,
                  GlassIconButton(
                    key: const ValueKey('rail-search'),
                    icon: AppIcons.search,
                    tooltip: l10n.shellSearchChats,
                    onPressed: onSearch,
                  ),
                ],
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GlassIconButton(
                    key: const ValueKey('rail-host'),
                    icon: hostKindIcon(host.kind),
                    tooltip: '$name · ${status.label}',
                    onPressed: onHost,
                    badge: StatusDot(tone: status.tone, size: 7),
                  ),
                  gap,
                  GlassIconButton(
                    key: const ValueKey('rail-web'),
                    icon: AppIcons.webApp,
                    tooltip: l10n.commonWeb,
                    onPressed: onWeb,
                  ),
                  gap,
                  GlassIconButton(
                    key: const ValueKey('rail-settings'),
                    icon: AppIcons.settings,
                    tooltip: l10n.commonSettings,
                    onPressed: onSettings,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
