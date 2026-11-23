// The Theme Studio's groups. Each shows the handful of choices most themes need and folds the rest of its part
// of the pack behind 「更多选项」, so every field can be reached without the sheet opening as a wall of knobs.

import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../common/app_sheet.dart';
import '../../common/capsule_chip.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'hue_slider.dart';
import 'theme_studio_colors.dart';
import 'theme_studio_controller.dart';
import 'theme_studio_controls.dart';

String _t(String zh, String en) => studioText(zh, en);

String? _blankToNull(String text) => text.trim().isEmpty ? null : text;

abstract class _Group extends StatelessWidget {
  const _Group({super.key, required this.c, required this.open, required this.onToggle});

  final ThemeStudioController c;
  final bool open;
  final VoidCallback onToggle;
}

class StudioInfoGroup extends _Group {
  const StudioInfoGroup({super.key, required super.c, required super.open, required super.onToggle});

  static List<String> _readTags(String text) => [
    for (final tag in text.split(RegExp('[,，、]')))
      if (tag.trim().isNotEmpty) tag.trim(),
  ];

  @override
  Widget build(BuildContext context) {
    final p = c.pack;
    return StudioGroup(
      id: 'info',
      title: _t('基本信息', 'Basics'),
      open: open,
      onToggle: onToggle,
      basics: [
        StudioField.text(
          key: const ValueKey('theme-studio-name'),
          value: p.name,
          onChanged: c.setName,
          label: _t('主题名称', 'Theme name'),
          hint: _t('例如：松烟纸墨', 'e.g. Warm Paper'),
        ),
        StudioField.text(
          key: const ValueKey('theme-studio-id'),
          value: p.id,
          onChanged: (text) => c.update(c.pack.copyWith(id: text)),
          label: _t('主题 ID（小写字母、数字、连字符）', 'Theme ID (lower-case letters, digits, hyphens)'),
          hint: 'warm-paper',
        ),
        StudioField.text(
          key: const ValueKey('theme-studio-description'),
          value: p.description,
          onChanged: (text) => c.update(c.pack.copyWith(description: text)),
          label: _t('一句话简介（可选）', 'Summary (optional)'),
        ),
      ],
      more: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: StudioField.text(
                value: p.titleZh ?? '',
                onChanged: (text) => c.setMeta(titleZh: () => _blankToNull(text)),
                label: _t('中文名称', 'Chinese name'),
                hint: _t('不填就用主题名称', 'Defaults to the theme name'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StudioField.text(
                value: p.titleEn ?? '',
                onChanged: (text) => c.setMeta(titleEn: () => _blankToNull(text)),
                label: _t('英文名称', 'English name'),
                hint: _t('不填就用主题名称', 'Defaults to the theme name'),
              ),
            ),
          ],
        ),
        StudioField<List<String>>(
          value: p.tags,
          read: _readTags,
          show: (tags) => tags.join(_t('、', ', ')),
          same: listEquals,
          onChanged: (tags) => c.update(c.pack.copyWith(tags: tags)),
          label: _t('标签（用逗号隔开，最多 8 个）', 'Tags (comma separated, up to 8)'),
        ),
        StudioField.text(
          value: p.author ?? '',
          onChanged: (text) => c.setMeta(author: () => _blankToNull(text)),
          label: _t('作者', 'Author'),
        ),
        StudioField.text(
          value: p.license ?? '',
          onChanged: (text) => c.setMeta(license: () => _blankToNull(text)),
          label: _t('许可协议', 'License'),
          hint: 'CC-BY-4.0',
        ),
        StudioField.text(
          value: p.source ?? '',
          onChanged: (text) => c.setMeta(source: () => _blankToNull(text)),
          label: _t('来源链接', 'Source link'),
          hint: 'https://',
        ),
      ],
    );
  }
}

class StudioColorGroup extends _Group {
  const StudioColorGroup({
    super.key,
    required super.c,
    required super.open,
    required super.onToggle,
    required this.previewDark,
  });

  final bool previewDark;

  static const _seeds = <(int, String, String, double)>[
    (0xFFA14732, '赤陶', 'Terracotta', 74),
    (0xFF2B6A58, '青瓷', 'Celadon', 162),
    (0xFF4B67B4, '雾蓝', 'Mist Blue', 260),
    (0xFF0D736A, '矩阵青', 'Matrix Teal', 192),
    (0xFF9A5B1F, '琥珀', 'Amber', 52),
    (0xFF5F7A55, '苔绿', 'Moss', 140),
    (0xFF726291, '暮紫', 'Dusk', 295),
    (0xFFB85A7C, '落樱', 'Sakura', 342),
    (0xFF4E525B, '石墨', 'Graphite', 262),
  ];

  /// What [token] looks like in the draft now, set or not.
  Color _now(String token, {bool dark = false}) =>
      studioTokenColor(token, studioThemeOf(c.pack, dark: dark), c.pack) ?? Color(c.pack.palette.seed);

