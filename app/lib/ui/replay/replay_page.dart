// 「对话回放」 — a shared conversation, read-only, played back the way it happened.
// Opened from a `.dshgo` file (system share, 「打开方式」) or as the share sheet's
// preview.
//
//   (‹) (  修复登录重复提交      ) (≡)     ← back · title · 全文
//   ( ▶  ━━━━━●─────────  0:42 / 3:10  1× )
//   … the conversation, drawn by the chat's own rows …
//   [ todo / goal bars, as in the chat ]
//   [              接着聊              ]

import 'dart:async';
import 'dart:math' as math;

import 'package:dsh_client/dsh_client.dart' show GoalPhase, GoalProjection, GoalSnapshot;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../share_code/conversation_share.dart';
import '../../state/attachments.dart' show sessionImageProvider;
import '../../state/compose_inbox.dart';
import '../../state/goal_dock_state.dart' show DockGoal;
import '../../state/settings_state.dart';
import '../../state/ui_mode_state.dart';
import '../../state/web_target.dart';
import '../chat/dock/dock_pill.dart' show DockSlot;
import '../chat/dock/goal_bar.dart';
import '../chat/dock/todo_bar.dart';
import '../common/pressable.dart';
import '../common/side_insets.dart';
import '../shell/page_frame.dart' show GlassIconButton;
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'continue_chat.dart';
import 'replay_frame.dart';
import 'replay_list.dart';
import 'replay_scope.dart';

/// Opens the replay of [conversation] over the current page. [preview]: the
/// sharer looking before sending (no 「接着聊」).
Future<void> openConversationReplay(BuildContext context, DecodedConversation conversation, {bool preview = false}) {
  HapticFeedback.selectionClick();
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ReplayPage(share: conversation.share, assets: conversation.assets, preview: preview),
    ),
  );
}

class ReplayPage extends ConsumerStatefulWidget {
  const ReplayPage({
    super.key,
    required this.share,
    this.assets = const {},
    this.preview = false,
    this.autoplay = true,
  });

  final ConversationShare share;

  /// Asset id → picture.
  final Map<String, ConversationAsset> assets;
  final bool preview;

  /// Start playing once the page is up.
  final bool autoplay;

  /// Speeds 「1×」「2×」「4×」.
  static const speeds = [1, 2, 4];

  @override
  ConsumerState<ReplayPage> createState() => _ReplayPageState();
}

class _ReplayPageState extends ConsumerState<ReplayPage> with SingleTickerProviderStateMixin {
  late ReplayFrames _frames = ReplayFrames(widget.share);
  late final Ticker _ticker = createTicker(_tick);
  final _position = ValueNotifier<double>(0);
  final _scrolledUnder = ValueNotifier<double>(0);
  final _veil = ValueNotifier<double>(0);
  Timer? _autoplay;

  late ReplayFrame _frame = _frames.at(0);
  bool _live = false;
  bool _playing = false;
  int _speed = 1;
  Duration _last = Duration.zero;
  double _drawnAt = -1;
  bool _resumeAfterSeek = false;

  double get _duration => _frames.timeline.duration;
  bool get _ended => _position.value >= _duration;

  @override
  void initState() {
    super.initState();
    if (_duration <= 0) {
      _seek(_duration);
    } else if (widget.autoplay) {
      _autoplay = Timer(const Duration(milliseconds: 450), () {
        if (mounted) _play();
      });
    }
  }

  @override
  void didUpdateWidget(ReplayPage old) {
    super.didUpdateWidget(old);
    if (!identical(old.share, widget.share)) {
      _frames = ReplayFrames(widget.share);
      _seek(0);
    }
  }

  @override
  void dispose() {
    _autoplay?.cancel();
    _ticker.dispose();
    _position.dispose();
    _scrolledUnder.dispose();
    _veil.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000.0;
    _last = elapsed;
    final next = math.min(_duration, _position.value + math.min(dt, 250) * _speed);
    _position.value = next;
    // Rows at most ~30 times a second; the progress bar every frame.
    if (next >= _duration || next - _drawnAt >= 33 * _speed) _draw(live: true);
    if (next >= _duration) _stop();
  }

  void _draw({required bool live}) {
    _drawnAt = _position.value;
    setState(() {
      _frame = _frames.at(_position.value);
      _live = live;
    });
  }

  void _play() {
    _autoplay?.cancel();
    if (_ended) {
      _position.value = 0;
      _draw(live: false);
    }
    _last = Duration.zero;
    if (!_ticker.isActive) _ticker.start();
    setState(() => _playing = true);
  }

  void _stop() {
    _autoplay?.cancel();
    if (_ticker.isActive) _ticker.stop();
    if (mounted) setState(() => _playing = false);
  }

