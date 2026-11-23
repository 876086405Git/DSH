// 设置里的开屏预览：自定义画面播完前按返回，它的播放器随页面一起释放。

import 'dart:async';

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/launch/launch_media.dart';
import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/ui/launch/launch_preview_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class _Clip extends LaunchMedia {
  bool disposed = false;

  @override
  Size get size => const Size(90, 160);

  @override
  Widget view() => const ColoredBox(color: Color(0xFF2E5C8A));

  @override
  void play({VoidCallback? onDone}) {}

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  testWidgets('back before the round ends releases the picture', (tester) async {
    usePhone(tester);
    final clip = _Clip();
    final controller = LaunchController(
      snapshot: snapshotFor(systemSplash: false),
      custom: const CustomLaunch(kind: LaunchMediaKind.video, path: '/clip.mp4', width: 90, height: 160),
      native: false,
    )..useMedia(clip);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: navigator, home: const SizedBox()));
    unawaited(
      navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => LaunchPreviewPage(controller: controller))),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.phase, isNot(LaunchPhase.gone));

    navigator.currentState!.pop();
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.phase, LaunchPhase.gone);
    expect(clip.disposed, isTrue);
  });
}
