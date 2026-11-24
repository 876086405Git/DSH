// The call page's smaller pieces: glass keys that give under the finger, the
// red hang-up key, the line saying what is happening (with breathing dots),
// the clock, what was heard, and her words arriving character by character.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../theme/theme.dart';
import 'call_visuals.dart';

/// A round key on frosted glass; [on] fills it white. Gives a little under
/// the finger and springs back.
class CallKey extends StatefulWidget {
  const CallKey({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.on = false,
    this.blur = true,
    this.size = 62,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool on;
  final bool blur;
  final double size;

  @override
  State<CallKey> createState() => _CallKeyState();
}

class _CallKeyState extends State<CallKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.on;
    final ink = CallInk.of(context);
    final duration = AppMotion.of(context, AppMotion.standard);
    final disc = AnimatedContainer(
      duration: duration,
      curve: AppMotion.std,
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? ink.on : ink.glass,
        border: Border.all(color: on ? Colors.transparent : ink.glassBorder),
      ),
      child: Center(
        child: AnimatedSwitcher(
          duration: duration,
          transitionBuilder: (child, animation) => RotationTransition(
            turns: Tween(begin: -0.12, end: 0.0).animate(animation),
            child: ScaleTransition(
              scale: Tween(begin: 0.6, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutBack)),
              child: FadeTransition(opacity: animation, child: child),
            ),
          ),
          child: Icon(
            widget.icon,
            key: ValueKey(widget.icon),
            size: widget.size * 0.38,
            color: on ? ink.onGlyph : ink.fg,
          ),
        ),
      ),
    );
    return Semantics(
      button: true,
      toggled: widget.on,
      enabled: widget.onTap != null,
      label: widget.label,
      child: GestureDetector(
        onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                widget.onTap!();
              },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _down ? 0.88 : 1,
              duration: AppMotion.of(context, _down ? AppMotion.press : AppMotion.standard),
              curve: _down ? Curves.easeOut : Curves.easeOutBack,
              child: widget.blur && !on
                  ? ClipOval(
                      child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18), child: disc),
                    )
                  : disc,
            ),
            const SizedBox(height: 10),
            ExcludeSemantics(
              child: Text(
                widget.label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: ink.dim, letterSpacing: 0.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The red key that ends the call, glowing softly; its receiver tips down when pressed.
class HangUpKey extends StatefulWidget {
  const HangUpKey({super.key, required this.icon, required this.label, required this.onTap, this.size = 74});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final double size;

  @override
  State<HangUpKey> createState() => _HangUpKeyState();
}

class _HangUpKeyState extends State<HangUpKey> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFFF4D61);
    const deep = Color(0xFFE0243F);
    return Semantics(
      button: true,
      enabled: widget.onTap != null,
      label: widget.label,
      child: GestureDetector(
        onTapDown: widget.onTap == null ? null : (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedScale(
              scale: _down ? 0.9 : 1,
              duration: AppMotion.of(context, _down ? AppMotion.press : AppMotion.standard),
              curve: _down ? Curves.easeOut : Curves.easeOutBack,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [red, deep],
                  ),
                  boxShadow: [
                    BoxShadow(color: red.withValues(alpha: _down ? 0.15 : 0.28), blurRadius: 22, spreadRadius: -6),
                  ],
                ),
                child: AnimatedRotation(
                  turns: _down ? -0.06 : 0,
                  duration: AppMotion.of(context, AppMotion.quick),
                  child: Icon(widget.icon, color: Colors.white, size: widget.size * 0.42),
                ),
              ),
            ),
            const SizedBox(height: 10),
            ExcludeSemantics(
              child: Text(
                widget.label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: CallInk.of(context).dim),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What is happening, sliding in when it changes; [dots] breathe after it.
class CallStatus extends StatelessWidget {
  const CallStatus({super.key, required this.text, this.dots = false, this.color});

  final String text;
  final bool dots;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.titleSmall
        ?.copyWith(color: color ?? CallInk.of(context).dim, letterSpacing: 1.2, fontWeight: FontWeight.w500);
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.standard),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      child: Row(
        key: ValueKey('$text$dots'),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text, style: style),
          if (dots) _Dots(color: style?.color ?? CallInk.of(context).dim),
        ],
      ),
    );
  }
}

class _Dots extends StatefulWidget {
  const _Dots({required this.color});

  final Color color;

  @override
  State<_Dots> createState() => _DotsState();
}

