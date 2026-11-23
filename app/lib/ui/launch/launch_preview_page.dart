// 设置 › 主题 › 启动画面 › 预览: the launch screen as a cold start shows it, over the whole
// screen: the system's picture, the motion (or the custom picture played once, however long),
// a short rest, then it fades away as it would onto the app. A tap ends it early.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../launch/custom_launch.dart';
import '../../launch/launch_state.dart';
import '../theme/theme.dart';
import 'launch_overlay.dart';

/// Shows the launch screen once; [custom] null previews the default.
Future<void> showLaunchPreview(BuildContext context, {CustomLaunch? custom, LaunchChannel? channel}) async {
  final navigator = Navigator.of(context);
  final fadeIn = AppMotion.of(context, AppMotion.quick);
  final size = MediaQuery.sizeOf(context);
  final dpr = MediaQuery.devicePixelRatioOf(context);
  final snapshot =
      await LaunchSnapshot.fromMap(await (channel ?? const LaunchChannel()).snapshot()) ??
      // No native side: the page and the wordmark, no icon.
      LaunchSnapshot(
        sdk: 35,
        systemSplash: false,
        iconPx: (160 * dpr).round(),
        background: LaunchColors.mistTop,
        backgroundBottom: LaunchColors.mistBottom,
        dark: false,
      );
  final controller = LaunchController(
    snapshot: LaunchSnapshot(
      sdk: snapshot.sdk,
      // Played straight away: there's no system splash to take over from.
      systemSplash: false,
      iconPx: snapshot.iconPx,
      icon: snapshot.icon,
      background: snapshot.background,
      backgroundBottom: snapshot.backgroundBottom,
      dark: snapshot.dark,
    ),
    custom: custom,
    native: false,
  );
  if (custom != null) unawaited(controller.openMedia(size * dpr));
  await navigator.push(
    PageRouteBuilder<void>(
      opaque: true,
      transitionDuration: fadeIn,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, _, _) => LaunchPreviewPage(controller: controller),
      transitionsBuilder: (context, animation, _, child) => FadeTransition(opacity: animation, child: child),
    ),
  );
}

class LaunchPreviewPage extends StatefulWidget {
  const LaunchPreviewPage({super.key, required this.controller});

  final LaunchController controller;

  /// The app being "ready": after the motion and a moment at rest.
  static const rest = Duration(milliseconds: 2000);

  /// A custom picture plays its whole round, then this beat at rest.
  static const afterRound = Duration(milliseconds: 500);

  @override
  State<LaunchPreviewPage> createState() => _LaunchPreviewPageState();
}

class _LaunchPreviewPageState extends State<LaunchPreviewPage> {
  Timer? _timer;
  bool _popped = false;

  LaunchController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_follow);
    if (_c.custom == null) {
      _timer = Timer(LaunchPreviewPage.rest, _c.ready);
    } else {
      unawaited(
        _c.mediaDone.then((_) {
          if (mounted) _timer = Timer(LaunchPreviewPage.afterRound, _c.ready);
        }),
      );
    }
  }

  void _follow() {
    // A custom picture that can't be read: the default motion plays instead.
    if (_c.mediaFailed && _timer == null) _timer = Timer(LaunchPreviewPage.rest, _c.ready);
    if (_c.phase != LaunchPhase.gone || _popped || !mounted) return;
    _popped = true;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.removeListener(_follow);
    // Closed early (back): no timer left behind, and the picture's player is released.
    _c.gone();
    super.dispose();
  }

  // A tap ends it, as at a launch (the overlay's own).
  @override
  Widget build(BuildContext context) => LaunchOverlay(controller: _c);
}
