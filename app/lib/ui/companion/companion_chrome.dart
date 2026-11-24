// Everything 伙伴小屋 draws in Flutter on top of her: the top bar with her name and
// what she's up to, her words, the input, and the first-run and failure screens.
// All of it is built on the app's glass surfaces under a dark theme, because the
// water behind is dark at every hour (companion_page.dart wraps it).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../pets/pet_signals.dart';
import '../../pets/pet_state.dart';
import '../common/pressable.dart';
import '../common/typing_indicator.dart';
import '../pets/pet_sprite.dart';
import '../theme/app_icons.dart';
import '../theme/glass.dart';
import '../theme/motion.dart';
import '../theme/semantic_colors.dart';
import '../theme/surfaces.dart';

/// Screen edge to floating controls, and their height (polish-guide.md §1).
const companionEdge = 12.0;
const _barHeight = 44.0;

// Over her stage (companion_page.dart): every glass here but the log's close
// button sits in one BackdropGroup and shares one backdrop read between them
// (`grouped: true`). They never overlap one another, so it looks the same.

/// Deep water behind her words and the input: reply text has to stay readable
/// over a white apron and a bright midday sky alike.
GlassStyle companionDeepGlass(BuildContext context) =>
    DshSurfaces.of(context)
        .glass(GlassTier.sheet)
        .copyWith(fill: const Color(0xC40E2740), fallbackFill: const Color(0xF20E2740), blurSigma: 22, saturation: 1.3);

/// The room's glass: everything over her (top bar, sheets, their cards) takes
/// the water's blue instead of the app's grey, and floats without a heavy drop.
DshSurfaces companionWaterSurfaces(DshSurfaces base) {
  const deep = Color(0xFF0B2440);
  const white = Color(0xFFFFFFFF);
  return base.copyWith(
    // Her other pages stand in the same water as her room.
    backdropTop: const Color(0xFF15426B),
    backdropBottom: const Color(0xFF071A30),
    glowPrimary: const Color(0x332C8BD0),
    glowSecondary: const Color(0x1F2AA198),
    chrome: base.chrome.copyWith(
      fill: const Color(0x8C123A63),
      fallbackFill: const Color(0xF2123A63),
      hairline: white.withValues(alpha: 0.12),
      rim: white.withValues(alpha: 0.16),
      shadows: const [BoxShadow(color: Color(0x2E000814), blurRadius: 18, offset: Offset(0, 6))],
    ),
    sheet: base.sheet.copyWith(
      fill: deep.withValues(alpha: 0.9),
      fallbackFill: deep,
      hairline: white.withValues(alpha: 0.10),
      rim: white.withValues(alpha: 0.14),
    ),
    card: base.card.copyWith(
      fill: const Color(0x14A9D6FF),
      fallbackFill: const Color(0xFF12304F),
      hairline: white.withValues(alpha: 0.08),
      rim: white.withValues(alpha: 0.08),
    ),
  );
}

/// What she's doing, for the line under her name.
enum CompanionActivity { idle, listening, thinking, speaking, sleeping, away, snacking, playing, resting }

class CompanionRoundButton extends StatelessWidget {
  const CompanionRoundButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.grouped = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// In the room's top bar; not over the log, which has to blur the log.
  final bool grouped;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    semanticLabel: label,
    child: GlassSurface(
      tier: GlassTier.chrome,
      grouped: grouped,
      circle: true,
      child: SizedBox.square(
        dimension: _barHeight,
        child: Icon(icon, size: 21, color: Theme.of(context).colorScheme.onSurface),
      ),
    ),
  );
}

/// Her name and what she's doing: the page's one quiet line of text.
class CompanionNamePlate extends StatelessWidget {
  const CompanionNamePlate({super.key, required this.name, required this.activity});