  Future<void> _pick(BuildContext context, Color from, ValueChanged<int> apply, {bool opacity = true}) async {
    final picked = await showStudioColorPicker(context, initial: from, opacity: opacity);
    if (picked != null) apply(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = c.pack.palette;
    final changed = ThemeColorOverrides.tokenKeys
        .where((key) => palette.light[key] != null || palette.dark[key] != null)
        .length;
    final hue = palette.tintHue;
    return StudioGroup(
      id: 'colors',
      title: _t('颜色', 'Colors'),
      open: open,
      onToggle: onToggle,
      basics: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (rgb, zh, en, tint) in _seeds)
              CapsuleChoiceChip(
                label: _t(zh, en),
                selected: palette.seed == rgb,
                onSelected: () => c.setSeed(rgb, tintHue: tint),
              ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: StudioHexField(
                key: const ValueKey('theme-studio-seed-hex'),
                value: palette.seed,
                // The accent cannot be empty: clearing the field leaves it as it was.
                onChanged: (argb) {
                  if (argb != null) c.setSeed(argb);
                },
                label: _t('自定义主色', 'Custom accent'),
                onPick: () => unawaited(_pick(context, Color(palette.seed), c.setSeed, opacity: false)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StudioHexField(
                key: const ValueKey('theme-studio-bubble-hex'),
                value: palette.light.userBubble,
                onChanged: c.setUserBubble,
                label: _t('我的气泡（可选）', 'My bubble (optional)'),
                hint: '#ECE8E2',
                onPick: () => unawaited(_pick(context, _now('userBubble'), c.setUserBubble)),
              ),
            ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: StudioHexField(
                key: const ValueKey('theme-studio-light-bg-hex'),
                value: palette.light.backdropTop,
                onChanged: (argb) => c.setBackdropColor(argb, dark: false),
                label: _t('浅色背景（可选）', 'Light page (optional)'),
                hint: '#F7F4EC',
                onPick: () =>
                    unawaited(_pick(context, _now('backdropTop'), (argb) => c.setBackdropColor(argb, dark: false))),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: StudioHexField(
                key: const ValueKey('theme-studio-dark-bg-hex'),
                value: palette.dark.backdropTop,
                onChanged: (argb) => c.setBackdropColor(argb, dark: true),
                label: _t('深色背景（可选）', 'Dark page (optional)'),
                hint: '#181614',
                onPick: () => unawaited(
                  _pick(context, _now('backdropTop', dark: true), (argb) => c.setBackdropColor(argb, dark: true)),
                ),
              ),
            ),
          ],
        ),
        StudioChoice<double>(
          label: _t('背景光晕', 'Backdrop glow'),
          items: [(0.0, _t('没有', 'None')), (0.45, _t('柔和', 'Soft')), (1.0, _t('明显', 'Full'))],
          value: palette.glowOpacity,
          onChanged: (v) => c.palette((p) => p.copyWith(glowOpacity: v)),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const ValueKey('theme-studio-all-colors'),
            icon: const Icon(AppIcons.color, size: 16),
            label: Text(
              changed == 0 ? _t('全部颜色', 'All colors') : _t('全部颜色 · 已改 $changed 项', 'All colors · $changed changed'),
            ),
            onPressed: () => unawaited(
              showAppSheet<void>(
                context,
                heightFactor: 0.92,
                builder: (_) => ThemeStudioColorsSheet(controller: c, startDark: previewDark),
              ),
            ),
          ),
        ),
      ],
      more: [
        StudioHexField(
          value: palette.seedDark,
          onChanged: (argb) => c.palette((p) => p.copyWith(seedDark: () => argb)),
          label: _t('深色模式的主色（不填自动算）', 'Accent in dark mode (derived when empty)'),
          onPick: () => unawaited(
            _pick(
              context,
              _now('primary', dark: true),
              (argb) => c.palette((p) => p.copyWith(seedDark: () => argb)),
              opacity: false,
            ),
          ),
        ),
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 30,
              child: Row(
                children: [
                  Expanded(
                    child: Text(_t('背景和文字偏向的色调', 'Tint of backgrounds and text'), style: theme.textTheme.bodyMedium),
                  ),
                  Text(
                    hue == null ? _t('跟随主色', 'Follows the accent') : '${hue.round()}°',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  if (hue != null)
                    TextButton(
                      onPressed: () => c.palette((p) => p.copyWith(tintHue: () => null)),
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 28),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(_t('跟随主色', 'Follow the accent')),
                    ),
                ],
              ),
            ),
            HueSlider(
              hue: hue ?? Oklch.fromColor(Color(palette.seed)).h,
              brightness: theme.brightness,
              onChanged: (h) => c.palette((p) => p.copyWith(tintHue: () => h.roundToDouble())),
            ),
          ],
        ),
        StudioSlider(
          label: _t('色调的浓淡', 'Tint strength'),
          value: palette.tintChroma,
          min: 0,
          max: 2,
          fallback: 1,
          format: StudioSlider.times,
          onChanged: (v) => c.palette((p) => p.copyWith(tintChroma: v)),
        ),
        StudioSlider(
          label: _t('光晕强度', 'Glow strength'),
          value: palette.glowOpacity,
          min: 0,
          max: 1,
          fallback: 1,
          format: StudioSlider.percent,
          onChanged: (v) => c.palette((p) => p.copyWith(glowOpacity: v)),
        ),
      ],
    );
  }
}

class StudioSurfaceGroup extends _Group {
  const StudioSurfaceGroup({
    super.key,
    required super.c,
    required super.open,
    required super.onToggle,
    required this.resolved,
  });

  /// The draft as a theme: where an untouched tuning value is read from.
  final ThemeData resolved;

