// 设置 › 主题 › 壁纸: the default backdrop or the user's own picture, side by side as two small
// phones (the launch screen's card, same grid); where the picture sits, how soft and how calm,
// replace it, preview it.
//
//          ╭──────╮    ╭──────╮
//          │ ◖══◗ │    │▒◖══◗▒│      two phones the screen's shape, centred as a pair 12
//          │  ▭▭  │    │▒ ▭▭ ▒│      apart, each a third of the card's inner width, a sketch
//          ╰──────╯    ╰──────╯      of the chat on each; the one in use ringed in the accent
//            默认         自定义
//   调整位置                                 ›     ┐
//   模糊                                   30%     │
//   ━━━━━━━━━●──────────────────────────────       │ only while the custom one is in use
//   提亮 (light) / 压暗 (dark)              20%     │
//   ━━━━━━●─────────────────────────────────       │
//   更换图片                                 ›     ┘
//   预览                                     ›
//
// The custom phone shows the real bake (small), redone as a slider moves; the backdrop behind
// the app is baked again once the slider is let go.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/wallpaper_state.dart';
import '../../../wallpaper/custom_wallpaper.dart';
import '../../../wallpaper/wallpaper_look.dart';
import '../../../wallpaper/wallpaper_render.dart';
import '../../common/brief_notice.dart';
import '../../common/expand_reveal.dart';
import '../../common/pressable.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../wallpaper/wallpaper_backdrop.dart';
import '../../wallpaper/wallpaper_editor_page.dart';
import '../../wallpaper/wallpaper_preview_page.dart';
import '../settings_widgets.dart';
import 'appearance_page.dart' show PickerGrid;
import 'launch_screen_section.dart' show LaunchScreenPicker;

/// The card's rows.
class WallpaperSection extends ConsumerStatefulWidget {
  const WallpaperSection({super.key});

  @override
  ConsumerState<WallpaperSection> createState() => _WallpaperSectionState();
}

class _WallpaperSectionState extends ConsumerState<WallpaperSection> {
  bool _busy = false;

  /// The wallpaper as a slider being dragged has it; null when nothing is being dragged.
  CustomWallpaper? _draft;

  /// The custom phone's picture: the real bake, small. [_thumbFor] is what it was baked from.
  ui.Image? _thumb;
  (CustomWallpaper, WallpaperFrame)? _thumbFor;
  bool _broken = false;
  bool _baking = false;
  (CustomWallpaper, WallpaperFrame)? _next;

  @override
  void dispose() {
    _thumb?.dispose();
    super.dispose();
  }

  /// Pixels per dp for the phones: about what they show at.
  double _density(BuildContext context) => math.min(1.0, 0.3 * MediaQuery.devicePixelRatioOf(context));

  /// Bakes the custom phone's picture for [wallpaper] unless it already shows it; while a bake
  /// runs, only the latest ask waits.
  void _want(CustomWallpaper wallpaper, WallpaperFrame frame) {
    final key = (wallpaper, frame);
    if (_thumbFor == key && (_thumb != null || _broken)) return;
    if (_baking) {
      _next = key;
      return;
    }
    unawaited(_bake(key));
  }

