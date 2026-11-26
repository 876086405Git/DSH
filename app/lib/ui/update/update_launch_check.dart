import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/notify_state.dart' show launchNoticeShownProvider;
import '../../state/update_state.dart';
import 'update_sheet.dart';

/// Mounted once in the home shell; draws nothing.
///
/// Checks for updates after the engine's launch delay and on later resumes,
/// subject to the controller's automatic-check throttle. On resume it first
/// lets the controller continue any pending install flow.
class UpdateLaunchCheck extends ConsumerStatefulWidget {
  const UpdateLaunchCheck({super.key, this.delay = const Duration(seconds: 6)});

  final Duration delay;

  @override
  ConsumerState<UpdateLaunchCheck> createState() => _UpdateLaunchCheckState();
}

class _UpdateLaunchCheckState extends ConsumerState<UpdateLaunchCheck> {
  late final Timer _timer;
  late final AppLifecycleListener _lifecycle;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, () => unawaited(_run()));
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_onResume()));
  }

  @override
  void dispose() {
    _timer.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  bool get _foreground =>
      (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) == AppLifecycleState.resumed;

  Future<void> _onResume() async {
    // A resume during startup leaves the delayed check to the launch timer.
    final launchPending = _timer.isActive;
    await ref.read(appUpdateProvider.notifier).onAppResumed();
    if (!launchPending) await _run();
  }

  Future<void> _run() async {
    if (!mounted || !_foreground || _running) return;
    // Share the check and the presentation across launch and resume triggers.
    _running = true;
    try {
      final offer = await ref.read(appUpdateProvider.notifier).autoCheckIfDue();
      if (!offer || !mounted || !_foreground) return;
      // Don't cover a page or sheet the person is in, or interrupt typing (raw
      // view insets: a Scaffold on the way may have consumed the keyboard's).
      // The mark in 设置 → 关于 stays either way.
      if (ModalRoute.of(context)?.isCurrent == false || View.of(context).viewInsets.bottom > 0) return;
      ref.read(launchNoticeShownProvider.notifier).set(true);
      await showUpdateSheet(context);
    } finally {
      _running = false;
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
