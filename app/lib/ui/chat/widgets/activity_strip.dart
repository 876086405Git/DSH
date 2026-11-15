// The live "what is happening now" pill above the composer while a turn runs
// (layer 1 of the run information): live status, the model's `⏵` narration,
// rotating copy and easter eggs (see activity_copy.dart), and the turn clock.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart';
import '../../../state/run_pulse.dart';
import '../../pets/pet_perch.dart';
import '../../theme/theme.dart';
import '../activity_copy.dart';
import '../run_info.dart';
import 'live_clock.dart';
import 'whale_tail.dart';

/// 生成中,输入条正上方的一颗玻璃胶囊:鲸尾(游速 = 出字速度)+ 此刻在做
/// 什么 + 一句自述或趣味文案 + 本轮用时,有待办时右端是进度。点一下看本轮
/// 轨迹;长按几秒内换成这一步的用时和估算速度。
///
/// ```
/// ( 🐋 跑  flutter test test/auth           0:19 │ 进度 3/5 ▰▰▰▱▱ )
/// ( 🐋 思考中  脑子在冒烟                    0:07 )
/// ```
///
/// 只订阅 [runActivityOf] 的结果(值相等不重建)和 [RunPulse](换档、压缩
/// 开始结束时才通知);走秒和文案轮换只重建文字那一段。
class ActivityStripSlot extends ConsumerStatefulWidget {
  const ActivityStripSlot({super.key, required this.sessionId, this.onTap, this.todoProgress = true});

  final String sessionId;
  final VoidCallback? onTap;

  /// See [ActivityStrip.todoProgress].
  final bool todoProgress;

  @override
  ConsumerState<ActivityStripSlot> createState() => _ActivityStripSlotState();
}

/// 出现时胶囊从输入条背后升起,收起时沉回去:插槽高度跟着动画走(列表的
/// 底边距随之变化),胶囊本身始终整颗画出、不裁不淡。露在插槽外的下半截
/// 被后画的输入条盖住,隔着它的毛玻璃只看得到一团模糊,不会和后面的消息
/// 文字叠在一起,也没有被裁出来的硬边。
class _ActivityStripSlotState extends ConsumerState<ActivityStripSlot> with SingleTickerProviderStateMixin {
  late final AnimationController _rise = AnimationController(vsync: this, duration: AppMotion.standard)
    ..addStatusListener(_onStatus);
  // Sinking decelerates too (not the rise played backwards), in step with
  // the reply actions and new rows that grow while it sinks.
  late final CurvedAnimation _height = CurvedAnimation(
    parent: _rise,
    curve: AppMotion.std,
    reverseCurve: AppMotion.std.flipped,
  );