  Future<void> _bake((CustomWallpaper, WallpaperFrame) key) async {
    _baking = true;
    final density = _density(context);
    final image = await ref.read(wallpaperRendererProvider).bake(key.$1, key.$2, density: density);
    _baking = false;
    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() {
      _thumb?.dispose();
      _thumb = image;
      _thumbFor = key;
      _broken = image == null;
    });
    final next = _next;
    _next = null;
    if (next != null && next != key) _want(next.$1, next.$2);
  }

  Future<void> _choose() async {
    if (_busy) return;
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _busy = true);
    LaunchImportProblem? problem;
    try {
      problem = await ref.read(customWallpaperProvider.notifier).choose();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    final text = switch (problem) {
      null => l10n.wallpaperChanged,
      LaunchImportProblem.cancelled => null,
      LaunchImportProblem.unavailable => l10n.wallpaperUnavailable,
      // overLimit is the launch screen's (next to clips); a photos-only import says tooLarge.
      LaunchImportProblem.tooLarge || LaunchImportProblem.overLimit => l10n.wallpaperTooLarge,
      LaunchImportProblem.unsupported => l10n.wallpaperUnsupported,
      LaunchImportProblem.unreadable => l10n.wallpaperUnreadable,
    };
    if (text != null) messenger?.showBriefNotice(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final stored = ref.watch(customWallpaperProvider).value;
    final notifier = ref.read(customWallpaperProvider.notifier);
    final wallpaper = _draft ?? stored;
    final on = stored != null && stored.on;
    final brightness = Theme.of(context).brightness;
    final frame = WallpaperBackdrop.frameOf(context);
    if (wallpaper != null) _want(wallpaper, frame);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WallpaperPicker(
          custom: stored,
          thumb: wallpaper == null ? null : _thumb,
          broken: _broken,
          busy: _busy,
          onDefault: () => unawaited(notifier.use(false)),
          onCustom: stored == null ? () => unawaited(_choose()) : () => unawaited(notifier.use(true)),
        ),
        ExpandReveal(
          open: on,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 2,
            children: [
              SettingsTile(
                key: const ValueKey('wallpaper-frame'),
                title: l10n.wallpaperFrame,
                onTap: stored == null ? null : () => unawaited(showWallpaperEditor(context, stored)),
              ),
              WallpaperSliderRow(
                key: const ValueKey('wallpaper-blur'),
                title: l10n.wallpaperBlur,
                value: wallpaper?.blur ?? CustomWallpaper.defaultBlur,
                onChanged: (v) => setState(() => _draft = (_draft ?? stored)?.copyWith(blur: v)),
                onChangeEnd: (v) {
                  setState(() => _draft = null);
                  unawaited(notifier.setBlur(v));
                },
              ),
              WallpaperSliderRow(
                key: const ValueKey('wallpaper-tone'),
                title: brightness == Brightness.dark ? l10n.wallpaperDim : l10n.wallpaperLighten,
                value: wallpaper?.toneFor(brightness) ?? CustomWallpaper.defaultLighten,
                onChanged: (v) => setState(() => _draft = (_draft ?? stored)?.withTone(brightness, v)),
                onChangeEnd: (v) {
                  setState(() => _draft = null);
                  unawaited(notifier.setTone(brightness, v));
                },
              ),
              SettingsTile(
                key: const ValueKey('wallpaper-replace'),
                title: l10n.wallpaperReplace,
                onTap: _busy ? null : () => unawaited(_choose()),
              ),
            ],
          ),
        ),
        SettingsTile(
          key: const ValueKey('wallpaper-preview'),
          title: l10n.wallpaperPreview,
          onTap: () => unawaited(showWallpaperPreview(context)),
        ),
      ],
    );
  }
}

/// The blur / tone rows: [SettingsSliderTile] with its defaults (5% steps, read as a percent).
typedef WallpaperSliderRow = SettingsSliderTile;

/// 默认 and 自定义 as two small phones, centred as a pair: the launch screen card's geometry
/// ([LaunchScreenPicker]'s ring, radius and shape).
class WallpaperPicker extends StatelessWidget {
  const WallpaperPicker({
    super.key,
    required this.custom,
    required this.thumb,
    required this.onDefault,
    required this.onCustom,
    this.broken = false,
    this.busy = false,
  });

  final CustomWallpaper? custom;

  /// The custom one baked small; null while it bakes.
  final ui.Image? thumb;

  /// The picture couldn't be read.
  final bool broken;

