// First run, after the walk: where each item ended up, a way back to any
// that is still off, and what happens next for voice.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/access_state.dart';
import '../onboarding/onboarding_scaffold.dart';
import '../settings/settings_widgets.dart';
import '../theme/app_icons.dart';
import 'access_widgets.dart';
import 'system_access_route.dart';

/// ```
///   ▣  还有 1 项没开
///      随时可在「设置 › 系统权限」补开
///   ╭──────────────────────────────────╮
///   │ ▢ 允许使用麦克风          已开启   │
///   │ ▢ 允许通知               未开启 › │
///   │ ▢ 允许后台高耗电          已去设置 › │
///   ╰──────────────────────────────────╯
///   语音模型（约 241 MB）会在引擎就绪后开始下载…
///   (               继续               )
/// ```
class AccessSummaryPage extends ConsumerWidget {
  const AccessSummaryPage({super.key, required this.items, required this.voice, required this.onDone});

  /// What the picked features need, in walk order.
  final List<AccessItem> items;

  /// 语音输入 was picked and has a model: it downloads once the engine is up.
  final bool voice;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final readings = ref.watch(accessReadingsProvider).value ?? const AccessReadings();
    final visited = ref.watch(accessVisitedProvider);
    final rows = [
      for (final item in items)
        if (accessStateOf(item, readings, visited) case final state?) (item, state),
    ];
    final left = rows.where((r) => !r.$2.settled).length;
    return OnboardingScaffold(
      children: [
        const Spacer(),
        OnboardingHeader(
          icon: left == 0 ? AppIcons.completed : AppIcons.systemAccess,
          title: left == 0 ? l10n.accessSummaryAllSet : l10n.accessSummaryLeft(left),
          message: l10n.accessSummaryMessage,
        ),
        const SizedBox(height: 28),
        SettingsSection(
          key: const ValueKey('access-summary-card'),
          margin: EdgeInsets.zero,
          footer: voice ? Text(l10n.accessVoiceDownload(voiceModelApproxMb), key: const ValueKey('access-voice')) : null,
          children: [
            for (final (item, state) in rows)
              AccessItemTile(
                item: item,
                state: state,
                vendor: readings.vendor,
                onTap: () => openAccessItem(context, item),
              ),
          ],
        ),
        const Spacer(flex: 2),
        const SizedBox(height: 24),
        FilledButton(key: const ValueKey('access-summary-done'), onPressed: onDone, child: Text(l10n.commonContinue)),
      ],
    );
  }
}