class _DotsState extends State<_Dots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduced(context)) _c.stop();
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(left: 3),
              child: Opacity(
                opacity: 0.25 + 0.75 * (0.5 + 0.5 * math.sin((_c.value - i * 0.18) * math.pi * 2)).clamp(0.0, 1.0),
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// mm:ss since the call connected, with a breathing live dot; ticks on its own.
class CallTimer extends StatefulWidget {
  const CallTimer({super.key, required this.since, required this.live});

  final DateTime? since;
  final bool live;

  @override
  State<CallTimer> createState() => _CallTimerState();
}

class _CallTimerState extends State<CallTimer> with SingleTickerProviderStateMixin {
  Timer? _tick;
  late final AnimationController _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
    ..repeat(reverse: true);
  Duration _frozen = Duration.zero;

  @override
  void initState() {
    super.initState();
    _next();
  }

  /// The next second on the clock, as it turns.
  void _next() {
    _tick?.cancel();
    _tick = Timer(Duration(milliseconds: 1000 - _elapsed().inMilliseconds % 1000), () {
      if (!mounted) return;
      if (widget.live) setState(() {});
      _next();
    });
  }

  @override
  void didUpdateWidget(CallTimer old) {
    super.didUpdateWidget(old);
    if (old.live && !widget.live) _frozen = _elapsed();
    if (widget.since != old.since) _next();
  }

  Duration _elapsed() => widget.since == null ? Duration.zero : DateTime.now().difference(widget.since!);

  @override
  void dispose() {
    _tick?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.live ? _elapsed() : _frozen;
    final text = '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    if (AppMotion.reduced(context)) _pulse.stop();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: Tween(begin: 0.35, end: 1.0).animate(_pulse),
          child: Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.live ? const Color(0xFF3FCB8E) : CallInk.of(context).faint,
              boxShadow: widget.live ? const [BoxShadow(color: Color(0x8852E3A4), blurRadius: 6)] : null,
            ),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          widget.since == null ? '--:--' : text,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: CallInk.of(context).faint,
            fontFeatures: const [FontFeature.tabularFigures()],
            letterSpacing: 0.8,
          ),
        ),
      ],
    );
  }
}

/// What the person said: up to [lines] lines, larger while they are still
/// speaking ([speaking]) and stepping back once she answers.
class HeardLine extends StatelessWidget {
  const HeardLine({super.key, required this.text, this.speaking = false, this.lines = 3});

  final String text;
  final bool speaking;
  final int lines;

  @override
  Widget build(BuildContext context) {
    final ink = CallInk.of(context);
    final base = Theme.of(context).textTheme.bodyLarge!;
    final style = speaking
        ? base.copyWith(color: ink.fg.withValues(alpha: 0.92), fontSize: 17, height: 1.55)
        : base.copyWith(color: ink.dim, fontSize: 15, height: 1.5);
    return AnimatedSwitcher(
      duration: AppMotion.of(context, AppMotion.emphasized),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      layoutBuilder: (current, previous) => Stack(alignment: Alignment.bottomCenter, children: [...previous, ?current]),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(animation),
          child: child,
        ),
      ),
      // A new thing said comes in; words added to the same one just grow.
      child: KeyedSubtree(
        key: ValueKey(text.isEmpty ? '' : text.substring(0, math.min(4, text.length))),
        child: text.isEmpty
            ? const SizedBox(width: double.infinity)
            : AnimatedDefaultTextStyle(
                style: style,
                duration: AppMotion.of(context, AppMotion.standard),
                curve: AppMotion.std,
                child: Builder(
                  builder: (context) => CaptionWindow(
                    span: TextSpan(text: text, style: DefaultTextStyle.of(context).style),
                    lines: lines,
                  ),
                ),
              ),
      ),
    );
  }
}

/// [span] centred in as many lines as it needs, at most [lines]: longer text
/// keeps its end in view, the top line fading out.
class CaptionWindow extends StatefulWidget {
  const CaptionWindow({super.key, required this.span, required this.lines});

  final InlineSpan span;
  final int lines;

  @override
  State<CaptionWindow> createState() => _CaptionWindowState();
}

class _CaptionWindowState extends State<CaptionWindow> {
  // Kept across builds: words that only fade in (a color change) keep the
  // last layout, so the reveal's every tick doesn't lay the caption out again.
  final _painter = TextPainter(textAlign: TextAlign.center);

  @override
  void initState() {
    super.initState();
    PaintingBinding.instance.systemFonts.addListener(_painter.markNeedsLayout);
  }