  final String name;
  final CompanionActivity activity;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final status = switch (activity) {
      CompanionActivity.idle => l10n.companionStatusIdle,
      CompanionActivity.listening => l10n.companionStatusListening,
      CompanionActivity.thinking => l10n.companionStatusThinking,
      CompanionActivity.speaking => l10n.companionStatusSpeaking,
      CompanionActivity.sleeping => l10n.companionStatusSleeping,
      CompanionActivity.away => l10n.companionStatusAway,
      CompanionActivity.snacking => l10n.companionStatusSnacking,
      CompanionActivity.playing => l10n.companionStatusPlaying,
      CompanionActivity.resting => l10n.companionStatusResting,
    };
    final dot = switch (activity) {
      CompanionActivity.thinking || CompanionActivity.speaking => theme.colorScheme.primary,
      CompanionActivity.listening => const Color(0xFF7BE0B8),
      CompanionActivity.sleeping || CompanionActivity.away => colors.textTertiary,
      CompanionActivity.idle => const Color(0xFF9FD8F2),
      CompanionActivity.snacking => const Color(0xFFF2D5AC),
      CompanionActivity.playing => const Color(0xFFB4DFE8),
      CompanionActivity.resting => const Color(0xFF6EB5A8),
    };
    return Semantics(
      label: '$name，$status',
      child: ExcludeSemantics(
        child: GlassSurface(
          tier: GlassTier.chrome,
          grouped: true,
          stadium: true,
          child: SizedBox(
            height: _barHeight,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 10),
                  AnimatedContainer(
                    duration: AppMotion.of(context, AppMotion.standard),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.standard),
                    child: Text(
                      status,
                      key: ValueKey(activity),
                      maxLines: 1,
                      style: theme.textTheme.labelMedium?.copyWith(color: colors.textTertiary),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Fades in and rises a little; every floating piece of text uses this.
class _Rise extends StatelessWidget {
  const _Rise({required this.child, this.onFrame});

  final Widget? child;
  final VoidCallback? onFrame;

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.of(context, AppMotion.standard);
    return AnimatedSize(
      duration: duration,
      curve: AppMotion.std,
      alignment: Alignment.bottomCenter,
      onEnd: onFrame,
      child: AnimatedSwitcher(
        duration: duration,
        switchInCurve: AppMotion.enter,
        switchOutCurve: AppMotion.exit,
        layoutBuilder: (current, previous) =>
            Stack(alignment: Alignment.bottomCenter, children: [...previous, ?current]),
        transitionBuilder: (child, animation) {
          final transition = FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(animation),
              child: child,
            ),
          );
          if (onFrame == null) return transition;
          return AnimatedBuilder(
            animation: animation,
            child: transition,
            builder: (_, child) {
              onFrame!();
              return child!;
            },
          );
        },
        child: child ?? const SizedBox(key: ValueKey('nothing'), width: double.infinity),
      ),
    );
  }
}

/// What she says. Long replies scroll inside, newest at the bottom, and fade out
/// at the top edge instead of being cut.
class CompanionSpeech extends StatelessWidget {
  const CompanionSpeech({
    super.key,
    this.text,
    this.thinking = false,
    this.error = false,
    this.onPullBack,
    this.textKey,
    this.onFrame,
  });

  final String? text;
  final bool thinking;
  final bool error;
  final Key? textKey;

  /// Schedules a read after this frame's paint, including a scroll or fade.
  final VoidCallback? onFrame;

  /// Pulling down past the top of what she just said: read further back.
  final VoidCallback? onPullBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = text;
    Widget? bubble;
    if (thinking && words == null) {
      bubble = Align(
        key: const ValueKey('thinking'),
        alignment: Alignment.centerLeft,
        child: GlassSurface(
          tier: GlassTier.card,
          style: companionDeepGlass(context),
          grouped: true,
          borderRadius: BorderRadius.circular(20),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Builder(
            builder: (context) => Visibility.of(context)
                ? TypingIndicator(color: theme.colorScheme.onSurfaceVariant)
                : const SizedBox.square(dimension: 20),
          ),
        ),
      );
    } else if (words != null) {
      final maxHeight = MediaQuery.sizeOf(context).height * 0.26;
      bubble = Semantics(
        key: const ValueKey('words'),
        liveRegion: true,
        child: SizedBox(
          width: double.infinity,
          child: GlassSurface(
            tier: GlassTier.card,
            style: companionDeepGlass(context),
            grouped: true,
            borderRadius: BorderRadius.circular(22),
            padding: const EdgeInsets.fromLTRB(18, 13, 18, 14),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0, 0.1, 1],
                  colors: [Color(0x00FFFFFF), Color(0xFFFFFFFF), Color(0xFFFFFFFF)],
                ).createShader(rect),
                child: _PullBack(
                  onPull: onPullBack,
                  onFrame: onFrame,
                  child: SingleChildScrollView(
                    reverse: true,
                    // Even a short line can be pulled on.
                    physics: onPullBack == null
                        ? null
                        : const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        words,
                        key: textKey,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          height: 1.5,
                          color: error ? theme.colorScheme.error : theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return _Rise(onFrame: onFrame, child: bubble);
  }
}

/// A finger dragging past the oldest end of a reversed scroll view, far enough
/// to mean it: [onPull], once per drag.
class _PullBack extends StatefulWidget {
  const _PullBack({required this.onPull, required this.child, this.onFrame});

  final VoidCallback? onPull;
  final Widget child;
  final VoidCallback? onFrame;

  @override
  State<_PullBack> createState() => _PullBackState();
}

class _PullBackState extends State<_PullBack> {
  static const _far = 48.0;
  double _pulled = 0;
  bool _fired = false;

  bool _onNotification(ScrollNotification notification) {
    if (notification.depth == 0) widget.onFrame?.call();
    final pull = widget.onPull;
    if (pull == null) return false;
    switch (notification) {
      case ScrollStartNotification():
        _pulled = 0;
        _fired = false;
      // In a reversed view the oldest end is the far end: past it is positive.
      case OverscrollNotification(:final overscroll, :final dragDetails?):
        // Down past the edge adds; any way back takes it off again.
        final dy = dragDetails.delta.dy;
        _pulled = math.max(0.0, _pulled + (dy > 0 && overscroll > 0 ? overscroll : -dy.abs()));
        if (!_fired && _pulled > _far) {
          _fired = true;
          pull();
        }
      case ScrollUpdateNotification(:final dragDetails?) when dragDetails.delta.dy < 0:
        _pulled = math.max(0.0, _pulled + dragDetails.delta.dy);
      default:
        break;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (notification) {
      if (notification.depth == 0) widget.onFrame?.call();
      return false;
    },
    child: NotificationListener<ScrollNotification>(onNotification: _onNotification, child: widget.child),
  );
}

/// What the person just said, until she starts answering.
class CompanionMyLine extends StatelessWidget {
  const CompanionMyLine({super.key, this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final line = text;
    return _Rise(
      child: line == null
          ? null
          : Align(
              key: ValueKey(line),
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.74),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.86),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                      child: Text(
                        line,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onPrimary),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

/// A small pill floating over the input: a first-time hint, or something that
/// needs the person elsewhere.
class CompanionPill extends StatelessWidget {
  const CompanionPill({super.key, required this.icon, required this.label, this.onTap, this.tone});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pill = GlassSurface(
      tier: GlassTier.pill,
      style: companionDeepGlass(context),
      grouped: true,
      stadium: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: tone ?? theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 7),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge),
          ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Center(
        child: onTap == null ? pill : Pressable(onTap: onTap, child: pill),
      ),
    );
  }
}

/// How well she knows the person: four small pearls, lit up to the step, and its name.
class CompanionBondMeter extends StatelessWidget {
  const CompanionBondMeter({super.key, required this.step, required this.label});

  final int step;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary)),
            const SizedBox(width: 8),
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i <= step ? const Color(0xFFFF9DB5) : colors.textTertiary.withValues(alpha: 0.3),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The seaweed green her cushion and the resting dot share.
const _seaweed = Color(0xFF6EB5A8);

/// Her invitation to rest on the cushion, above the input (Pro C452 §6): a quiet
/// card, never spoken, never announced, never focused. A thin line runs down
/// while it waits; with a screen reader it waits until answered, and no line.
class CompanionInvite extends StatelessWidget {
  const CompanionInvite({
    super.key,
    required this.ticket,
    required this.text,
    required this.accept,
    required this.decline,
    required this.onAccept,
    required this.onDecline,
    this.remaining,
    this.total = const Duration(seconds: 8),
    this.mark,
  });

  /// The invitation shown, or null for none.
  final String? ticket;
  final String text;
  final String accept;
  final String decline;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  /// Until it goes by itself; null while it is held.
  final Duration? remaining;
  final Duration total;

  /// What the offer is about, at a glance; her cushion by default.
  final Widget? mark;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = ticket;
    final left = remaining;
    final card = id == null
        ? null
        : Padding(
            key: ValueKey('invite-$id'),
            padding: const EdgeInsets.only(bottom: 8),
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              child: GlassSurface(
                tier: GlassTier.card,
                style: companionDeepGlass(context),
                grouped: true,
                borderRadius: BorderRadius.circular(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: ExcludeSemantics(child: mark ?? const CompanionCushionMark()),
                          ),
                          const SizedBox(width: 11),
                          Expanded(child: Text(text, style: theme.textTheme.bodyLarge?.copyWith(height: 1.45))),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 10, 8),
                      // Side by side while they fit, one above the other in large type.
                      child: OverflowBar(
                        alignment: MainAxisAlignment.end,
                        overflowAlignment: OverflowBarAlignment.end,
                        spacing: 6,
                        overflowSpacing: 4,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                              foregroundColor: theme.colorScheme.onSurfaceVariant,
                              shape: const StadiumBorder(),
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                            ),
                            onPressed: onDecline,
                            child: Text(decline),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              shape: const StadiumBorder(),
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                            ),
                            onPressed: onAccept,
                            child: Text(accept),
                          ),
                        ],
                      ),
                    ),
                    if (left != null && !AppMotion.reduced(context))
                      _Fuse(
                        key: ValueKey('fuse-$id-${left.inMilliseconds ~/ 250}'),
                        from: (left.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
                        duration: left,
                      ),
                  ],
                ),
              ),
            ),
          );
    return _Rise(child: card);
  }
}

