// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.
//
// There is no PageView behind the chat here, so a leftward swipe while the
// drawer is closed is simply rejected and left to whatever else wants it: a
// code block's scroll, or the 快捷入口 panel's [QuickPanelDragRecognizer].

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 抽屉拖动手势识别器:**同一根手指全程由抽屉持有,右滑拉开、左滑推回**。
///
/// 为什么要自己写而不用 `Scaffold.drawer` 那套:
///
/// 手势竞技场(gesture arena)的胜负在手势**开始阶段**就决出了。抓住某个滚动内容
/// 的前缘过卷再调 `openDrawer()` 不够:那只是播一段 fling 动画,这根手指早已被
/// 那一层的横向 drag 识别器赢走,不松手继续滑,位移全部喂给它。
///
/// 中途补救也不成立:切滚动内容的 `physics`、动态放宽 `drawerEdgeDragWidth`、
/// 或事后 `openDrawer()`,都无法把**已在飞的** pointer 转交给另一个识别器 ——
/// 放宽拖动区只影响之后新建的识别器。
///
/// 所以正确做法是从一开始就参与竞争:识别器所在的 `RawGestureDetector` 包住
/// 聊天列,与内部横向 `Scrollable` 同处竞技场,按方向自己决定去留 ——
/// - 抽屉关着:横向位移超过 slop 后看方向。**向左立刻 reject**,把手势让给
///   横向滚动内容(代码块、表格)或右侧的快捷入口面板;**向右才 accept**,开始
///   拉开抽屉。
/// - 抽屉已开、或本次手势已被 accept:左右两个方向都由它持有,其他识别器
///   拿不到这根手指。于是同一根手指反向左滑时,进度连续从 1 降到 0。
/// - 竖向为主的位移一律 reject,交给聊天列表或抽屉内部的会话列表滚动。
///
/// 时序上有一条铁律:**任何方向判定都必须等位移真正发生之后**,绝不能
/// 在 pointer 落下瞬间(pointer down)就表态。竞技场里谁先 `resolve(accepted)`,
/// 其余成员全部收到 `rejectGesture` —— 抽屉开着时若在 down 事件就宣布
/// 胜利,抽屉里 InkWell 的 TapGestureRecognizer 会当场被拒,点击切换会话
/// 失灵;抽屉内列表的竖向滚动也一样被杀。Scrollable 之所以能和 Tap
/// 共存,靠的就是 drag 识别器耐心等过 slop、让 Tap 在松手时先赢。
/// 本识别器遵守同一时序:松手前手指没动过,就什么都不声明,点击完整放行。
class DrawerDragRecognizer extends OneSequenceGestureRecognizer {
  DrawerDragRecognizer({
    required this.isOpen,
    required this.onStart,
    required this.onDelta,
    required this.onEnd,
    super.debugOwner,
  });

  /// 抽屉当前是否已经打开(哪怕只开了一部分)。
  ///
  /// 已开时不再做方向筛选:两个方向都归抽屉——同一根手指可以把抽屉推到一半
  /// 再拉回来,只认一侧会让识别器在手势中途退场,另一侧就没人跟手了。
  final ValueGetter<bool> isOpen;

  final VoidCallback onStart;

  /// 横向位移增量(像素,向右为正)。
  final ValueChanged<double> onDelta;

  /// 手势结束:带横向速度(像素/秒,向右为正),用来决定落到全开还是全关。
  final ValueChanged<double> onEnd;

  /// 判定横向意图前要累计的位移。
  ///
  /// 固定 8 个逻辑像素:不能换成 `kPanSlop`(36px)这类更大的阈值再等。内部
  /// 横向 `Scrollable` 还可能按设备的 `gestureSettings` 选不同的 touch slop,
  /// 所以 `kTouchSlop`(18px)不是所有设备的实际阈值,也不能仅凭 8px 就保证
  /// 抽屉总会先赢。关着时只接受向右的意图:这是拉开抽屉的方向,没有别的页面要翻。
  ///
  /// 回归要按真机节奏分小步移动:一个 move 跨 50px 会直接越线,掩盖竞争。
  static const double _slop = 8.0;

  /// 竖向让位的阈值:本实现固定取 `kTouchSlop`(18px),比横向判定宽松,
  /// 确保「想滚列表」不会被误判成开抽屉。
  static const double _verticalSlop = kTouchSlop;

  /// 手指朝哪边滑算「拉开」:抽屉在左,向右。
  @protected
  double get openingSign => 1;

  /// 关着时,朝拉开方向滑了 [distance] 是否够表态(已过 [_slop])。
  @protected
  bool opensAfter(double distance, PointerDeviceKind kind) => true;