  @override
  Widget build(BuildContext context) {
    final s = c.pack.surfaces;
    final hasImage = s.backdropImage != null;
    final glass = resolved.extension<DshSurfaces>()!;
    Widget tune(
      String label,
      double? value,
      double max,
      double effective,
      ThemeSurfaceSpec Function(double? v) write, {
      double step = 0.05,
      String Function(double)? format,
    }) => StudioSlider(
      label: label,
      value: value,
      min: 0,
      max: max,
      effective: effective,
      follows: _t('跟随材质', 'Follows material'),
      step: step,
      format: format,
      onChanged: (v) => c.surfaces((_) => write(v)),
    );
    return StudioGroup(
      id: 'surfaces',
      title: _t('材质与背景', 'Material & backdrop'),
      open: open,
      onToggle: onToggle,
      basics: [
        StudioChoice<ThemeSurfacePreset>(
          label: _t('材质', 'Material'),
          items: [
            (ThemeSurfacePreset.glass, _t('磨砂玻璃', 'Frosted glass')),
            (ThemeSurfacePreset.paper, _t('实心纸面', 'Solid paper')),
            (ThemeSurfacePreset.flat, _t('纯平', 'Flat')),
            (ThemeSurfacePreset.outlined, _t('线框', 'Outlined')),
          ],
          value: s.preset,
          onChanged: c.setPreset,
        ),
        StudioAssetRow(
          title: _t('背景图', 'Backdrop'),
          pickLabel: _t('选择背景图（PNG / WebP / GIF）', 'Pick a backdrop (PNG / WebP / GIF)'),
          fileName: s.backdropImage,
          missing: c.isMissing(s.backdropImage),
          onPick: () => unawaited(c.pickImage(ThemeImageSlot.backdrop)),
          onClear: () => c.setImage(ThemeImageSlot.backdrop, null),
        ),
        if (hasImage) ...[
          StudioSlider(
            label: _t('背景图不透明度', 'Backdrop opacity'),
            value: s.backdropOpacity,
            min: 0,
            max: 1,
            fallback: 0.18,
            step: 0.01,
            format: StudioSlider.percent,
            onChanged: (v) => c.surfaces((s) => s.copyWith(backdropOpacity: v)),
          ),
          StudioSwitch(
            label: _t('小图平铺', 'Tile the image'),
            value: s.backdropRepeat,
            onChanged: (v) => c.surfaces((s) => s.copyWith(backdropRepeat: v)),
          ),
        ],
      ],
      more: [
        if (hasImage) ...[
          StudioSlider(
            label: _t('背景图模糊', 'Backdrop blur'),
            value: s.backdropBlur,
            min: 0,
            max: 40,
            fallback: 0,
            step: 1,
            onChanged: (v) => c.surfaces((s) => s.copyWith(backdropBlur: v)),
          ),
          StudioChoice<ThemeBackdropAlign>(
            label: _t('背景图对齐', 'Backdrop alignment'),
            items: [
              (ThemeBackdropAlign.center, _t('居中', 'Center')),
              (ThemeBackdropAlign.top, _t('靠上', 'Top')),
              (ThemeBackdropAlign.bottom, _t('靠下', 'Bottom')),
            ],
            value: s.backdropAlign,
            onChanged: (v) => c.surfaces((s) => s.copyWith(backdropAlign: v)),
          ),
          StudioSwitch(
            label: _t('动图保持播放', 'Keep animated images playing'),
            value: s.backdropAnimate,
            onChanged: (v) => c.surfaces((s) => s.copyWith(backdropAnimate: v)),
          ),
        ],
        StudioChoice<ThemeBackdropPattern>(
          label: _t('背景纹理', 'Backdrop pattern'),
          items: [
            (ThemeBackdropPattern.none, _t('没有', 'None')),
            (ThemeBackdropPattern.dots, _t('圆点', 'Dots')),
            (ThemeBackdropPattern.grid, _t('网格', 'Grid')),
            (ThemeBackdropPattern.lines, _t('横线', 'Lines')),
            (ThemeBackdropPattern.diagonal, _t('斜线', 'Diagonal')),
            (ThemeBackdropPattern.grain, _t('颗粒', 'Grain')),
          ],
          value: s.pattern,
          onChanged: (v) => c.surfaces((s) => s.copyWith(pattern: v)),
        ),
        if (s.pattern != ThemeBackdropPattern.none) ...[
          StudioSlider(
            label: _t('纹理深浅', 'Pattern strength'),
            value: s.patternOpacity,
            min: 0,
            max: 1,
            fallback: 0.06,
            step: 0.01,
            format: StudioSlider.percent,
            onChanged: (v) => c.surfaces((s) => s.copyWith(patternOpacity: v)),
          ),
          StudioSlider(
            label: _t('纹理疏密', 'Pattern spacing'),
            value: s.patternScale,
            min: 0.5,
            max: 3,
            fallback: 1,
            step: 0.1,
            format: StudioSlider.times,
            onChanged: (v) => c.surfaces((s) => s.copyWith(patternScale: v)),
          ),
        ],
        StudioChoice<ThemeGlowLayout>(
          label: _t('光晕位置', 'Glow position'),
          items: [
            (ThemeGlowLayout.corners, _t('两角', 'Corners')),
            (ThemeGlowLayout.top, _t('顶部', 'Top')),
            (ThemeGlowLayout.bottom, _t('底部', 'Bottom')),
            (ThemeGlowLayout.center, _t('中间', 'Center')),
          ],
          value: s.glowLayout,
          onChanged: (v) => c.surfaces((s) => s.copyWith(glowLayout: v)),
        ),
        StudioCaption(_t('材质微调（没动过的跟着材质走）', 'Material tuning (untouched values follow the material)')),
        tune(
          _t('顶栏模糊', 'Top bar blur'),
          s.chromeBlur,
          40,
          glass.chrome.blurSigma,
          (v) => s.copyWith(chromeBlur: () => v),
          step: 1,
        ),
        tune(
          _t('面板模糊', 'Sheet blur'),
          s.sheetBlur,
          40,
          glass.sheet.blurSigma,
          (v) => s.copyWith(sheetBlur: () => v),
          step: 1,
        ),
        tune(
          _t('卡片不透明度', 'Card opacity'),
          s.cardOpacity,
          1,
          glass.card.fill.a,
          (v) => s.copyWith(cardOpacity: () => v),
          format: StudioSlider.percent,
        ),
        tune(
          _t('胶囊不透明度', 'Pill opacity'),
          s.pillOpacity,
          1,
          glass.pill.fill.a,
          (v) => s.copyWith(pillOpacity: () => v),
          format: StudioSlider.percent,
        ),
        tune(
          _t('描边粗细', 'Edge width'),
          s.hairlineWidth,
          3,
          glass.chrome.hairlineWidth,
          (v) => s.copyWith(hairlineWidth: () => v),
          step: 0.1,
        ),
        // The last two scale what the material has: untouched is all of it.
        tune(
          _t('边缘高光', 'Edge highlight'),
          s.rimOpacity,
          1,
          1,
          (v) => s.copyWith(rimOpacity: () => v),
          format: StudioSlider.percent,
        ),
        tune(
          _t('阴影', 'Shadow'),
          s.shadowOpacity,
          1,
          1,
          (v) => s.copyWith(shadowOpacity: () => v),
          format: StudioSlider.percent,
        ),
      ],
    );
  }
}