  void _seek(double at) {
    _position.value = at.clamp(0, _duration);
    _draw(live: false);
  }

  void _showAll() {
    _stop();
    _seek(_duration);
  }

  void _toggle() {
    HapticFeedback.selectionClick();
    _playing ? _stop() : _play();
  }

  void _nextSpeed() {
    HapticFeedback.selectionClick();
    final i = ReplayPage.speeds.indexOf(_speed);
    setState(() => _speed = ReplayPage.speeds[(i + 1) % ReplayPage.speeds.length]);
  }

  void _continue() {
    final request = continueChatRequest(widget.share);
    if (ref.read(uiModeProvider).web) {
      // The web home has no native composer: the page opens a new chat with it.
      ref.read(webOpenProvider.notifier).request(const DshWebTarget(newSession: true), compose: request);
    } else {
      ref.read(composeInboxProvider.notifier).push(request);
    }
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final assets = widget.assets;
    final header = ReplayHeader.heightOf(context);
    final frame = _frame;
    final todos = TodoDockSummary.of(frame.todos, running: frame.running);
    final goal = frame.goal;
    return ProviderScope(
      // The bubbles' pictures come from the file, not from an engine.
      overrides: [
        sessionImageProvider.overrideWith((ref, key) async {
          final asset = assets[key.$2.attachmentId];
          if (asset == null) throw StateError('not in the file');
          return asset.bytes;
        }),
      ],
      child: ReplayScope(
        share: widget.share,
        frames: _frames,
        assets: assets,
        child: AnnotatedRegion<SystemUiOverlayStyle>(
          value: dshSystemOverlay(Theme.of(context).brightness),
          child: AppBackdrop(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              // A phone on its side: clear of the cutout on both sides.
              body: SideSafeArea(
                child: CustomMultiChildLayout(
                  delegate: _ReplayLayout(_veil),
                  children: [
                    LayoutId(
                      id: _Slot.body,
                      child: _ChatTextScale(
                        child: ReplayList(
                          frame: frame,
                          live: _live,
                          topInset: header,
                          bottomInset: _ReplayLayout.overlap,
                          scrolledUnder: _scrolledUnder,
                        ),
                      ),
                    ),
                    LayoutId(
                      id: _Slot.veil,
                      child: BackdropVeil(solidHeight: _veil),
                    ),
                    LayoutId(
                      id: _Slot.header,
                      child: ReplayHeader(
                        title: widget.share.title,
                        subtitle: _subtitle(_frames),
                        position: _position,
                        duration: _duration,
                        playing: _playing,
                        speed: _speed,
                        scrolledUnder: _scrolledUnder,
                        onBack: () => Navigator.of(context).maybePop(),
                        onToggle: _toggle,
                        onSpeed: _nextSpeed,
                        onShowAll: _ended && !_playing ? null : _showAll,
                        onSeekStart: () {
                          _resumeAfterSeek = _playing;
                          _stop();
                        },
                        onSeek: _seek,
                        onSeekEnd: () {
                          if (_resumeAfterSeek && !_ended) _play();
                          _resumeAfterSeek = false;
                        },
                      ),
                    ),
                    LayoutId(
                      id: _Slot.bottom,
                      child: SafeArea(
                        top: false,
                        minimum: const EdgeInsets.only(bottom: 8),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  BackdropGroup(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        DockSlot(
                                          key: const ValueKey('todo'),
                                          child: todos == null ? null : TodoBar(summary: todos),
                                        ),
                                        DockSlot(
                                          key: const ValueKey('goal'),
                                          child: goal == null ? null : GoalBar(goal: _dockGoal(goal)),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (!widget.preview)
                                    FilledButton(
                                      key: const ValueKey('replay-continue'),
                                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                                      onPressed: _continue,
                                      child: Text(l10n.viewReplayContinue),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static DockGoal _dockGoal(GoalEntry goal) => DockGoal(
    projection: GoalProjection(
      goal: GoalSnapshot(
        id: 'replay',
        revision: 1,
        objective: goal.text ?? '',
        phase: GoalPhase.fromWire(goal.phase) ?? GoalPhase.active,
        maxGoalRounds: 0,
      ),
    ),
    canChange: false,
  );

  /// 「10 月 24 日 · 12 分钟」, or the rounds of a part.
  static String _subtitle(ReplayFrames frames) {
    final share = frames.share;
    final start = share.start.toLocal();
    final parts = [appL10n.viewReplayDate(start.month.toString(), start.day)];
    final span = frames.originalSpan;
    if (span.inSeconds > 0) parts.add(formatReplaySpan(span));
    if (share.range case final r?) {
      parts.add(r.from == r.to ? appL10n.viewShareTurn(r.from) : appL10n.viewReplayTurns(r.from, r.to));
    }
    return parts.join(' · ');
  }
}

/// 「12 秒」「12 分钟」「1 小时 5 分钟」.
String formatReplaySpan(Duration d) {
  if (d.inSeconds < 60) return appL10n.viewReplaySeconds(math.max(1, d.inSeconds));
  final minutes = (d.inSeconds / 60).round();
  if (minutes < 60) return appL10n.viewReplayMinutes(minutes);
  final rest = minutes % 60;
  return rest == 0 ? appL10n.viewReplayHours(minutes ~/ 60) : appL10n.viewReplayHoursMinutes(minutes ~/ 60, rest);
}

/// 「0:42」.
String formatReplayClock(double ms) {
  final s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// The top of the replay: back, the title, 「全文」; under them the transport
/// capsule — play / pause, the progress bar, the time, the speed.
class ReplayHeader extends StatelessWidget {
  const ReplayHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.position,
    required this.duration,
    required this.playing,
    required this.speed,
    required this.onBack,
    required this.onToggle,
    required this.onSpeed,
    required this.onShowAll,
    required this.onSeekStart,
    required this.onSeek,
    required this.onSeekEnd,
    this.scrolledUnder,
  });

  final String title;
  final String subtitle;
  final ValueListenable<double> position;
  final double duration;
  final bool playing;
  final int speed;
  final VoidCallback onBack;
  final VoidCallback onToggle;
  final VoidCallback onSpeed;

  /// Null once everything shows.
  final VoidCallback? onShowAll;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeek;
  final VoidCallback onSeekEnd;
  final ValueListenable<double>? scrolledUnder;

  /// Round keys on the bar, the capsule's height.
  static const keySize = 44.0;

  /// Keys inside the capsule, and the even inset around them.
  static const innerKey = 36.0;
  static const inset = (keySize - innerKey) / 2;

  static const _top = 6.0;
  static const _gap = 8.0;
  static const _bottom = 8.0;

  static double titleHeightOf(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return math.max(keySize, scaler.scale(15) * 1.3 + scaler.scale(11) * 1.25 + 8);
  }

  static double heightOf(BuildContext context) =>
      MediaQuery.paddingOf(context).top + _top + titleHeightOf(context) + _gap + keySize + _bottom;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dsh = DshColors.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final height = heightOf(context);
    final ended = position.value >= duration && !playing;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: scrolledUnder == null
              ? const SizedBox.shrink()
              : ValueListenableBuilder<double>(
                  valueListenable: scrolledUnder!,
                  builder: (context, t, child) => Opacity(opacity: t, child: child),
                  child: TopFade(height: height + 12),
                ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(12, top + _top, 12, _bottom),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: AppSpace.floatingWidth),
              child: BackdropGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      key: const ValueKey('replay-title-row'),
                      height: titleHeightOf(context),
                      child: Row(
                        children: [
                          GlassIconButton(
                            key: const ValueKey('replay-back'),
                            icon: AppIcons.back,
                            tooltip: l10n.commonBack,
                            onPressed: onBack,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: GlassSurface(
                              key: const ValueKey('replay-title'),
                              tier: GlassTier.chrome,
                              stadium: true,
                              grouped: true,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(minHeight: titleHeightOf(context)),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, height: 1.3),
                                      ),
                                      Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppType.tabular(
                                          theme.textTheme.labelSmall!.copyWith(
                                            fontSize: 11,
                                            height: 1.25,
                                            color: dsh.textTertiary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          GlassIconButton(
                            key: const ValueKey('replay-all'),
                            icon: AppIcons.fullText,
                            tooltip: l10n.viewReplayFull,
                            onPressed: onShowAll,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: _gap),
                    GlassSurface(
                      key: const ValueKey('replay-transport'),
                      tier: GlassTier.chrome,
                      stadium: true,
                      grouped: true,
                      child: SizedBox(
                        height: keySize,
                        child: Padding(
                          padding: const EdgeInsets.all(inset),
                          child: Row(
                            children: [
                              _InnerKey(
                                key: const ValueKey('replay-play'),
                                label: playing
                                    ? l10n.viewReplayPause
                                    : ended
                                    ? l10n.viewReplayRestart
                                    : l10n.viewReplayPlay,
                                onTap: onToggle,
                                child: Icon(
                                  playing
                                      ? AppIcons.mediaPause
                                      : ended
                                      ? AppIcons.replay
                                      : AppIcons.mediaPlay,
                                  size: 22,
                                  color: scheme.onSurface,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: ValueListenableBuilder<double>(
                                  valueListenable: position,
                                  builder: (context, at, _) => _Progress(
                                    value: duration <= 0 ? 1 : (at / duration).clamp(0.0, 1.0),
                                    onStart: onSeekStart,
                                    onChanged: (f) => onSeek(f * duration),
                                    onEnd: onSeekEnd,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              ValueListenableBuilder<double>(
                                valueListenable: position,
                                builder: (context, at, _) => Text(
                                  '${formatReplayClock(at)} / ${formatReplayClock(duration)}',
                                  key: const ValueKey('replay-time'),
                                  style: AppType.tabular(theme.textTheme.labelSmall!.copyWith(color: dsh.textTertiary)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _InnerKey(
                                key: const ValueKey('replay-speed'),
                                label: l10n.viewReplaySpeed(speed),
                                minWidth: innerKey + 8,
                                onTap: onSpeed,
                                child: Text(
                                  '$speed×',
                                  style: AppType.tabular(
                                    theme.textTheme.labelLarge!.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A 36 tall key inside the capsule: a soft round (or stadium) fill.
class _InnerKey extends StatelessWidget {
  const _InnerKey({super.key, required this.label, required this.onTap, required this.child, this.minWidth});

  final String label;
  final VoidCallback onTap;
  final Widget child;
  final double? minWidth;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: Pressable(
        onTap: onTap,
        haptic: false,
        child: Container(
          height: ReplayHeader.innerKey,
          constraints: BoxConstraints(minWidth: minWidth ?? ReplayHeader.innerKey),
          padding: EdgeInsets.symmetric(horizontal: minWidth == null ? 0 : 10),
          alignment: Alignment.center,
          decoration: ShapeDecoration(
            color: scheme.onSurface.withValues(alpha: dark ? 0.10 : 0.06),
            shape: const StadiumBorder(),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The progress bar: a thin track, a small knob, drag or tap to seek.
class _Progress extends StatelessWidget {
  const _Progress({required this.value, required this.onStart, required this.onChanged, required this.onEnd});

  final double value;
  final VoidCallback onStart;
  final ValueChanged<double> onChanged;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SliderTheme(
      data: SliderThemeData(
        trackHeight: 4,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        activeTrackColor: scheme.primary,
        inactiveTrackColor: scheme.onSurface.withValues(alpha: 0.10),
        thumbColor: scheme.primary,
        overlayShape: SliderComponentShape.noOverlay,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7, elevation: 0, pressedElevation: 0),
        trackShape: const RoundedRectSliderTrackShape(),
      ),
      child: Slider(
        key: const ValueKey('replay-progress'),
        value: value,
        semanticFormatterCallback: (v) => '${(v * 100).round()}%',
        onChangeStart: (_) => onStart(),
        onChanged: onChanged,
        onChangeEnd: (_) => onEnd(),
      ),
    );
  }
}

/// The 对话字号 setting on the conversation only (as the chat does).
class _ChatTextScale extends ConsumerWidget {
  const _ChatTextScale({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factor = ref.watch(settingsProvider.select((s) => s.chatTextScale));
    if (factor == 1.0) return child;
    final media = MediaQuery.of(context);
    return MediaQuery(
      data: media.copyWith(textScaler: _Scaler(media.textScaler, factor)),
      child: child,
    );
  }
}

class _Scaler extends TextScaler {
  const _Scaler(this.base, this.factor);
  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize) * factor;

  @override
  double get textScaleFactor => scale(1);

  @override
  bool operator ==(Object other) => other is _Scaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}

enum _Slot { body, veil, header, bottom }

/// The chat's layout: the bottom bar first; the list ends just under its top
/// edge, the veil fills in behind it.
class _ReplayLayout extends MultiChildLayoutDelegate {
  _ReplayLayout(this.veilHeight);

  static const overlap = 6.0;

  final ValueNotifier<double> veilHeight;

  @override
  void performLayout(Size size) {
    final width = size.width;
    final along = BoxConstraints(minWidth: width, maxWidth: width);
    final bottom = layoutChild(_Slot.bottom, along);
    final top = size.height - bottom.height;
    positionChild(_Slot.bottom, Offset(0, top));
    veilHeight.value = math.max(0, bottom.height - overlap);
    layoutChild(_Slot.body, BoxConstraints.tight(Size(width, math.max(0, top + overlap))));
    positionChild(_Slot.body, Offset.zero);
    layoutChild(_Slot.veil, BoxConstraints.tight(size));
    positionChild(_Slot.veil, Offset.zero);
    layoutChild(_Slot.header, along);
    positionChild(_Slot.header, Offset.zero);
  }

  @override
  bool shouldRelayout(_ReplayLayout oldDelegate) => oldDelegate.veilHeight != veilHeight;
}