  /// 手势结束([PointerUpEvent] 或 [PointerCancelEvent])时交给 [onEnd] 的速度。
  @protected
  double endVelocity(PointerEvent event) => _velocity?.getVelocity().pixelsPerSecond.dx ?? 0;

  Offset _accum = Offset.zero;
  bool _accepted = false;
  VelocityTracker? _velocity;

  @override
  String get debugDescription => 'drawer drag';

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _accum = Offset.zero;
    _accepted = false;
    _velocity = VelocityTracker.withKind(event.kind);
    startTrackingPointer(event.pointer, event.transform);
    // 抽屉开着也**不能**在这里表态:立刻 accept 会让竞技场当场拒掉同一点位上
    // 的 TapGestureRecognizer,抽屉里的会话项就点不动了(见类文档)。方向判定
    // 一律推迟到第一个 PointerMoveEvent,松手前没位移的点击完整放行。
  }

  @override
  void handleEvent(PointerEvent event) {
    _velocity?.addPosition(event.timeStamp, event.localPosition);

    if (event is PointerMoveEvent) {
      if (_accepted) {
        onDelta(event.delta.dx);
        return;
      }
      _accum += event.delta;
      // 竖向为主:这是在滚聊天列表(或抽屉内的会话列表),让给它。
      if (_accum.dy.abs() > _verticalSlop && _accum.dy.abs() > _accum.dx.abs()) {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
        return;
      }
      if (_accum.dx.abs() < _slop) return;
      // 横向意图成立。抽屉已开时左右都归抽屉(右继续拉开、左推回),
      // 关着时只认向右 —— 向左是横向滚动或快捷入口面板的方向,让给它们。
      final open = isOpen();
      final towards = _accum.dx * openingSign;
      if (open || towards > 0) {
        if (!open && !opensAfter(towards, event.kind)) return;
        _accepted = true;
        onStart();
        resolve(GestureDisposition.accepted);
        // slop 期间攒下的位移不能丢,否则抽屉起手会「跳一下」才跟上手指。
        onDelta(_accum.dx);
      } else {
        resolve(GestureDisposition.rejected);
        stopTrackingPointer(event.pointer);
      }
      return;
    }

    if (event is PointerUpEvent || event is PointerCancelEvent) {
      if (_accepted) {
        onEnd(endVelocity(event));
      }
      stopTrackingPointer(event.pointer);
      _accepted = false;
    }
  }

  /// 竞技场判我们赢(可能是别人退出后默认胜出)。
  ///
  /// **不能在这里兼职「开始跟手」**。微小位移或单纯点击时,横向意图还没
  /// 判定出来,别的识别器也因为不够 slop 而放弃 —— 竞技场于是把胜利
  /// 默认判给唯一剩下的我们;在这里开始跟手的话,轻轻一点屏幕、松手后抽屉
  /// 就会自己弹开。
  ///
  /// 所以只认 [handleEvent] 里真正判定过向右意图(或抽屉已开)那一条路径;
  /// 被动获胜一律不做事。
  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    stopTrackingPointer(pointer);
    _accepted = false;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}
}

/// 右侧快捷入口面板的拖动:镜像抽屉,**向左**拉开、向右推回,同一根手指全程
/// 归它,竖向让位和「绝不在 pointer down 表态」都一样。
///
/// 只有一处不同:关着时向左要滑过设备的 touch slop(严格大于)才表态。横向
/// 滚动的代码块、表格,图表和卡片堆的横滑用的是同一个阈值和同一个比较,而
/// 事件先发给更靠里的识别器,所以手指下只要有这样的内容,一定是它先赢:向左
/// 滑一直是它们的,不能被面板抢走。识别器不用知道手指下是什么。Android 的
/// slop 约 8dp,和抽屉的判定距离相同;[gestureSettings] 要和 `Scrollable`
/// 一样取自 MediaQuery,否则两边阈值不一致。
///
/// 系统把手指收走时(边缘返回手势)没有「甩」这回事:只看拉到了哪儿,否则向左
/// 的速度会把面板甩开。
class QuickPanelDragRecognizer extends DrawerDragRecognizer {
  QuickPanelDragRecognizer({
    required super.isOpen,
    required super.onStart,
    required super.onDelta,
    required super.onEnd,
    super.debugOwner,
  });

  @override
  double get openingSign => -1;

  @override
  bool opensAfter(double distance, PointerDeviceKind kind) => distance > computeHitSlop(kind, gestureSettings);

  @override
  double endVelocity(PointerEvent event) => event is PointerCancelEvent ? 0 : super.endVelocity(event);

  @override
  String get debugDescription => 'quick panel drag';
}