  /// A pick is being read in: the custom phone shows a small ring.
  final bool busy;
  final VoidCallback onDefault;
  final VoidCallback onCustom;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final on = custom != null && custom!.on;
    final aspect = LaunchScreenPicker.aspectFor(MediaQuery.sizeOf(context));
    const room = LaunchScreenPicker.room;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PickerGrid.inset - room,
        PickerGrid.inset - room,
        PickerGrid.inset - room,
        PickerGrid.inset,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // A third of the inner width, as the theme-mode phones above.
          final inner = constraints.maxWidth - 2 * room;
          final width = (inner - 2 * PickerGrid.gap) / 3;
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              WallpaperPhone(
                key: const ValueKey('wallpaper-default'),
                label: l10n.wallpaperDefault,
                width: width,
                aspect: aspect,
                selected: !on,
                onTap: onDefault,
                child: const _Screen(child: AppBackdrop(child: _ChatSketch())),
              ),
              const SizedBox(width: PickerGrid.gap - 2 * room),
              WallpaperPhone(
                key: const ValueKey('wallpaper-custom'),
                label: l10n.wallpaperCustom,
                width: width,
                aspect: aspect,
                selected: on,
                onTap: onCustom,
                child: _CustomMini(custom: custom, thumb: thumb, broken: broken, busy: busy),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One phone of the pair: its screen clipped to the phone's corners, a hairline edge, a ring in
/// the accent when chosen, the name under it.
class WallpaperPhone extends StatelessWidget {
  const WallpaperPhone({
    super.key,
    required this.label,
    required this.width,
    required this.aspect,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String label;
  final double width;
  final double aspect;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const room = LaunchScreenPicker.room;
    const radius = BorderRadius.all(Radius.circular(LaunchScreenPicker.radius));
    final quick = AppMotion.of(context, AppMotion.quick);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: SizedBox(
          width: width + 2 * room,
          child: Column(
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: selected ? 1 : 0),
                duration: quick,
                curve: AppMotion.std,
                builder: (context, t, child) => CustomPaint(
                  foregroundPainter: _Ring(scheme.primary.withValues(alpha: t)),
                  child: child,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(room),
                  child: SizedBox(
                    width: width,
                    height: width / aspect,
                    child: ClipRSuperellipse(
                      borderRadius: radius,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          child,
                          DecoratedBox(
                            decoration: ShapeDecoration(
                              shape: RoundedSuperellipseBorder(
                                borderRadius: radius,
                                side: BorderSide(color: scheme.outlineVariant, width: 0.5),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: PickerGrid.labelGap - room),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: AnimatedDefaultTextStyle(
                  duration: quick,
                  style: PickerGrid.labelStyle(context, selected: selected),
                  child: Text(label, textAlign: TextAlign.center, maxLines: 1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Ring extends CustomPainter {
  _Ring(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    const w = LaunchScreenPicker.ring;
    final rect = (Offset.zero & size).deflate(w / 2);
    canvas.drawRSuperellipse(
      RSuperellipse.fromRectAndRadius(
        rect,
        const Radius.circular(LaunchScreenPicker.radius + LaunchScreenPicker.room - w / 2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_Ring old) => old.color != color;
}

/// The whole screen drawn at its real size, then shrunk into the phone.
class _Screen extends StatelessWidget {
  const _Screen({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return FittedBox(
      fit: BoxFit.cover,
      child: SizedBox(width: screen.width, height: screen.height, child: child),
    );
  }
}

/// No picture yet: a quiet phone with the add mark. A picture: its small bake under the sketch,
/// the guarded colours on it, as the chat will show it.
class _CustomMini extends StatelessWidget {
  const _CustomMini({required this.custom, required this.thumb, required this.broken, required this.busy});

  final CustomWallpaper? custom;
  final ui.Image? thumb;
  final bool broken;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final custom = this.custom;
    final thumb = this.thumb;
    final Widget body;
    if (custom == null) {
      body = ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: Center(
          child: busy ? const SizedBox.shrink() : Icon(AppIcons.addImage, size: 24, color: scheme.onSurfaceVariant),
        ),
      );
    } else if (broken) {
      body = ColoredBox(
        color: scheme.surfaceContainerHigh,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              context.l10n.wallpaperBroken,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: DshColors.of(context).textTertiary),
            ),
          ),
        ),
      );
    } else if (thumb == null) {
      // Baking: the picture's own edge colour meanwhile.
      body = ColoredBox(color: custom.edge == null ? scheme.surfaceContainerHigh : Color(custom.edge!));
    } else {
      final theme = Theme.of(context);
      body = _Screen(
        child: Theme(
          data: WallpaperLook.of(context).guardTheme(theme),
          child: Stack(
            fit: StackFit.expand,
            children: [
              RawImage(image: thumb, fit: BoxFit.cover, filterQuality: FilterQuality.medium),
              const _ChatSketch(),
            ],
          ),
        ),
      );
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        if (busy)
          ColoredBox(
            color: scheme.surface.withValues(alpha: 0.6),
            child: const Center(
              child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
      ],
    );
  }
}

/// A sketch of the chat at the screen's real size: the header (menu key, title capsule, model
/// key), the person's bubble, three lines of reply, and the composer with its send key.
class _ChatSketch extends StatelessWidget {
  const _ChatSketch();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CustomPaint(
      size: Size.infinite,
      painter: _SketchPainter(
        surfaces: DshSurfaces.of(context),
        ink: theme.colorScheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.5 : 0.42),
        faint: DshColors.of(context).textTertiary.withValues(alpha: 0.5),
        accent: theme.colorScheme.primary,
        padding: MediaQuery.viewPaddingOf(context),
      ),
    );
  }
}

class _SketchPainter extends CustomPainter {
  _SketchPainter({
    required this.surfaces,
    required this.ink,
    required this.faint,
    required this.accent,
    required this.padding,
  });

  final DshSurfaces surfaces;
  final Color ink;
  final Color faint;
  final Color accent;
  final EdgeInsets padding;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final glass = Paint()..color = surfaces.chrome.fill;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = surfaces.chrome.hairline;
    RRect pill(Rect r) => RRect.fromRectAndRadius(r, Radius.circular(r.shortestSide / 2));
    void chrome(RRect r) => canvas
      ..drawRRect(r, glass)
      ..drawRRect(r, edge);
    void line(double x, double y, double width, double height, Color color) =>
        canvas.drawRRect(pill(Rect.fromLTWH(x, y, width, height)), Paint()..color = color);

    // Header: ≡, the title capsule, the model key.
    final top = padding.top + 6;
    chrome(pill(Rect.fromLTWH(12, top, 44, 44)));
    chrome(pill(Rect.fromLTWH(64, top, w * 0.46, 44)));
    line(80, top + 12, w * 0.28, 9, ink);
    line(80, top + 26, w * 0.14, 7, faint);
    chrome(pill(Rect.fromLTWH(w - 12 - 44, top, 44, 44)));

    // The person's bubble, then the reply.
    final bubbleTop = top + 44 + 60;
    final bubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(w - 16 - w * 0.6, bubbleTop, w * 0.6, 64),
      const Radius.circular(22),
    );
    canvas.drawRRect(bubble, Paint()..color = surfaces.userBubble);
    line(bubble.left + 18, bubbleTop + 18, w * 0.42, 10, ink);
    line(bubble.left + 18, bubbleTop + 36, w * 0.26, 10, ink);
    final reply = bubbleTop + 64 + 40;
    for (final (i, f) in const [0.82, 0.88, 0.76, 0.52].indexed) {
      line(16, reply + i * 26, (w - 32) * f, 11, ink);
    }
    line(16, reply + 4 * 26 + 8, w * 0.18, 8, faint);

    // Composer and its send key: the one accent on the screen.
    final composer = pill(Rect.fromLTWH(12, h - padding.bottom - 12 - 52, w - 24, 52));
    chrome(composer);
    line(composer.left + 22, composer.center.dy - 5, w * 0.36, 10, faint);
    canvas.drawCircle(Offset(composer.right - 26, composer.center.dy), 18, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_SketchPainter old) =>
      old.surfaces != surfaces ||
      old.ink != ink ||
      old.faint != faint ||
      old.accent != accent ||
      old.padding != padding;
}