/// How long the invitation still waits: a hairline closing in from both ends.
class _Fuse extends StatelessWidget {
  const _Fuse({super.key, required this.from, required this.duration});

  final double from;
  final Duration duration;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: from, end: 0),
    duration: duration,
    builder: (context, t, _) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
      child: Center(
        child: FractionallySizedBox(
          widthFactor: t,
          child: Container(
            height: 2,
            decoration: BoxDecoration(color: _seaweed.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(1)),
          ),
        ),
      ),
    ),
  );
}

/// Her seaweed cushion, small: what the invitation is about, at a glance.
class CompanionCushionMark extends StatelessWidget {
  const CompanionCushionMark({super.key});

  @override
  Widget build(BuildContext context) => const CustomPaint(size: Size(26, 18), painter: _CushionPainter());
}

class _CushionPainter extends CustomPainter {
  const _CushionPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    const shade = Color(0xFF3F8C7F);
    const light = Color(0xFF8ED2C3);
    // Leaf blades behind it on the right, like the one in her room.
    Path leaf(double baseX, double tipX, double tipY, double lean) => Path()
      ..moveTo(baseX - w * 0.05, h * 0.56)
      ..quadraticBezierTo(baseX - w * 0.06 + lean, h * 0.2, tipX, tipY)
      ..quadraticBezierTo(baseX + w * 0.07 + lean, h * 0.26, baseX + w * 0.05, h * 0.56)
      ..close();
    final blade = Paint()..color = _seaweed;
    canvas
      ..drawPath(leaf(w * 0.74, w * 0.78, 0, -w * 0.02), blade)
      ..drawPath(leaf(w * 0.86, w * 0.99, h * 0.1, w * 0.05), blade)
      ..drawRRect(RRect.fromLTRBR(0, h * 0.4, w, h, Radius.elliptical(w / 2, h * 0.32)), Paint()..color = shade)
      ..drawOval(Rect.fromLTRB(w * 0.04, h * 0.34, w * 0.96, h * 0.78), Paint()..color = light)
      // The quilting across the top.
      ..drawPath(
        Path()
          ..moveTo(w * 0.18, h * 0.58)
          ..quadraticBezierTo(w * 0.34, h * 0.48, w * 0.5, h * 0.57)
          ..quadraticBezierTo(w * 0.66, h * 0.66, w * 0.82, h * 0.56),
        Paint()
          ..color = _seaweed
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3
          ..strokeCap = StrokeCap.round,
      );
  }

  @override
  bool shouldRepaint(_CushionPainter oldDelegate) => false;
}

