// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';

/// 嵌套纵向滚动的"到头让路"。
///
/// 工具输出井、代码块、diff 内部各有自己的纵向滚动区。内层滚动件会抢先赢下
/// 手势竞技场,手指按在内层上拖,外层消息列表永远接不到这次拖动 —— 哪怕内层
/// 已经滚到了头。包上这一层:内层到边后继续拖,未被消费的增量
/// (OverscrollNotification)直接转交给最近的外层 Scrollable(聊天列表)。
class OverscrollForwarder extends StatelessWidget {
  const OverscrollForwarder({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 这个 context 在内层 Scrollable **之上**,所以找到的是外层列表。
    final outer = Scrollable.maybeOf(context);
    if (outer == null) return child;
    return NotificationListener<OverscrollNotification>(
      onNotification: (notification) {
        // 只接管纵向:代码块的横向到边增量不能拿去竖着晃消息列表。
        if (notification.metrics.axis != Axis.vertical) return false;
        final position = outer.position;
        final target = (position.pixels + notification.overscroll).clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if (target != position.pixels) {
          position.jumpTo(target.toDouble());
        }
        return true;
      },
      // A bounce reports no overscroll, so on iOS the drag would stay in here and the list above
      // would never move. Android clamps by default.
      child: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
          ? ScrollConfiguration(
              behavior: ScrollConfiguration.of(context)
                  .copyWith(physics: const ClampingScrollPhysics(parent: RangeMaintainingScrollPhysics())),
              child: child,
            )
          : child,
    );
  }
}
