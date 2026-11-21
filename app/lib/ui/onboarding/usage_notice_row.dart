// First run's welcome page, over 「开始」: the switch for anonymous usage
// statistics (lib/usage/usage_stats.dart), on, and what it leaves out. Every
// fresh install sees it, on this phone or a remote host; seeing it records
// that the person was told — counting is on from the start.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/android_features.dart';
import '../../usage/usage_stats.dart';
import '../settings/settings_widgets.dart';
import '../theme/theme.dart';

/// ```
///     发送匿名使用统计              ◉
///     不含对话和个人信息，可随时关闭
///   (               开始               )
/// ```
///
/// Card-less and quiet, laid out as a settings row is: the text 16 in from
/// the button's left edge, the switch's track ending 16 in from its right.
class UsageNoticeRow extends ConsumerStatefulWidget {
  const UsageNoticeRow({super.key});

  @override
  ConsumerState<UsageNoticeRow> createState() => _UsageNoticeRowState();
}

class _UsageNoticeRowState extends ConsumerState<UsageNoticeRow> {
  @override
  void initState() {
    super.initState();
    unawaited(ref.read(usageStatsProvider.notifier).markNoticed());
  }

  void _set(bool on) => unawaited(ref.read(usageStatsProvider.notifier).setEnabled(on));

  @override
  Widget build(BuildContext context) {
    // Nothing goes out on HarmonyOS yet, so there is nothing to agree to.
    if (ref.watch(operatingSystemProvider) == 'ohos') return const SizedBox.shrink();
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final enabled = ref.watch(usageStatsProvider.select((s) => s.enabled));
    return MergeSemantics(
      child: GestureDetector(
        key: const ValueKey('usage-notice'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _set(!enabled),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(SettingsMetrics.inset, 0, SettingsMetrics.trailingPad, 0),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.usageStatsTitle,
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      ref.watch(operatingSystemProvider) == 'android' ? l10n.usageV4Welcome : l10n.usageNoticeBody,
                      style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SwitchTheme(
                data: SwitchTheme.of(context).copyWith(materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: Switch.adaptive(key: const ValueKey('usage-notice-switch'), value: enabled, onChanged: _set),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