class CompanionComposer extends StatelessWidget {
  const CompanionComposer({
    super.key,
    required this.input,
    required this.focus,
    required this.hint,
    required this.running,
    required this.busy,
    required this.listening,
    required this.voiceAvailable,
    required this.onSend,
    required this.onStop,
    required this.onVoice,
    this.onUserInput,
    this.onCall,
  });

  /// 语音通话 with her; null hides the key.
  final VoidCallback? onCall;

  /// The person tapped into the field or typed: not text set by the page.
  final VoidCallback? onUserInput;

  final TextEditingController input;
  final FocusNode focus;
  final String hint;
  final bool running;
  final bool busy;
  final bool listening;
  final bool voiceAvailable;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onVoice;

  /// Round keys sit concentric in the capsule (polish-guide.md §1).
  static const _keySize = 40.0;
  static const _keyInset = 6.0;

  /// Text changes rebuild the composer, not her room.
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: input, builder: (context, _) => _buildComposer(context));

  Widget _buildComposer(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final hasText = input.text.trim().isNotEmpty;

    final Widget key;
    if (hasText) {
      key = _ComposerKey(
        key: const ValueKey('send'),
        icon: AppIcons.send,
        label: l10n.companionSend,
        filled: true,
        onTap: busy ? null : onSend,
      );
    } else if (running) {
      key = _ComposerKey(
        key: const ValueKey('stop'),
        icon: AppIcons.stopGenerating,
        label: l10n.companionStop,
        filled: true,
        onTap: onStop,
      );
    } else if (voiceAvailable) {
      key = _ComposerKey(
        key: ValueKey(listening ? 'listening' : 'voice'),
        icon: listening ? AppIcons.stopGenerating : AppIcons.voice,
        label: l10n.companionVoice,
        filled: listening,
        onTap: onVoice,
      );
    } else {
      key = _ComposerKey(key: const ValueKey('idle'), icon: AppIcons.send, label: l10n.companionSend, filled: false);
    }

    return GlassSurface(
      tier: GlassTier.chrome,
      style: companionDeepGlass(context),
      grouped: true,
      borderRadius: BorderRadius.circular(_keySize / 2 + _keyInset),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, _keyInset, _keyInset, _keyInset),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _keySize),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextField(
                    controller: input,
                    focusNode: focus,
                    onTap: onUserInput,
                    onChanged: onUserInput == null ? null : (_) => onUserInput!(),
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    style: theme.textTheme.bodyLarge,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      hintText: listening ? l10n.companionListening : hint,
                      hintStyle: theme.textTheme.bodyLarge?.copyWith(color: colors.textTertiary),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (onCall != null && !hasText && !running) ...[
              _ComposerKey(icon: AppIcons.call, label: l10n.speechCallTile, filled: false, onTap: onCall),
              const SizedBox(width: 4),
            ],
            AnimatedSwitcher(
              duration: AppMotion.of(context, AppMotion.quick),
              switchInCurve: AppMotion.enter,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: Tween(begin: 0.82, end: 1.0).animate(animation), child: child),
              ),
              child: key,
            ),
          ],
        ),
      ),
    );
  }
}