  @override
  void dispose() {
    PaintingBinding.instance.systemFonts.removeListener(_painter.markNeedsLayout);
    _painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final span = widget.span;
      final lines = widget.lines;
      final scaler = MediaQuery.textScalerOf(context);
      _painter
        ..text = span
        ..textDirection = Directionality.of(context)
        ..textScaler = scaler
        ..layout(maxWidth: box.maxWidth);
      final count = _painter.computeLineMetrics().length;
      final height = _painter.height;
      final text = Text.rich(span, textAlign: TextAlign.center, textScaler: scaler);
      if (count <= lines) return SizedBox(width: double.infinity, child: text);
      return SizedBox(
        width: double.infinity,
        height: height / count * lines,
        child: ShaderMask(
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: const [Colors.transparent, Colors.white],
            stops: [0, 0.9 / lines],
          ).createShader(rect),
          blendMode: BlendMode.dstIn,
          child: ClipRect(
            child: OverflowBox(alignment: Alignment.bottomCenter, maxHeight: double.infinity, child: text),
          ),
        ),
      );
    },
  );
}

/// [i] moved back off the middle of a surrogate pair: half an emoji in a
/// span of its own is not text, and draws as a replacement mark.
int _whole(String text, int i) =>
    i > 0 && i < text.length && (text.codeUnitAt(i) & 0xFC00) == 0xDC00 && (text.codeUnitAt(i - 1) & 0xFC00) == 0xD800
    ? i - 1
    : i;

/// Her words as they arrive: the newest characters fade in one after another;
/// past [lines] lines the oldest fade out at the top.
class RevealText extends StatefulWidget {
  const RevealText({super.key, required this.text, this.style, this.lines = 5, this.window = 220, this.done = false});

  final String text;

  /// No more is coming: the last characters settle in.
  final bool done;
  final TextStyle? style;
  final int lines;

  /// At most this many of the last characters are shown.
  final int window;

  @override
  State<RevealText> createState() => _RevealTextState();
}

class _RevealTextState extends State<RevealText> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  double _shown = 0;
  Duration _last = Duration.zero;

  /// How many characters fade in together.
  static const _tail = 8;

  /// Where the reveal is headed: the end, its newest characters still coming
  /// in; once [RevealText.done], past it, so they come in whole. Nothing to
  /// reveal holds it at the start, for the words that come next.
  double get _target => widget.text.isEmpty ? 0 : widget.text.length + (widget.done ? _tail.toDouble() : 0.0);

  @override
  void didUpdateWidget(RevealText old) {
    super.didUpdateWidget(old);
    if (widget.text.isEmpty ||
        !widget.text.startsWith(old.text.substring(0, math.min(old.text.length, _shown.floor())))) {
      _shown = 0;
    }
    if (_shown < _target && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.text.isNotEmpty) _ticker.start();
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero ? 0.016 : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final target = _target;
    // Catch up faster the further behind: never more than a second late.
    final rate = math.max(26.0, (target - _shown) * 2.2);
    _shown = math.min(target, _shown + rate * dt);
    if (!AppMotion.reduced(context)) setState(() {});
    if (_shown >= target) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.text;
    final shown = AppMotion.reduced(context) ? text.length + _tail.toDouble() : _shown;
    final end = _whole(text, shown.ceil().clamp(0, text.length));
    // Past an emoji's first half, not back before it: the window stays [window] long.
    final cut = math.max(0, end - widget.window);
    final start = _whole(text, cut) == cut ? cut : cut + 1;
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final color = base.color ?? Colors.white;
    final spans = <InlineSpan>[];
    if (start > 0) spans.add(TextSpan(text: '…', style: base));
    final solidEnd = _whole(text, math.max(start, end - _tail));
    if (solidEnd > start) spans.add(TextSpan(text: text.substring(start, solidEnd), style: base));
    for (var i = solidEnd; i < end;) {
      final next = _whole(text, i + 1) == i ? i + 2 : i + 1;
      final fade = ((shown - i) / _tail).clamp(0.0, 1.0);
      spans.add(
        TextSpan(
          text: text.substring(i, next),
          style: base.copyWith(color: color.withValues(alpha: color.a * fade)),
        ),
      );
      i = next;
    }
    if (spans.isEmpty) return const SizedBox(width: double.infinity);
    // The newest lines in view: the words grow upward, as tall as they need.
    return CaptionWindow(
      span: TextSpan(children: spans),
      lines: widget.lines,
    );
  }
}