/// One font role: a built-in face, a font file already in the pack, or a new file.
class _FontChoice extends StatelessWidget {
  const _FontChoice({required this.c, required this.role, required this.label});

  final ThemeStudioController c;
  final ThemeFontRole role;
  final String label;

  @override
  Widget build(BuildContext context) {
    final code = role == ThemeFontRole.code;
    final current = c.fontOf(role);
    // 'mono', 'monospace' and 'JetBrainsMono' are all accepted everywhere; each role offers the ones it tells apart.
    final shown = code
        ? (current == 'mono' ? 'monospace' : current)
        : (current == 'monospace' || current == 'JetBrainsMono' ? 'mono' : current);
    final builtIn = code
        ? [('JetBrainsMono', 'JetBrains Mono'), ('monospace', _t('系统等宽', 'System mono'))]
        : [('system', _t('系统', 'System')), ('serif', _t('衬线', 'Serif')), ('mono', _t('等宽', 'Mono'))];
    final files = {...c.fontFiles, if (ThemeTypographySpec.isCustomFontAsset(current)) current};
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StudioCaption(label),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final (value, name) in builtIn)
              CapsuleChoiceChip(label: name, selected: shown == value, onSelected: () => c.chooseFont(role, value)),
            for (final file in files)
              CapsuleChoiceChip(
                label: file,
                icon: AppIcons.files,
                selected: current == file,
                onSelected: () => c.chooseFont(role, file),
              ),
            ActionChip(
              key: ValueKey('theme-studio-font-${role.name}'),
              avatar: const Icon(AppIcons.add, size: 14),
              label: Text(_t('选字体文件', 'Pick a font file')),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: const StadiumBorder(),
              onPressed: () => unawaited(c.pickFont(role)),
            ),
          ],
        ),
        if (ThemeTypographySpec.isCustomFontAsset(current) && c.isMissing(current)) StudioMissingNote(current),
      ],
    );
  }
}

class StudioTypographyGroup extends _Group {
  const StudioTypographyGroup({super.key, required super.c, required super.open, required super.onToggle});

  @override
  Widget build(BuildContext context) {
    final t = c.pack.typography;
    return StudioGroup(
      id: 'typography',
      title: _t('字体', 'Fonts'),
      open: open,
      onToggle: onToggle,
      basics: [
        _FontChoice(
          c: c,
          role: ThemeFontRole.reading,
          label: _t('回复字体（.ttf / .otf 也可以）', 'Reply font (.ttf / .otf work too)'),
        ),
        StudioChoice<double>(
          label: _t('回复行距', 'Reply line spacing'),
          items: [(1.45, _t('紧凑', 'Compact')), (1.55, _t('标准', 'Standard')), (1.68, _t('舒展', 'Open'))],
          value: t.readingLineHeight,
          onChanged: (v) => c.typography((t) => t.copyWith(readingLineHeight: v)),
        ),
      ],
      more: [
        _FontChoice(c: c, role: ThemeFontRole.ui, label: _t('界面字体', 'Interface font')),
        _FontChoice(c: c, role: ThemeFontRole.heading, label: _t('标题字体', 'Heading font')),
        _FontChoice(c: c, role: ThemeFontRole.code, label: _t('代码字体', 'Code font')),
        StudioSwitch(
          label: _t('回复正文用回复字体', 'Use the reply font for replies'),
          value: c.pack.components.useReadingFontForReply,
          onChanged: (v) => c.components((p) => p.copyWith(useReadingFontForReply: v)),
        ),
        StudioSlider(
          label: _t('回复字号', 'Reply size'),
          value: t.readingScale,
          min: 0.85,
          max: 1.25,
          fallback: 1,
          step: 0.01,
          format: StudioSlider.times,
          onChanged: (v) => c.typography((t) => t.copyWith(readingScale: v)),
        ),
        StudioSlider(
          label: _t('回复行距（精确）', 'Reply line spacing (exact)'),
          value: t.readingLineHeight,
          min: 1.2,
          max: 2,
          fallback: 1.55,
          step: 0.01,
          onChanged: (v) => c.typography((t) => t.copyWith(readingLineHeight: v)),
        ),
        StudioSlider(
          label: _t('回复字距', 'Reply letter spacing'),
          value: t.readingLetterSpacing,
          min: -0.5,
          max: 2,
          fallback: 0,
          step: 0.1,
          onChanged: (v) => c.typography((t) => t.copyWith(readingLetterSpacing: v)),
        ),
        StudioSlider(
          label: _t('标题字号', 'Heading size'),
          value: t.headingScale,
          min: 0.85,
          max: 1.35,
          fallback: 1,
          step: 0.01,
          format: StudioSlider.times,
          onChanged: (v) => c.typography((t) => t.copyWith(headingScale: v)),
        ),
        StudioSlider(
          label: _t('标题字距', 'Heading letter spacing'),
          value: t.headingLetterSpacing,
          min: -1,
          max: 4,
          fallback: 0,
          step: 0.1,
          onChanged: (v) => c.typography((t) => t.copyWith(headingLetterSpacing: v)),
        ),
        StudioChoice<int?>(
          label: _t('标题粗细', 'Heading weight'),
          items: [
            (null, _t('默认', 'Default')),
            for (final weight in const [300, 400, 500, 600, 700, 800, 900]) (weight, '$weight'),
          ],
          value: t.headingWeight,
          onChanged: (v) => c.typography((t) => t.copyWith(headingWeight: () => v)),
        ),
        StudioSlider(
          label: _t('代码字号', 'Code size'),
          value: t.codeScale,
          min: 0.85,
          max: 1.2,
          fallback: 1,
          step: 0.01,
          format: StudioSlider.times,
          onChanged: (v) => c.typography((t) => t.copyWith(codeScale: v)),
        ),
      ],
    );
  }
}

