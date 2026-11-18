// 设置 › 主题: light / dark, the palette (six presets,
// a custom hue, the wallpaper), the feature tile style, the launcher icon (and a
// picture shortcut) and the launch screen (those two on Android only).
//
// Every picker on the page shares one grid: previews start 16 from the card's
// edges and sit 12 apart, labels 8 under them (TileStylePicker, AppIconPicker).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/android_features.dart';
import '../../../state/appearance_state.dart';
import '../../../state/settings_state.dart';
import '../../../ui_config/ui_config.dart';
import '../../common/expand_reveal.dart';
import '../../common/pressable.dart';
import '../../shell/page_frame.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../settings_widgets.dart';
import 'app_icon_picker.dart';
import 'icon_shortcut_sheet.dart';
import 'launch_screen_section.dart';
import 'tile_style_picker.dart';
import 'wallpaper_section.dart';

/// 设置首页「外观」组的第一行:当前配色的色点 + 名字 · 明暗,点开 [AppearancePage]。
class AppearanceEntryTile extends ConsumerWidget {
  const AppearanceEntryTile({super.key, this.tint = 0});

  /// The hub group's hue.
  final int tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final accent = ref.watch(accentProvider);
    final seed = accent.seedFor(Theme.of(context).brightness);
    final mode = switch (ref.watch(uiThemeModeProvider.select((s) => s.value))) {
      ThemeMode.light => l10n.commonLight,
      ThemeMode.dark => l10n.commonDark,
      ThemeMode.system => l10n.commonFollowSystem,
    };
    return SettingsTile(
      icon: AppIcons.theme,
      tint: tint,
      spot: SettingsIndex.entry(SettingsPageId.appearance),
      value: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AccentDot(color: seed, size: 10),
          const SizedBox(width: 6),
          Text('${accent.label} · $mode'),
        ],
      ),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AppearancePage())),
    );
  }
}

/// 设置 › 主题:明暗、配色(预设 / 自定义 / 跟随壁纸)、功能图标、桌面图标。宠物在
/// 设置首页自成一行。
///
/// 选什么都即时生效:整个 App 的主题随之交叉淡变(`AppMotion.standard`),
/// 这一页本身就是预览。
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final appearance = ref.watch(appearanceProvider);
    final wallpaper = ref.watch(wallpaperAccentProvider).value;
    // A picture as a launcher shortcut: Android and HarmonyOS, not iOS.
    final pictureShortcut = ref.watch(operatingSystemProvider) != 'ios';
    return AppPage.list(
      title: l10n.pluginsTheme,
      children: [
        SettingsSection(
          title: l10n.hubThemeLightDark,
          children: [SpotAnchor(spot: Spots.darkMode, child: const ThemeModePicker())],
        ),
        SettingsSection(
          title: l10n.pluginsColors,
          children: [
            SpotAnchor(spot: Spots.accent, child: const PalettePicker()),
            ExpandReveal(open: appearance.source == AccentSource.custom, child: const CustomAccentPanel()),
            if (wallpaper != null) _WallpaperRow(wallpaper: wallpaper, on: appearance.source == AccentSource.wallpaper),
          ],
        ),
        SettingsSection(
          title: l10n.pluginsFeatureIcons,
          children: [SpotAnchor(spot: Spots.tileStyle, child: const TileStylePicker())],
        ),
        SettingsSection(
          title: l10n.pluginsAppIcon,
          children: [
            SpotAnchor(spot: Spots.appIcon, child: const AppIconPicker()),
            if (pictureShortcut) const IconShortcutTile(),
          ],
        ),
        SettingsSection(
          title: l10n.launchScreenTitle,
          footer: Text(l10n.launchFooter),
          children: [SpotAnchor(spot: Spots.launchScreen, child: const LaunchScreenSection())],
        ),
        SettingsSection(
          title: l10n.wallpaperTitle,
          footer: Text(l10n.wallpaperFooter),
          children: [SpotAnchor(spot: Spots.wallpaper, child: const WallpaperSection())],
        ),
      ],
    );
  }
}

/// The grid every picker on this page shares, with [TileStylePicker] and
/// [AppIconPicker]: content 16 from the card's edges, columns 12 apart, the
/// name 8 under its preview (or under its ring).
abstract final class PickerGrid {
  static const inset = 16.0;
  static const gap = 12.0;
  static const labelGap = 8.0;

