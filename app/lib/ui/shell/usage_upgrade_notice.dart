// An install from before anonymous usage statistics never saw the welcome
// page's switch. The first time it reaches the home (not during first run,
// on this phone or a remote host), a toast tells it, once: 了解 opens
// 设置 › 隐私与分享 at the switch, 关闭 turns the full statistics off. Counting
// is on by default: showing it only records that the person was told
// (lib/usage/usage_stats.dart).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/android_features.dart';
import '../../state/notify_state.dart' show launchNoticeShownProvider;
import '../../usage/usage_net.dart' show UsageBuild;
import '../../usage/usage_stats.dart';
import '../settings/index/settings_pages.dart';

/// How long the toast stays unless a key is used.
const usageNoticeDuration = Duration(seconds: 8);

/// The toast's keys' side padding: the last key's label ends 16 from the
/// toast's right edge, as the text starts 16 from its left.
const _keyPad = 8.0;

/// ```
///   ╭──────────────────────────────────╮
///   │ 新增匿名使用统计，帮助改进 DSH Go。 │
///   │ 不含对话和个人信息                 │
///   │                     了解    关闭  │
///   ╰──────────────────────────────────╯
/// ```
SnackBar usageNoticeBar(
  BuildContext context, {
  required VoidCallback onLearn,
  required VoidCallback onOff,
  bool v4 = false,
}) {
  final l10n = context.l10n;
  final scheme = Theme.of(context).colorScheme;
  final style = TextButton.styleFrom(
    foregroundColor: scheme.inversePrimary,
    padding: const EdgeInsets.symmetric(horizontal: _keyPad),
    // No minimum width: a wider box would centre a short label and break the 16.
    minimumSize: const Size(0, 40),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
  return SnackBar(
    key: const ValueKey('usage-upgrade-notice'),
    persist: false,
    duration: usageNoticeDuration,
    padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 16 - _keyPad, 4),
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.only(end: _keyPad),
          child: Text(v4 ? l10n.usageV4Notice : l10n.usageUpgradeNotice, key: const ValueKey('usage-upgrade-text')),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              key: const ValueKey('usage-upgrade-learn'),
              style: style,
              onPressed: onLearn,
              child: Text(l10n.usageUpgradeLearn),
            ),
            TextButton(
              key: const ValueKey('usage-upgrade-off'),
              style: style,
              onPressed: onOff,
              child: Text(l10n.usageUpgradeOff),
            ),
          ],
        ),
      ],
    ),
  );
}

/// Wraps the home; draws nothing of its own.
class UsageUpgradeNotice extends ConsumerStatefulWidget {
  const UsageUpgradeNotice({super.key, required this.child, this.delay = const Duration(milliseconds: 1500)});

  final Widget child;

  /// After the home is up (the launch screen gone).
  final Duration delay;

  @override
  ConsumerState<UsageUpgradeNotice> createState() => _UsageUpgradeNoticeState();
}

class _UsageUpgradeNoticeState extends ConsumerState<UsageUpgradeNotice> {
  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    // Builds that count nothing have nothing to tell, nor has one that sends nothing.
    if (!UsageBuild.active || ref.read(operatingSystemProvider) == 'ohos') return;
    ref.listenManual(usageStatsProvider, (_, s) => _schedule(s), fireImmediately: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool _owed(UsageStatsState s) =>
      s.loaded && s.enabled && (!s.noticed || (ref.read(operatingSystemProvider) == 'android' && !s.v4Noticed));

  void _schedule(UsageStatsState s) {
    if (_shown || _timer != null || !_owed(s)) return;
    _timer = Timer(widget.delay, _show);
  }

  void _show() {
    _timer = null;
    if (!mounted || _shown || !_owed(ref.read(usageStatsProvider))) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    // A page or sheet over the home, or the app away: when it is back.
    if (messenger == null ||
        ModalRoute.of(context)?.isCurrent == false ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      _timer = Timer(const Duration(seconds: 2), _show);
      return;
    }
    _shown = true;
    ref.read(launchNoticeShownProvider.notifier).set(true);
    final usage = ref.read(usageStatsProvider.notifier);
    messenger.showSnackBar(
      usageNoticeBar(
        context,
        v4: ref.read(operatingSystemProvider) == 'android',
        onLearn: () {
          messenger.hideCurrentSnackBar();
          if (mounted) unawaited(openSpot(context, Spots.usageStats));
        },
        onOff: () {
          messenger.hideCurrentSnackBar();
          unawaited(usage.setEnabled(false));
        },
      ),
    );
    unawaited(usage.markNoticed());
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