class StudioShapeGroup extends _Group {
  const StudioShapeGroup({
    super.key,
    required super.c,
    required super.open,
    required super.onToggle,
    required this.resolved,
  });

  /// The draft as a theme: where a radius that follows the overall roundness is read from.
  final ThemeData resolved;

  @override
  Widget build(BuildContext context) {
    final s = c.pack.shapes;
    final style = resolved.extension<DshThemeStyle>()!;
    Widget radius(String label, double? value, double effective, ThemeShapeSpec Function(double? v) write) =>
        StudioSlider(
          label: label,
          value: value,
          min: 0,
          max: 36,
          step: 1,
          effective: effective,
          follows: _t('跟随整体', 'Follows overall'),
          onChanged: (v) => c.shapes((_) => write(v)),
        );
    return StudioGroup(
      id: 'shapes',
      title: _t('形状与间距', 'Shape & spacing'),
      open: open,
      onToggle: onToggle,
      basics: [
        StudioChoice<double>(
          label: _t('圆角', 'Corners'),
          items: [
            (0.28, _t('硬朗', 'Sharp')),
            (0.85, _t('微圆', 'Gentle')),
            (1.0, _t('标准', 'Standard')),
            (1.32, _t('圆润', 'Soft')),
          ],
          value: s.cornerScale,
          onChanged: (v) => c.shapes((s) => s.copyWith(cornerScale: v)),
        ),
        StudioChoice<double>(
          label: _t('疏密', 'Density'),
          items: [(16.0, _t('紧凑', 'Compact')), (24.0, _t('标准', 'Standard')), (30.0, _t('宽松', 'Airy'))],
          value: s.turnGap,
          // One choice sets all three gaps; each has its own slider under 「更多选项」.
          onChanged: (v) => c.shapes(
            (s) => s.copyWith(
              turnGap: v,
              inTurnGap: v <= 18 ? 6.0 : (v >= 28 ? 10.0 : 8.0),
              gutter: v <= 18 ? 14.0 : 16.0,
            ),
          ),
        ),
      ],
      more: [
        StudioChoice<ThemeCornerStyle>(
          label: _t('角型', 'Corner style'),
          items: [
            (ThemeCornerStyle.squircle, _t('圆润', 'Smooth')),
            (ThemeCornerStyle.round, _t('正圆角', 'Round')),
            (ThemeCornerStyle.bevel, _t('切角', 'Bevel')),
          ],
          value: s.cornerStyle,
          onChanged: (v) => c.shapes((s) => s.copyWith(cornerStyle: v)),
        ),
        StudioChoice<ThemeBubbleCorners>(
          label: _t('气泡四角', 'Bubble corners'),
          items: [
            (ThemeBubbleCorners.uniform, _t('四角一样', 'Even')),
            (ThemeBubbleCorners.tail, _t('带小尾巴', 'Tail')),
            (ThemeBubbleCorners.leaf, _t('叶片', 'Leaf')),
          ],
          value: s.bubbleCorners,
          onChanged: (v) => c.shapes((s) => s.copyWith(bubbleCorners: v)),
        ),
        StudioSlider(
          label: _t('整体圆角', 'Overall roundness'),
          value: s.cornerScale,
          min: 0,
          max: 1.6,
          fallback: 1,
          step: 0.01,
          format: StudioSlider.times,
          onChanged: (v) => c.shapes((s) => s.copyWith(cornerScale: v)),
        ),
        radius(
          _t('气泡圆角', 'Bubble radius'),
          s.bubbleRadius,
          style.bubbleRadius,
          (v) => s.copyWith(bubbleRadius: () => v),
        ),
        radius(_t('卡片圆角', 'Card radius'), s.cardRadius, style.cardRadius, (v) => s.copyWith(cardRadius: () => v)),
        radius(
          _t('代码块圆角', 'Code block radius'),
          s.codeRadius,
          style.codeRadius,
          (v) => s.copyWith(codeRadius: () => v),
        ),
        radius(
          _t('输入框圆角', 'Composer radius'),
          s.composerRadius,
          style.composerRadius,
          (v) => s.copyWith(composerRadius: () => v),
        ),
        StudioSlider(
          label: _t('气泡左右留白', 'Bubble side padding'),
          value: s.bubblePadH,
          min: 10,
          max: 24,
          fallback: 16,
          step: 1,
          onChanged: (v) => c.shapes((s) => s.copyWith(bubblePadH: v)),
        ),
        StudioSlider(
          label: _t('气泡上下留白', 'Bubble top and bottom padding'),
          value: s.bubblePadV,
          min: 6,
          max: 16,
          fallback: 8,
          step: 1,
          onChanged: (v) => c.shapes((s) => s.copyWith(bubblePadV: v)),
        ),
        StudioSlider(
          label: _t('描边粗细', 'Border width'),
          value: s.borderWidth,
          min: 0,
          max: 2.5,
          fallback: 0.5,
          step: 0.1,
          onChanged: (v) => c.shapes((s) => s.copyWith(borderWidth: v)),
        ),
        StudioSlider(
          label: _t('两轮对话之间', 'Between turns'),
          value: s.turnGap,
          min: 12,
          max: 40,
          fallback: 24,
          step: 1,
          onChanged: (v) => c.shapes((s) => s.copyWith(turnGap: v)),
        ),
        StudioSlider(
          label: _t('同一轮里的消息之间', 'Within a turn'),
          value: s.inTurnGap,
          min: 4,
          max: 20,
          fallback: 8,
          step: 1,
          onChanged: (v) => c.shapes((s) => s.copyWith(inTurnGap: v)),
        ),
        StudioSlider(
          label: _t('左右页边距', 'Side margin'),
          value: s.gutter,
          min: 10,
          max: 28,
          fallback: 16,
          step: 1,
          onChanged: (v) => c.shapes((s) => s.copyWith(gutter: v)),
        ),
      ],
    );
  }
}