class _ComposerKey extends StatelessWidget {
  const _ComposerKey({super.key, required this.icon, required this.label, required this.filled, this.onTap});

  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return Pressable(
      onTap: onTap,
      enabled: enabled,
      semanticLabel: label,
      child: Container(
        width: CompanionComposer._keySize,
        height: CompanionComposer._keySize,
        decoration: BoxDecoration(
          color: filled ? scheme.primary.withValues(alpha: enabled ? 1 : 0.5) : Colors.transparent,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 20,
          color: filled ? scheme.onPrimary : scheme.onSurfaceVariant.withValues(alpha: enabled ? 1 : 0.45),
        ),
      ),
    );
  }
}

/// The water, for screens without her: same colours as the stage at midday.
class CompanionWater extends StatelessWidget {
  const CompanionWater({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(0, -1.25),
        radius: 1.5,
        colors: [Color(0xFF8ACBE0), Color(0xFF3E94BC), Color(0xFF1C5A8C), Color(0xFF0D2F55)],
        stops: [0, 0.32, 0.66, 1],
      ),
    ),
    child: child,
  );
}

/// The little pixel whale girl the app already ships: on first run and when
/// something failed, she stands in for the Live2D one.
class CompanionPixelWhale extends ConsumerWidget {
  const CompanionPixelWhale({super.key, this.state = PetStateName.idle, this.bodyHeight = 92});