  /// The last activity shown, kept on screen while the strip sinks away.
  RunActivity? _last;
  int _lastLevel = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rise.duration = AppMotion.of(context, AppMotion.standard);
  }

  @override
  void dispose() {
    _height.dispose();
    _rise.dispose();
    super.dispose();
  }

  void _onStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed) return;
    // May fire inside build (no animations: sinking ends at once).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _rise.isDismissed) setState(() => _last = null);
    });
  }

  /// Starts rising / sinking right away, from build: its clock then counts
  /// from this frame, like the reply actions and the "发送中" line that
  /// start in didUpdateWidget, so they all move in step.
  void _drive(bool visible) {
    final status = _rise.status;
    final going = visible
        ? status != AnimationStatus.forward && status != AnimationStatus.completed
        : status != AnimationStatus.reverse && status != AnimationStatus.dismissed;
    if (!going) return;
    visible ? _rise.forward() : _rise.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final sessionId = widget.sessionId;
    final activity = ref.watch(chatProvider(sessionId).select(runActivityOf));
    final pulse = ref.watch(runPulseProvider(sessionId));
    return ListenableBuilder(
      listenable: pulse,
      builder: (context, _) {
        final compacting = pulse.compactingSince;
        final shown = compacting != null ? compactionActivity(ref.read(chatProvider(sessionId)), compacting) : activity;
        if (shown != null) {
          _last = shown;
          // 等你时最慢的一档(0),不停下。
          _lastLevel = shown.waiting || shown.kind == ActivityKind.stopping ? 0 : pulse.level;
        }
        _drive(shown != null);
        final strip = _last;
        if (strip == null) return const SizedBox(width: double.infinity);
        // The chat page's pet stands on the strip: one mascot a screen, so
        // the whale tail steps aside while it does.
        final perches = PetPerchScope.maybeOf(context);
        return AnimatedBuilder(
          animation: _height,
          builder: (context, child) => Align(alignment: Alignment.topCenter, heightFactor: _height.value, child: child),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: PetPerch(
              kind: PerchKind.strip,
              active: shown != null,
              child: ValueListenableBuilder<PerchKind?>(
                valueListenable: perches?.occupied ?? _noPet,
                builder: (context, occupied, _) => ActivityStrip(
                  activity: strip,
                  speedLevel: _lastLevel,
                  tokensPerSecond: () => pulse.tokensPerSecond,
                  onTap: shown == null ? null : widget.onTap,
                  todoProgress: widget.todoProgress,
                  whale: occupied != PerchKind.strip,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Outside a pet stage nothing ever stands on the strip.
final _noPet = ValueNotifier<PerchKind?>(null);

class ActivityStrip extends StatefulWidget {
  const ActivityStrip({
    super.key,
    required this.activity,
    this.speedLevel = 1,
    this.tokensPerSecond,
    this.onTap,
    this.whaleColor,
    this.todoProgress = true,
    this.whale = true,
  });

  final RunActivity activity;

  /// 鲸尾档位:0 等你,1–4 见 [SpeedGauge](见 [WhaleTail])。
  final int speedLevel;

  /// 长按时读一次当前估算速度。
  final double Function()? tokensPerSecond;
  final VoidCallback? onTap;

  /// 鲸尾颜色;缺省是 DeepSeek 蓝(深色模式提亮),等你时是警示色。
  final Color? whaleColor;

  /// 右端的待办进度;聊天页上方有待办条时关掉,免得说两遍。
  final bool todoProgress;

  /// 左端的鲸尾。宠物站在胶囊上时收起(位置一起收掉,左右内边距相等)。
  final bool whale;

  /// 长按后统计显示多久。
  static const statsFor = Duration(seconds: 4);

  @override
  State<ActivityStrip> createState() => _ActivityStripState();
}

class _ActivityStripState extends State<ActivityStrip> {
  Timer? _statsTimer;

  @override
  void dispose() {
    _statsTimer?.cancel();
    super.dispose();
  }

  void _showStats() {
    HapticFeedback.selectionClick();
    _statsTimer?.cancel();
    _statsTimer = Timer(ActivityStrip.statsFor, () {
      if (mounted) setState(() => _statsTimer = null);
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final dsh = DshColors.of(context);
    final a = widget.activity;
    final whale = widget.whaleColor ?? (a.waiting ? dsh.warning : whaleColorFor(theme.brightness));

    return Semantics(
      button: widget.onTap != null,
      label: '${a.title} ${a.detail}',
      onTapHint: l10n.chatViewTurnTrace,
      onTap: widget.onTap,
      onLongPress: _showStats,
      excludeSemantics: true,
      child: GlassSurface(
        tier: GlassTier.chrome,
        stadium: true,
        // One backdrop sample with the deck's other bars (chat page).
        grouped: true,
        onTap: widget.onTap,
        onLongPress: _showStats,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.whale ? 1 : 0),
            duration: AppMotion.of(context, AppMotion.standard),
            curve: AppMotion.std,
            builder: (context, t, _) => Padding(
              // 9 + whale: the tail's own air makes up the difference; without
              // it both ends are 14.
              padding: EdgeInsets.fromLTRB(14 - 5 * t, 6, 14, 6),
              child: Row(
                children: [
                  if (t > 0)
                    ClipRect(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: t,
                        child: Opacity(
                          opacity: t,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 自己一层:鲸尾每帧在动,不连累玻璃里的其余内容重绘。
                              RepaintBoundary(
                                child: WhaleTail(level: widget.speedLevel, color: whale, height: 20),
                              ),
                              const SizedBox(width: 6),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: LiveElapsed(
                      since: a.turnStart ?? a.since,
                      skew: a.skew,
                      builder: (context, elapsed) => _Line(
                        activity: a,
                        elapsed: elapsed,
                        stats: _statsTimer == null ? null : _stats(a, widget.tokensPerSecond?.call() ?? 0),
                      ),
                    ),
                  ),
                  if (widget.todoProgress && a.todoTotal > 0) ...[
                    Container(
                      width: 0.5,
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      color: theme.colorScheme.outlineVariant,
                    ),
                    TodoProgress(done: a.todoDone, total: a.todoTotal),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 长按的那几秒:这一步多久了 + 估算的出字速度。
  static String _stats(RunActivity a, double tps) {
    final since = a.since;
    final step = since == null ? null : formatClock(LiveElapsed.elapsedSince(since, a.skew));
    final speed = tps >= 1 ? appL10n.chatTokensPerSecond(tps.round()) : appL10n.chatNoTokensStreaming;
    return [if (step != null) appL10n.chatCurrentStep(step), speed].join(' · ');
  }
}

/// 标题 + 第二段(工具目标 / 自述 / 文案 / 统计)+ 本轮用时。
class _Line extends StatelessWidget {
  const _Line({required this.activity, required this.elapsed, this.stats});

  final RunActivity activity;
  final Duration? elapsed;
  final String? stats;

  // Leave the transition unkeyed so AnimatedSwitcher assigns each fade its own key.
  // The same activity can return while an older copy is still fading out.
  static Widget _fade(Widget child, Animation<double> animation) => FadeTransition(opacity: animation, child: child);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final a = activity;

    // Three tiers: what (title, onSurface 600) › on what (detail, secondary)
    // › colour (narration secondary, fun copy and the clock tertiary).
    final flavor = stats != null ? null : activityFlavor(a, runClock());
    final secondary = colors.onSurfaceVariant;
    final body = theme.textTheme.bodySmall?.copyWith(height: 1.3);
    final spans = <TextSpan>[
      if (stats != null)
        TextSpan(
          text: stats,
          style: body?.copyWith(color: secondary),
        )
      else ...[
        if (a.detail.isNotEmpty)
          TextSpan(
            text: a.detail,
            style: a.detailIsCode
                ? AppType.mono(size: 12, color: secondary, height: 1.3)
                : body?.copyWith(color: secondary),
          ),
        if (flavor != null)
          TextSpan(
            text: a.detail.isNotEmpty ? ' · ${flavor.text}' : flavor.text,
            style: body?.copyWith(
              color: flavor.source == FlavorSource.narration && a.detail.isEmpty ? secondary : dsh.textTertiary,
            ),
          ),
      ],
    ];
    final second = spans.map((s) => s.text).join();

    final titleStyle = theme.textTheme.labelMedium?.copyWith(
      color: a.waiting ? dsh.warning : colors.onSurface,
      height: 1.3,
    );
    final clockStyle = AppType.tabular(
      theme.textTheme.labelSmall!.copyWith(fontSize: 12, color: a.waiting ? dsh.warning : dsh.textTertiary),
    );

    return Row(
      children: [
        Expanded(
          child: AnimatedSwitcher(
            duration: AppMotion.of(context, AppMotion.quick),
            transitionBuilder: !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS
                ? _fade
                : AnimatedSwitcher.defaultTransitionBuilder,
            layoutBuilder: (current, previous) =>
                Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
            child: Row(
              key: ValueKey('${a.title}\u0000$second'),
              children: [
                Text(a.title, style: titleStyle),
                if (second.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text.rich(
                      TextSpan(children: spans),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        if (elapsed != null) ...[const SizedBox(width: 8), Text(formatClock(elapsed!), style: clockStyle)],
      ],
    );
  }
}

/// `进度 3/5` + 一根 3dp 细条。
class TodoProgress extends StatelessWidget {
  const TodoProgress({super.key, required this.done, required this.total, this.barWidth = 30, this.showLabel = true});

  final int done;
  final int total;
  final double barWidth;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dsh = DshColors.of(context);
    final fraction = total == 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Semantics(
      label: l10n.chatTodoProgress(done, total),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            showLabel ? l10n.chatProgress(done, total) : '$done/$total',
            style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(fontSize: 12, color: dsh.textTertiary)),
          ),
          const SizedBox(width: 7),
          Container(
            width: barWidth,
            height: 3,
            alignment: Alignment.centerLeft,
            decoration: ShapeDecoration(color: colors.onSurface.withValues(alpha: 0.10), shape: const StadiumBorder()),
            child: FractionallySizedBox(
              widthFactor: fraction,
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: fraction >= 1 ? dsh.success : colors.primary,
                  shape: const StadiumBorder(),
                ),
                child: const SizedBox(height: 3),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