class StudioComponentGroup extends _Group {
  const StudioComponentGroup({super.key, required super.c, required super.open, required super.onToggle});

  @override
  Widget build(BuildContext context) {
    final p = c.pack.components;
    return StudioGroup(
      id: 'components',
      title: _t('界面组件', 'Components'),
      open: open,
      onToggle: onToggle,
      basics: [
        StudioChoice<ThemeHeaderStyle>(
          label: _t('顶栏', 'Top bar'),
          items: [
            (ThemeHeaderStyle.glass, _t('玻璃', 'Glass')),
            (ThemeHeaderStyle.ghost, _t('透明无框', 'Ghost')),
            (ThemeHeaderStyle.outlined, _t('细线框', 'Outlined')),
            (ThemeHeaderStyle.minimal, _t('柔和实底', 'Minimal')),
          ],
          value: p.headerStyle,
          onChanged: (v) => c.components((p) => p.copyWith(headerStyle: v)),
        ),
        StudioChoice<ThemeComposerStyle>(
          label: _t('输入框', 'Composer'),
          items: [
            (ThemeComposerStyle.floatingGlass, _t('玻璃', 'Glass')),
            (ThemeComposerStyle.solidPaper, _t('实心纸面', 'Solid paper')),
            (ThemeComposerStyle.outlined, _t('线框', 'Outlined')),
          ],
          value: p.composerStyle,
          onChanged: (v) => c.components((p) => p.copyWith(composerStyle: v)),
        ),
        StudioChoice<ThemeSendButtonStyle>(
          label: _t('发送键', 'Send button'),
          items: [
            (ThemeSendButtonStyle.primary, _t('主色', 'Accent')),
            (ThemeSendButtonStyle.ink, _t('深墨反白', 'Ink')),
            (ThemeSendButtonStyle.tonal, _t('柔和浅底', 'Tonal')),
            (ThemeSendButtonStyle.outlined, _t('线框', 'Outlined')),
          ],
          value: p.sendButtonStyle,
          onChanged: (v) => c.components((p) => p.copyWith(sendButtonStyle: v)),
        ),
        StudioChoice<ThemeUserBubbleStyle>(
          label: _t('我的消息', 'My messages'),
          items: [
            (ThemeUserBubbleStyle.soft, _t('软气泡', 'Soft')),
            (ThemeUserBubbleStyle.outlined, _t('细框', 'Outlined')),
            (ThemeUserBubbleStyle.accent, _t('主色浅底', 'Accent')),
            (ThemeUserBubbleStyle.minimal, _t('右侧竖线', 'Side rule')),
          ],
          value: p.userBubbleStyle,
          onChanged: (v) => c.components((p) => p.copyWith(userBubbleStyle: v)),
        ),
        StudioChoice<ThemeAssistantStyle>(
          label: _t('助手回复', 'Replies'),
          items: [
            (ThemeAssistantStyle.plain, _t('直接排版', 'Plain')),
            (ThemeAssistantStyle.card, _t('卡片', 'Card')),
            (ThemeAssistantStyle.leftRule, _t('左侧引线', 'Side rule')),
            (ThemeAssistantStyle.quote, _t('引用块', 'Quote')),
          ],
          value: p.assistantStyle,
          onChanged: (v) => c.components((p) => p.copyWith(assistantStyle: v)),
        ),
        StudioChoice<ThemeCodeBlockStyle>(
          label: _t('代码块', 'Code blocks'),
          items: [
            (ThemeCodeBlockStyle.well, _t('深底', 'Well')),
            (ThemeCodeBlockStyle.outlined, _t('线框', 'Outlined')),
            (ThemeCodeBlockStyle.card, _t('卡片', 'Card')),
          ],
          value: p.codeBlockStyle,
          onChanged: (v) => c.components((p) => p.copyWith(codeBlockStyle: v)),
        ),
      ],
      more: [
        StudioChoice<ThemeSendButtonShape>(
          label: _t('发送键形状', 'Send button shape'),
          items: [
            (ThemeSendButtonShape.circle, _t('圆形', 'Circle')),
            (ThemeSendButtonShape.squircle, _t('圆角方', 'Rounded')),
            (ThemeSendButtonShape.square, _t('方形', 'Square')),
          ],
          value: p.sendButtonShape,
          onChanged: (v) => c.components((p) => p.copyWith(sendButtonShape: v)),
        ),
        StudioChoice<ThemeCodeHeaderStyle>(
          label: _t('代码块标题条', 'Code block header'),
          items: [
            (ThemeCodeHeaderStyle.bar, _t('填色', 'Filled')),
            (ThemeCodeHeaderStyle.plain, _t('只留文字', 'Text only')),
          ],
          value: p.codeHeaderStyle,
          onChanged: (v) => c.components((p) => p.copyWith(codeHeaderStyle: v)),
        ),
        StudioChoice<ThemeTurnDivider>(
          label: _t('两轮对话之间的分隔', 'Divider between turns'),
          items: [
            (ThemeTurnDivider.none, _t('没有', 'None')),
            (ThemeTurnDivider.hairline, _t('细线', 'Hairline')),
            (ThemeTurnDivider.dashed, _t('虚线', 'Dashed')),
            (ThemeTurnDivider.dots, _t('圆点', 'Dots')),
          ],
          value: p.turnDivider,
          onChanged: (v) => c.components((p) => p.copyWith(turnDivider: v)),
        ),
        StudioChoice<ThemeHeadingStyle>(
          label: _t('回复里的标题', 'Headings in replies'),
          items: [
            (ThemeHeadingStyle.plain, _t('普通', 'Plain')),
            (ThemeHeadingStyle.accent, _t('上色', 'Coloured')),
            (ThemeHeadingStyle.underline, _t('下划线', 'Underlined')),
            (ThemeHeadingStyle.marker, _t('小竖条', 'Marker')),
          ],
          value: p.headingStyle,
          onChanged: (v) => c.components((p) => p.copyWith(headingStyle: v)),
        ),
        StudioChoice<ThemeBulletStyle>(
          label: _t('列表符号', 'List bullets'),
          items: [
            (ThemeBulletStyle.dot, _t('圆点 •', 'Dot •')),
            (ThemeBulletStyle.dash, _t('短横 –', 'Dash –')),
            (ThemeBulletStyle.diamond, _t('菱形 ◆', 'Diamond ◆')),
            (ThemeBulletStyle.arrow, _t('箭头 ›', 'Arrow ›')),
            (ThemeBulletStyle.square, _t('方块 ▪', 'Square ▪')),
          ],
          value: p.bulletStyle,
          onChanged: (v) => c.components((p) => p.copyWith(bulletStyle: v)),
        ),
        StudioChoice<ThemeHeaderTitleFont>(
          label: _t('顶栏标题用哪种字体', 'Top bar title font'),
          items: [
            (ThemeHeaderTitleFont.ui, _t('界面字体', 'Interface')),
            (ThemeHeaderTitleFont.heading, _t('标题字体', 'Heading')),
            (ThemeHeaderTitleFont.code, _t('代码字体', 'Code')),
          ],
          value: p.headerTitleFont,
          onChanged: (v) => c.components((p) => p.copyWith(headerTitleFont: v)),
        ),
        StudioLocalizedText(
          label: _t('我的小标签', 'My label'),
          value: p.userLabel,
          maxLength: 16,
          onChanged: (v) => c.components((p) => p.copyWith(userLabel: () => v)),
        ),
        StudioLocalizedText(
          label: _t('助手小标签', 'Assistant label'),
          value: p.assistantLabel,
          maxLength: 16,
          onChanged: (v) => c.components((p) => p.copyWith(assistantLabel: () => v)),
        ),
        StudioLocalizedText(
          label: _t('输入框提示语', 'Composer hint'),
          value: p.composerHint,
          maxLength: 30,
          onChanged: (v) => c.components((p) => p.copyWith(composerHint: () => v)),
        ),
        StudioAssetRow(
          title: _t('助手头像', 'Assistant avatar'),
          pickLabel: _t('选择助手头像', 'Pick an assistant avatar'),
          fileName: p.assistantAvatar,
          missing: c.isMissing(p.assistantAvatar),
          onPick: () => unawaited(c.pickImage(ThemeImageSlot.assistantAvatar)),
          onClear: () => c.setImage(ThemeImageSlot.assistantAvatar, null),
        ),
        StudioAssetRow(
          title: _t('我的头像', 'My avatar'),
          pickLabel: _t('选择我的头像', 'Pick my avatar'),
          fileName: p.userAvatar,
          missing: c.isMissing(p.userAvatar),
          onPick: () => unawaited(c.pickImage(ThemeImageSlot.userAvatar)),
          onClear: () => c.setImage(ThemeImageSlot.userAvatar, null),
        ),
      ],
    );
  }
}