  final PetStateName state;

  /// Roughly how tall she should be, in logical pixels.
  final double bodyHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pack = ref.watch(petPackProvider('whale-girl')).value;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (pack == null) return SizedBox(height: bodyHeight);
    // Whole device pixels per art pixel, or pixel art goes soft.
    final k = math.max(1, (bodyHeight * dpr / pack.contentBox.height).round());
    final scale = k / dpr;
    return SizedBox(
      width: pack.canvas.width * scale,
      height: pack.canvas.height * scale,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: PetSprite(pack: pack, anim: pack.animFor(state), scale: scale),
          ),
        ],
      ),
    );
  }
}

/// First run, and the way back when she couldn't load: a picture, one sentence,
/// one button.
class CompanionWelcome extends StatelessWidget {
  const CompanionWelcome({
    super.key,
    required this.title,
    required this.message,
    required this.action,
    required this.busy,
    required this.onAction,
    this.state = PetStateName.idle,
    this.error,
    this.secondary,
    this.onSecondary,
    this.tertiary,
    this.onTertiary,
  });

  final String title;
  final String message;
  final String action;
  final bool busy;
  final VoidCallback onAction;

  /// A quieter second way, under the button.
  final String? secondary;
  final VoidCallback? onSecondary;

  /// One more way in under the others (创意工坊).
  final String? tertiary;
  final VoidCallback? onTertiary;
  final PetStateName state;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return CompanionWater(
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 72),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CompanionPixelWhale(state: state),
                  const SizedBox(height: 28),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.55,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 28),
                  AnimatedSwitcher(
                    duration: AppMotion.of(context, AppMotion.standard),
                    child: busy
                        ? const SizedBox.square(
                            key: ValueKey('busy'),
                            dimension: 48,
                            child: Center(
                              child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.2)),
                            ),
                          )
                        : SizedBox(
                            key: const ValueKey('action'),
                            height: 48,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                shape: const StadiumBorder(),
                                padding: const EdgeInsets.symmetric(horizontal: 28),
                              ),
                              onPressed: onAction,
                              child: Text(action),
                            ),
                          ),
                  ),
                  if (secondary case final label? when !busy)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: theme.colorScheme.onSurfaceVariant,
                          shape: const StadiumBorder(),
                        ),
                        onPressed: onSecondary,
                        child: Text(label),
                      ),
                    ),
                  if (tertiary case final label? when !busy)
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                        shape: const StadiumBorder(),
                      ),
                      onPressed: onTertiary,
                      child: Text(label),
                    ),
                  if (error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                    ),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        context.l10n.companionPrivacyLine,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// While the stage loads: the same pixel whale, swimming over.
class CompanionArriving extends StatelessWidget {
  const CompanionArriving({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CompanionPixelWhale(bodyHeight: 64),
          const SizedBox(height: 14),
          Text(
            context.l10n.companionArriving,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