  /// The name under a choice: the accent and heavier when chosen.
  static TextStyle labelStyle(BuildContext context, {required bool selected}) {
    final theme = Theme.of(context);
    return theme.textTheme.labelMedium!.copyWith(
      color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );
  }
}

// ── 外观模式 ─────────────────────────────────────────────────────────────

/// 三张小样:浅色、深色、跟随系统(左浅右深)。小样用当前配色画,换配色时
/// 跟着淡变;选中的那张外面一圈主色环。
class ThemeModePicker extends ConsumerWidget {
  const ThemeModePicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final modes = [
      (ThemeMode.light, l10n.commonLight),
      (ThemeMode.dark, l10n.commonDark),
      (ThemeMode.system, l10n.commonFollowSystem),
    ];
    final mode = ref.watch(uiThemeModeProvider);
    final (light, dark) = _themesFor(ref.watch(accentProvider));
    // The ring sits outside each preview, in [_ModeTile.room]: the padding
    // and gap leave room for it, so previews land 16 from the card and 12
    // apart, column for column with the tile styles below.
    const room = _ModeTile.room;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PickerGrid.inset - room,
        PickerGrid.inset - room,
        PickerGrid.inset - room,
        PickerGrid.inset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mode.fromUiJson)
            const Padding(
              padding: EdgeInsets.only(left: room, right: room, bottom: 8),
              child: Align(alignment: Alignment.centerLeft, child: FromUiJsonBadge(UiSettingKey.themeMode)),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (i, (m, label)) in modes.indexed) ...[
                if (i > 0) const SizedBox(width: PickerGrid.gap - 2 * room),
                Expanded(
                  child: _ModeTile(
                    label: label,
                    selected: mode.value == m,
                    enabled: !mode.fromUiJson,
                    light: m == ThemeMode.dark ? null : light,
                    dark: m == ThemeMode.light ? null : dark,
                    onTap: () => unawaited(
                      ThemeRevealHost.run(context, () => ref.read(settingsProvider.notifier).setThemeMode(m)),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Light and dark themes of [accent], built once per palette.
(ThemeData, ThemeData) _themesFor(AppAccent accent) {
  final hit = _themeCache[accent];
  if (hit != null) return hit;
  if (_themeCache.length > 4) _themeCache.clear();
  return _themeCache[accent] = (buildLightTheme(accent: accent), buildDarkTheme(accent: accent));
}

final _themeCache = <AppAccent, (ThemeData, ThemeData)>{};

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.enabled,
    this.light,
    this.dark,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool enabled;

  /// Null: that half isn't drawn ([dark] alone fills the tile).
  final ThemeData? light;
  final ThemeData? dark;

  /// Ring stroke and the gap between the ring and the preview.
  static const ring = 2.0;
  static const gap = 3.0;

  /// Room around the preview for the ring.
  static const room = ring + gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quick = AppMotion.of(context, AppMotion.quick);
    final fade = AppMotion.of(context, AppMotion.standard);
    Widget preview(ThemeData? end) => end == null
        ? const SizedBox.shrink()
        : TweenAnimationBuilder<ThemeData>(
            tween: ThemeDataTween(end: end),
            duration: fade,
            curve: AppMotion.std,
            builder: (context, t, _) => CustomPaint(painter: _PhonePainter(t), size: Size.infinite),
          );
    final content = Column(
      children: [
        AspectRatio(
          aspectRatio: 0.8,
          child: CustomPaint(
            foregroundPainter: _RingPainter(
              color: scheme.primary.withValues(alpha: selected ? 1 : 0),
              width: ring,
              radius: AppShape.md + ring + gap,
            ),
            child: Padding(
              padding: const EdgeInsets.all(room),
              child: ClipRSuperellipse(
                key: ValueKey('theme-mode-$label'),
                borderRadius: AppShape.radiusMd,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (light != null) preview(light),
                    if (dark != null)
                      ClipRect(clipper: light == null ? null : const _RightHalf(), child: preview(dark)),
                    // Edge of the preview: a hairline, like a card.
                    DecoratedBox(
                      decoration: ShapeDecoration(
                        shape: RoundedSuperellipseBorder(
                          borderRadius: AppShape.radiusMd,
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
        // A narrow column at a large text size: the name shrinks to fit
        // rather than losing its end.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: AnimatedDefaultTextStyle(
            duration: quick,
            style: PickerGrid.labelStyle(context, selected: selected),
            child: Text(label, textAlign: TextAlign.center, maxLines: 1),
          ),
        ),
      ],
    );
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: enabled ? onTap : null,
      child: Pressable(
        onTap: onTap,
        enabled: enabled,
        child: enabled ? content : Opacity(opacity: 0.5, child: content),
      ),
    );
  }
}

class _RightHalf extends CustomClipper<Rect> {
  const _RightHalf();

  @override
  Rect getClip(Size size) => Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height);

  @override
  bool shouldReclip(_RightHalf oldClipper) => false;
}

/// A ring just outside a rounded rect (the selected mode).
class _RingPainter extends CustomPainter {
  _RingPainter({required this.color, required this.width, required this.radius});

  final Color color;
  final double width;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    if (color.a == 0) return;
    final rect = (Offset.zero & size).deflate(width / 2);
    canvas.drawRSuperellipse(
      RSuperellipse.fromRectAndRadius(rect, Radius.circular(radius - width / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.color != color || old.width != width || old.radius != radius;
}

/// A tiny chat screen in [theme]: the page with its two glows, a header
/// capsule, two reply lines, the user's bubble and the composer with its
/// send key.
class _PhonePainter extends CustomPainter {
  _PhonePainter(this.theme);

  final ThemeData theme;

  @override
  void paint(Canvas canvas, Size size) {
    final s = theme.extension<DshSurfaces>()!;
    final scheme = theme.colorScheme;
    final w = size.width;
    final h = size.height;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [s.backdropTop, s.backdropBottom],
        ).createShader(rect),
    );
    void glow(Offset c, double r, Color color) {
      final b = Rect.fromCircle(center: c, radius: r);
      canvas.drawRect(b, Paint()..shader = RadialGradient(colors: [color, color.withValues(alpha: 0)]).createShader(b));
    }

    glow(Offset(w * 0.92, 0), h * 0.7, s.glowPrimary);
    glow(Offset(0, h), h * 0.62, s.glowSecondary);

    final glass = Paint()..color = s.chrome.fallbackFill;
    final edge = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5
      ..color = s.chrome.hairline;
    final unit = w / 100;

    // Header capsule.
    final header = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(w / 2, 12 * unit), width: 44 * unit, height: 9 * unit),
      const Radius.circular(99),
    );
    canvas
      ..drawRRect(header, glass)
      ..drawRRect(header, edge);

    final ink = Paint()..color = scheme.onSurface.withValues(alpha: theme.brightness == Brightness.dark ? 0.26 : 0.2);
    RRect bar(double x, double y, double width, double height) =>
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, width, height), Radius.circular(height / 2));

    // The user's bubble, then the reply under it.
    final bubble = RRect.fromRectAndRadius(
      Rect.fromLTWH(w - 12 * unit - 46 * unit, 30 * unit, 46 * unit, 15 * unit),
      Radius.circular(6 * unit),
    );
    canvas.drawRRect(bubble, Paint()..color = s.userBubble);
    canvas.drawRRect(bar(w - 12 * unit - 38 * unit, 35.5 * unit, 30 * unit, 4 * unit), ink);
    canvas.drawRRect(bar(12 * unit, 54 * unit, 66 * unit, 4.5 * unit), ink);
    canvas.drawRRect(bar(12 * unit, 63 * unit, 76 * unit, 4.5 * unit), ink);
    canvas.drawRRect(bar(12 * unit, 72 * unit, 48 * unit, 4.5 * unit), ink);

    // Composer with the send key: the one accent on the screen.
    final composerH = 15 * unit;
    final composer = RRect.fromRectAndRadius(
      Rect.fromLTWH(8 * unit, h - 8 * unit - composerH, w - 16 * unit, composerH),
      const Radius.circular(99),
    );
    canvas
      ..drawRRect(composer, glass)
      ..drawRRect(composer, edge);
    final send = composer.outerRect;
    canvas.drawCircle(
      Offset(send.right - send.height / 2, send.center.dy),
      send.height / 2 - 2.5 * unit,
      Paint()..color = scheme.primary,
    );
  }

  @override
  bool shouldRepaint(_PhonePainter old) => old.theme != theme;
}

// ── 配色 ─────────────────────────────────────────────────────────────────

/// 六套预设 + 自定义(色轮),设置页窄时折行。色点画的是守卫之后、当前明暗下的
/// 主色;选中的外面一圈同色环,下面是名字。[custom] 为 false 时只有六套
/// 预设(首次启动的外观页)。
class PalettePicker extends ConsumerWidget {
  const PalettePicker({super.key, this.custom = true});

  /// The seventh slot, a hue wheel for a colour of one's own.
  final bool custom;

  /// How tall the row is at this text size. It lays out with a
  /// [LayoutBuilder], which a column measuring intrinsic heights (the
  /// first-run pages) cannot ask: such a column gives it this height.
  static double heightFor(BuildContext context) {
    final label = PickerGrid.labelStyle(context, selected: true);
    final line = MediaQuery.textScalerOf(context).scale(label.fontSize!) * (label.height ?? 1.35);
    return 2 * PickerGrid.inset + disc + 2 * (ringGap + ringWidth) + PickerGrid.labelGap + line;
  }

  /// Swatch disc, its ring, and the widest a slot (disc + name) gets.
  static const disc = 30.0;
  static const ringGap = 2.5;
  static const ringWidth = 2.0;
  static const slot = 52.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final appearance = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    final brightness = Theme.of(context).brightness;
    final customAccent = AppAccent.derive(Color(appearance.customColor));
    bool chosen(AppAccent p) => appearance.source == AccentSource.preset && appearance.presetId == p.id;
    final items = [
      for (final p in AppAccent.presets)
        _Swatch(
          label: p.label,
          selected: chosen(p),
          color: p.seedFor(brightness),
          onTap: () => unawaited(notifier.selectPreset(p.id)),
        ),
      if (custom)
        _Swatch(
          label: l10n.pluginsCustomColor,
          selected: appearance.source == AccentSource.custom,
          color: customAccent.seedFor(brightness),
          wheel: true,
          onTap: () => unawaited(notifier.selectCustom()),
        ),
    ];
    // Rings 16 from the card's edges, centres evenly spaced; each slot is as
    // wide as the spacing allows (up to [slot]) so the names have room.
    return LayoutBuilder(
      builder: (context, constraints) {
        const ringSide = disc + 2 * (ringGap + ringWidth);
        final step = (constraints.maxWidth - 2 * PickerGrid.inset - ringSide) / (items.length - 1);
        final width = math.max(ringSide, math.min(slot, step));
        final side = PickerGrid.inset - (width - ringSide) / 2;
        final slots = [for (final item in items) SizedBox(width: width, child: item)];
        return Padding(
          padding: EdgeInsets.fromLTRB(side, PickerGrid.inset, side, PickerGrid.inset),
          child: custom
              ? Wrap(alignment: WrapAlignment.spaceBetween, runSpacing: PickerGrid.gap, children: slots)
              // First-run pages measure this six-palette row with heightFor.
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: slots,
                ),
        );
      },
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
    this.wheel = false,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  /// The custom slot: a hue wheel around the chosen colour.
  final bool wheel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final quick = AppMotion.of(context, AppMotion.quick);
    const size = PalettePicker.disc + 2 * (PalettePicker.ringGap + PalettePicker.ringWidth);
    return Semantics(
      button: true,
      selected: selected,
      label: l10n.pluginsColorLabel(label),
      excludeSemantics: true,
      onTap: onTap,
      child: Pressable(
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: size,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: selected ? 1 : 0),
                duration: quick,
                curve: AppMotion.std,
                builder: (context, t, _) => CustomPaint(
                  painter: _SwatchPainter(
                    color: color,
                    ring: t,
                    wheel: wheel ? _wheelColors(theme.brightness) : null,
                    hole: _cardColor(context),
                    edge: scheme.onSurface.withValues(alpha: 0.08),
                  ),
                ),
              ),
            ),
            const SizedBox(height: PickerGrid.labelGap),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: AnimatedDefaultTextStyle(
                duration: quick,
                style: PickerGrid.labelStyle(context, selected: selected),
                child: Text(label, maxLines: 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a card looks like on the page (the glass over the backdrop).
Color _cardColor(BuildContext context) {
  final s = DshSurfaces.of(context);
  return Color.alphaBlend(s.card.fill, Color.lerp(s.backdropTop, s.backdropBottom, 0.5)!);
}

/// The hue wheel and the hue track: guarded colours every 15°, per brightness.
List<Color> _wheelColors(Brightness brightness) => _wheels[brightness] ??= [
  for (var h = 0; h <= 360; h += 15) AppAccent.guardedSeed(AppAccent.hueColor(h % 360.0), brightness),
];

final _wheels = <Brightness, List<Color>>{};

class _SwatchPainter extends CustomPainter {
  _SwatchPainter({required this.color, required this.ring, required this.hole, required this.edge, this.wheel});

  final Color color;

  /// 0–1: how far the selection ring has drawn in.
  final double ring;
  final Color hole;
  final Color edge;
  final List<Color>? wheel;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    const r = PalettePicker.disc / 2;
    if (ring > 0) {
      canvas.drawCircle(
        c,
        r + PalettePicker.ringGap + PalettePicker.ringWidth / 2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = PalettePicker.ringWidth
          ..color = color.withValues(alpha: ring),
      );
    }
    final wheel = this.wheel;
    if (wheel == null) {
      canvas.drawCircle(c, r, Paint()..color = color);
    } else {
      final bounds = Rect.fromCircle(center: c, radius: r);
      canvas.drawCircle(c, r, Paint()..shader = SweepGradient(colors: wheel).createShader(bounds));
      canvas.drawCircle(c, r * 0.62, Paint()..color = hole);
      canvas.drawCircle(c, r * 0.44, Paint()..color = color);
    }
    canvas.drawCircle(
      c,
      r - 0.25,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = edge,
    );
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.color != color || old.ring != ring || old.hole != hole || old.edge != edge || old.wheel != wheel;
}

/// A small filled circle (the hub row's value, the wallpaper row).
class AccentDot extends StatelessWidget {
  const AccentDot({super.key, required this.color, this.size = 12});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: DecoratedBox(
      decoration: ShapeDecoration(
        color: color,
        shape: CircleBorder(
          side: BorderSide(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08), width: 0.5),
        ),
      ),
    ),
  );
}

// ── 自定义 ───────────────────────────────────────────────────────────────

/// 自定义:色相条 + 几个推荐色。色相条和色块画的都是守卫后的颜色 —— 看到
/// 的就是用上的。
class CustomAccentPanel extends ConsumerWidget {
  const CustomAccentPanel({super.key});

  /// Picks beyond the presets: (hue, chroma, name), at the presets' lightness.
  static List<(double, double, String)> get suggestions => _suggestions(appL10n);

  static List<(double, double, String)> _suggestions(L10n l10n) => [
    (22.0, 0.10, l10n.pluginsCoral),
    (355.0, 0.10, l10n.pluginsRouge),
    (52.0, 0.075, l10n.pluginsOchre),
    (135.0, 0.075, l10n.pluginsMoss),
    (215.0, 0.09, l10n.pluginsLake),
    (282.0, 0.12, l10n.pluginsIndigo),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final choices = _suggestions(l10n);
    final appearance = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    final brightness = Theme.of(context).brightness;
    final pick = Color(appearance.customColor);
    return Padding(
      padding: const EdgeInsets.fromLTRB(PickerGrid.inset, 0, PickerGrid.inset, PickerGrid.inset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HueSlider(
            hue: Oklch.fromColor(pick).h,
            brightness: brightness,
            onChanged: (h) => unawaited(notifier.selectCustom(AppAccent.hueColor(h).toARGB32())),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final (hue, chroma, name) in choices)
                Builder(
                  builder: (context) {
                    final color = AppAccent.hueColor(hue, chroma: chroma);
                    final selected = appearance.customColor == color.toARGB32();
                    return Semantics(
                      button: true,
                      selected: selected,
                      label: name,
                      excludeSemantics: true,
                      child: Pressable(
                        onTap: () => unawaited(notifier.selectCustom(color.toARGB32())),
                        child: SizedBox.square(
                          dimension: 36,
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: selected ? 1 : 0),
                            duration: AppMotion.of(context, AppMotion.quick),
                            builder: (context, t, _) => CustomPaint(
                              painter: _ChipPainter(
                                color: AppAccent.guardedSeed(color, brightness),
                                ring: t,
                                edge: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChipPainter extends CustomPainter {
  _ChipPainter({required this.color, required this.ring, required this.edge});

  final Color color;
  final double ring;
  final Color edge;

  static const radius = 11.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    if (ring > 0) {
      canvas.drawCircle(
        c,
        radius + 2.5 + 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color.withValues(alpha: ring),
      );
    }
    canvas.drawCircle(c, radius, Paint()..color = color);
    canvas.drawCircle(
      c,
      radius - 0.25,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = edge,
    );
  }

  @override
  bool shouldRepaint(_ChipPainter old) => old.color != color || old.ring != ring || old.edge != edge;
}

/// 色相条:一条守卫后的色相渐变,一颗圆钮(里面是当前色)。拖动时圆钮
/// 跟手,主题每 ~100ms 跟一次,松手落定。
class HueSlider extends StatefulWidget {
  const HueSlider({super.key, required this.hue, required this.brightness, required this.onChanged});

  final double hue;
  final Brightness brightness;
  final ValueChanged<double> onChanged;

  static const height = 36.0;
  static const track = 12.0;
  static const knob = 26.0;

  @override
  State<HueSlider> createState() => _HueSliderState();
}

class _HueSliderState extends State<HueSlider> {
  double? _dragging;
  double _lastDx = 0;
  DateTime _sent = DateTime(0);

  double get _hue => _dragging ?? widget.hue;

  double _hueAt(double dx, double width) {
    const pad = HueSlider.knob / 2;
    return ((dx - pad) / (width - 2 * pad)).clamp(0.0, 1.0) * 360;
  }

  void _drag(double dx, double width, {bool end = false}) {
    final hue = _hueAt(dx, width);
    setState(() => _dragging = end ? null : hue);
    final now = DateTime.now();
    if (end || now.difference(_sent) > const Duration(milliseconds: 100)) {
      _sent = now;
      widget.onChanged(hue);
    }
  }

  void _step(double by) => widget.onChanged((widget.hue + by) % 360);

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final hue = _hue;
    final colors = _wheelColors(widget.brightness);
    final current = AppAccent.guardedSeed(AppAccent.hueColor(hue % 360), widget.brightness);
    return Semantics(
      slider: true,
      label: l10n.pluginsHue,
      value: '${hue.round()}°',
      increasedValue: '${((hue + 15) % 360).round()}°',
      decreasedValue: '${((hue - 15) % 360).round()}°',
      onIncrease: () => _step(15),
      onDecrease: () => _step(-15),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _drag(d.localPosition.dx, width, end: true),
            onHorizontalDragStart: (d) => _drag(_lastDx = d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) => _drag(_lastDx = d.localPosition.dx, width),
            onHorizontalDragEnd: (_) => _drag(_lastDx, width, end: true),
            child: SizedBox(
              height: HueSlider.height,
              width: width,
              child: CustomPaint(
                painter: _HuePainter(
                  colors: colors,
                  hue: hue,
                  current: current,
                  knob: Theme.of(context).brightness == Brightness.dark
                      ? Theme.of(context).colorScheme.onSurface
                      : Colors.white,
                  shadow: Theme.of(context).colorScheme.shadow,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HuePainter extends CustomPainter {
  _HuePainter({
    required this.colors,
    required this.hue,
    required this.current,
    required this.knob,
    required this.shadow,
  });

  final List<Color> colors;
  final double hue;
  final Color current;
  final Color knob;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = HueSlider.knob / 2;
    final track = Rect.fromLTWH(
      pad - HueSlider.track / 2,
      (size.height - HueSlider.track) / 2,
      size.width - 2 * pad + HueSlider.track,
      HueSlider.track,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(track, const Radius.circular(99)),
      Paint()..shader = LinearGradient(colors: colors).createShader(track),
    );
    final x = pad + (hue / 360).clamp(0.0, 1.0) * (size.width - 2 * pad);
    final c = Offset(x, size.height / 2);
    canvas.drawCircle(
      c.translate(0, 1),
      HueSlider.knob / 2,
      Paint()
        ..color = shadow.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(c, HueSlider.knob / 2, Paint()..color = knob);
    canvas.drawCircle(c, HueSlider.knob / 2 - 4, Paint()..color = current);
  }

  @override
  bool shouldRepaint(_HuePainter old) =>
      old.hue != hue || old.current != current || old.knob != knob || old.colors != colors || old.shadow != shadow;
}

// ── 跟随壁纸 ─────────────────────────────────────────────────────────────

class _WallpaperRow extends ConsumerWidget {
  const _WallpaperRow({required this.wallpaper, required this.on});

  final Color wallpaper;
  final bool on;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final notifier = ref.read(appearanceProvider.notifier);
    final seed = AppAccent.derive(
      wallpaper,
      id: AppAccent.wallpaperId,
      label: l10n.pluginsWallpaper,
    ).seedFor(Theme.of(context).brightness);
    void set(bool v) => unawaited(v ? notifier.selectWallpaper() : notifier.leaveWallpaper());
    return MergeSemantics(
      child: SettingsTile(
        title: l10n.pluginsFollowWallpaper,
        value: AccentDot(color: seed),
        onTap: () => set(!on),
        trailing: Switch.adaptive(value: on, onChanged: set),
      ),
    );
  }
}