class StudioEmptyStateGroup extends _Group {
  const StudioEmptyStateGroup({super.key, required super.c, required super.open, required super.onToggle});

  @override
  Widget build(BuildContext context) {
    final e = c.pack.emptyState;
    final drawsGlyph = e.heroStyle == ThemeHeroStyle.glyph || e.heroStyle == ThemeHeroStyle.seal;
    return StudioGroup(
      id: 'empty',
      title: _t('新对话页', 'New chat page'),
      open: open,
      onToggle: onToggle,
      basics: [
        StudioChoice<ThemeEmptyLayout>(
          label: _t('版式', 'Layout'),
          items: [
            (ThemeEmptyLayout.centered, _t('居中', 'Centered')),
            (ThemeEmptyLayout.editorial, _t('靠左', 'Left aligned')),
            (ThemeEmptyLayout.compact, _t('紧凑', 'Compact')),
          ],
          value: e.layout,
          onChanged: (v) => c.emptyState((e) => e.copyWith(layout: v)),
        ),
        StudioChoice<ThemeHeroStyle>(
          label: _t('主视觉', 'Hero'),
          items: [
            (ThemeHeroStyle.whale, _t('鲸尾', 'Whale')),
            (ThemeHeroStyle.badge, _t('徽章', 'Badge')),
            (ThemeHeroStyle.glyph, _t('文字', 'Glyph')),
            (ThemeHeroStyle.seal, _t('印章', 'Seal')),
            (ThemeHeroStyle.customImage, _t('自选图片', 'Own image')),
            (ThemeHeroStyle.hidden, _t('不显示', 'Hidden')),
          ],
          value: e.heroStyle,
          // Without an image yet, the choice only takes once one is picked.
          onChanged: (v) => v == ThemeHeroStyle.customImage && e.heroImage == null
              ? unawaited(c.pickImage(ThemeImageSlot.hero))
              : c.emptyState((e) => e.copyWith(heroStyle: v)),
        ),
        if (drawsGlyph)
          StudioField.text(
            key: const ValueKey('theme-studio-hero-glyph'),
            value: e.heroGlyph ?? '',
            onChanged: (text) => c.emptyState((e) => e.copyWith(heroGlyph: () => _blankToNull(text))),
            label: _t('主视觉上的字（1–4 个）', 'Hero characters (1–4)'),
            maxLength: 4,
            errorText: e.heroGlyph == null ? _t('这里要填', 'Required') : null,
          ),
        if (e.heroStyle == ThemeHeroStyle.customImage)
          StudioAssetRow(
            title: _t('主视觉图', 'Hero image'),
            pickLabel: _t('选择主视觉图（PNG / WebP / GIF）', 'Pick a hero image (PNG / WebP / GIF)'),
            fileName: e.heroImage,
            missing: c.isMissing(e.heroImage),
            onPick: () => unawaited(c.pickImage(ThemeImageSlot.hero)),
            onClear: () => c.setImage(ThemeImageSlot.hero, null),
          ),
        StudioChoice<ThemeSuggestionsDisplay>(
          label: _t('建议卡', 'Suggestions'),
          items: [
            (ThemeSuggestionsDisplay.expanded, _t('展开', 'Expanded')),
            (ThemeSuggestionsDisplay.grid, _t('双列', 'Two columns')),
            (ThemeSuggestionsDisplay.collapsible, _t('折叠', 'Collapsed')),
          ],
          value: e.suggestionsDisplay,
          // The collapsed list is a quieter page: no connection subtitle, paper cards.
          onChanged: (v) => c.update(
            c.pack.copyWith(
              emptyState: c.pack.emptyState.copyWith(
                suggestionsDisplay: v,
                showConnectedSubtitle: v != ThemeSuggestionsDisplay.collapsible,
              ),
              components: v == ThemeSuggestionsDisplay.collapsible
                  ? c.pack.components.copyWith(suggestionCardStyle: ThemeSuggestionCardStyle.paper)
                  : null,
            ),
          ),
        ),
      ],
      more: [
        StudioSlider(
          label: _t('主视觉大小', 'Hero size'),
          value: e.heroScale,
          min: 0.6,
          max: 2,
          fallback: 1,
          format: StudioSlider.times,
          onChanged: (v) => c.emptyState((e) => e.copyWith(heroScale: v)),
        ),
        StudioLocalizedText(
          label: _t('问候语', 'Greeting'),
          value: e.greeting,
          maxLength: 40,
          onChanged: (v) => c.emptyState((e) => e.copyWith(greeting: () => v)),
        ),
        StudioLocalizedText(
          label: _t('副标题', 'Subtitle'),
          value: e.subtitle,
          maxLength: 60,
          onChanged: (v) => c.emptyState((e) => e.copyWith(subtitle: () => v)),
        ),
        StudioSwitch(
          label: _t('问候语用回复字体', 'Use the reply font for the greeting'),
          value: e.useReadingFontForGreeting,
          onChanged: (v) => c.emptyState((e) => e.copyWith(useReadingFontForGreeting: v)),
        ),
        StudioSwitch(
          label: _t('连上后显示副标题', 'Show the subtitle once connected'),
          value: e.showConnectedSubtitle,
          onChanged: (v) => c.emptyState((e) => e.copyWith(showConnectedSubtitle: v)),
        ),
        StudioChoice<ThemeSuggestionCardStyle>(
          label: _t('建议卡样式', 'Suggestion card style'),
          items: [
            (ThemeSuggestionCardStyle.glass, _t('玻璃', 'Glass')),
            (ThemeSuggestionCardStyle.paper, _t('纸面', 'Paper')),
            (ThemeSuggestionCardStyle.outlined, _t('线框', 'Outlined')),
            (ThemeSuggestionCardStyle.minimal, _t('极简', 'Minimal')),
          ],
          value: c.pack.components.suggestionCardStyle,
          onChanged: (v) => c.components((p) => p.copyWith(suggestionCardStyle: v)),
        ),
      ],
    );
  }
}
