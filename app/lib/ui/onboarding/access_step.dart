// First run, step 3 of 4 on this phone, while the runtime unpacks
// (docs/design/onboarding-parallel-setup.md): what DSH Go should do, then
// each permission it needs, one at a time, then where they all ended up.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/access_state.dart';
import '../../state/android_features.dart';
import '../access/access_pick_page.dart';
import '../access/access_summary_page.dart';
import '../access/access_walk.dart';
import 'onboarding_scaffold.dart';

/// 想让 DSH Go 帮你做哪些事 → 逐项开启 → 汇总. 跳过 on the first page goes on
/// with nothing changed. The picks are kept until the step is over, so a
/// launch after the app was killed in system settings comes back to the walk.
class AccessStepPage extends ConsumerStatefulWidget {
  const AccessStepPage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  ConsumerState<AccessStepPage> createState() => _AccessStepPageState();
}

class _AccessStepPageState extends ConsumerState<AccessStepPage> {
  bool _summary = false;
  bool _walkedOnce = false;
  bool _finishing = false;

  Future<void> _walked() async {
    if (_walkedOnce) return;
    _walkedOnce = true;
    await ref.read(accessReadingsProvider.notifier).refresh();
    if (mounted) setState(() => _summary = true);
  }

  /// 继续: what was picked goes on as the summary is left, so an item turned
  /// on from it counts ([AccessSetupController.finish]). If that fails (the
  /// readings could not be taken) the step is not over and nothing is lost:
  /// it says so with 重试 (over 继续 while it shows), and 继续 works again.
  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    try {
      await ref.read(accessSetupProvider.notifier).finish();
    } catch (_) {
      _finishing = false;
      if (mounted) {
        final l10n = context.l10n;
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(l10n.accessFinishFailed),
              // Goes by itself: 继续 underneath does the same.
              persist: false,
              duration: const Duration(seconds: 6),
              action: SnackBarAction(label: l10n.commonRetry, onPressed: () => unawaited(_finish())),
            ),
          );
      }
      return;
    }
    widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    final setup = ref.watch(accessSetupProvider);
    final readings = ref.watch(accessReadingsProvider).value;
    final features = setup.features;
    final Widget page;
    if (setup.loaded && features == null) {
      // The pick needs nothing from the phone (mobile data, if known, shows when read).
      page = AccessPickPage(
        key: const ValueKey('pick'),
        onPicked: (picked, phoneMode) =>
            unawaited(ref.read(accessSetupProvider.notifier).choose(picked, phoneMode: phoneMode)),
        onSkip: widget.onDone,
      );
    } else if (features == null || readings == null) {
      page = const OnboardingScaffold(key: ValueKey('loading'), children: [SizedBox.shrink()]);
    } else {
      final items = accessWalk(features, readings.vendor);
      page = _summary
          ? AccessSummaryPage(
              key: const ValueKey('summary'),
              items: items,
              voice: features.contains(AccessFeature.voice) && accessVoiceDownloads(ref.watch(operatingSystemProvider)),
              onDone: () => unawaited(_finish()),
            )
          : AccessWalk(
              key: const ValueKey('walk'),
              items: items,
              vendor: readings.vendor,
              skipped: setup.skipped,
              onSkip: (item) => unawaited(ref.read(accessSetupProvider.notifier).skip(item)),
              onDone: () => unawaited(_walked()),
            );
    }
    return OnboardingSwitcher(child: page);
  }
}
