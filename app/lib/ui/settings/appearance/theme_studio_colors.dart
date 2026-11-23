// The Theme Studio's full colour list: every colour a pack can override, for light and dark, with a HEX field
// and a picker per row.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../common/app_sheet.dart';
import '../../common/segmented_pill.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'hue_slider.dart';
import 'theme_studio_controller.dart';
import 'theme_studio_controls.dart';

typedef _Token = ({String key, String zh, String en, String useZh, String useEn});

const List<(String zh, String en, List<_Token> tokens)> _colorGroups = [
  (
    '背景与光晕',
    'Backdrop & glow',
    [
      (key: 'backdropTop', zh: '背景上端', en: 'Backdrop top', useZh: '页面背景渐变的上端', useEn: 'Top of the page gradient'),
      (
        key: 'backdropBottom',
        zh: '背景下端',
        en: 'Backdrop bottom',
        useZh: '页面背景渐变的下端',
        useEn: 'Bottom of the page gradient',
      ),
      (key: 'glowPrimary', zh: '主光晕', en: 'Main glow', useZh: '背景里的第一团光', useEn: 'The first glow in the backdrop'),
      (key: 'glowSecondary', zh: '副光晕', en: 'Second glow', useZh: '背景里的第二团光', useEn: 'The second glow in the backdrop'),
      (key: 'patternInk', zh: '纹理', en: 'Pattern', useZh: '背景纹理的点和线', useEn: 'Dots and lines of the backdrop pattern'),
    ],
  ),
  (
    '表面与描边',
    'Surfaces & lines',
    [
      (key: 'surface', zh: '页面底色', en: 'Surface', useZh: '页面和面板的基础底色', useEn: 'Base colour of pages and panels'),
      (key: 'cardFill', zh: '卡片', en: 'Cards', useZh: '卡片的填充色，可以带透明度', useEn: 'Card fill; may be translucent'),
      (
        key: 'chromeFill',
        zh: '顶栏与输入框',
        en: 'Top bar & composer',
        useZh: '顶栏胶囊、输入框这一层的填充色',
        useEn: 'Fill of the top bar and composer layer',
      ),
      (key: 'sheetFill', zh: '底部面板', en: 'Sheets', useZh: '从底部升起的面板', useEn: 'Panels that rise from the bottom'),
      (
        key: 'hairline',
        zh: '细描边',
        en: 'Hairline',
        useZh: '卡片、顶栏、面板边缘的细线',
        useEn: 'Thin edge of cards, bars and sheets',
      ),
      (key: 'outline', zh: '分隔线（深）', en: 'Outline', useZh: '比较明显的边框和分隔线', useEn: 'Stronger borders and dividers'),
      (
        key: 'outlineVariant',
        zh: '分隔线（浅）',
        en: 'Soft outline',
        useZh: '比较淡的边框和分隔线',
        useEn: 'Softer borders and dividers',
      ),
    ],
  ),
  (
    '文字',
    'Text',
    [
      (key: 'onSurface', zh: '正文', en: 'Body text', useZh: '正文和标题', useEn: 'Body text and titles'),
      (key: 'onSurfaceVariant', zh: '次要文字', en: 'Secondary text', useZh: '说明文字和图标', useEn: 'Descriptions and icons'),
      (
        key: 'textTertiary',
        zh: '辅助文字',
        en: 'Faint text',
        useZh: '时间、提示这类最淡的字',
        useEn: 'Times, hints and other faint text',
      ),
      (key: 'heading', zh: '回复标题', en: 'Reply headings', useZh: '回复里的各级标题', useEn: 'Headings inside replies'),
      (key: 'link', zh: '链接', en: 'Links', useZh: '回复里的链接', useEn: 'Links inside replies'),
    ],
  ),
  (
    '主色',
    'Accent',
    [
      (key: 'primary', zh: '主色', en: 'Accent', useZh: '按钮、开关和选中状态', useEn: 'Buttons, switches and selection'),
      (key: 'onPrimary', zh: '主色上的字', en: 'On accent', useZh: '主色按钮上的文字和图标', useEn: 'Text and icons on accent buttons'),
      (
        key: 'primaryContainer',
        zh: '主色浅底',
        en: 'Accent tint',
        useZh: '选中项、标签的浅色底',
        useEn: 'Tinted fill of selected items and tags',
      ),
      (
        key: 'onPrimaryContainer',
        zh: '主色浅底上的字',
        en: 'On accent tint',
        useZh: '浅色底上的文字',
        useEn: 'Text on the tinted fill',
      ),
      (
        key: 'rule',
        zh: '引线',
        en: 'Rule',
        useZh: '回复左侧竖线、标题小竖条这类强调线',
        useEn: 'Reply side rule, heading marker and similar lines',
      ),
    ],
  ),
  (
    '消息气泡',
    'Messages',
    [
      (key: 'userBubble', zh: '我的气泡', en: 'My bubble', useZh: '你发出的消息的底色', useEn: 'Fill of the messages you send'),
      (
        key: 'onUserBubble',
        zh: '我的气泡文字',
        en: 'My bubble text',
        useZh: '你发出的消息的文字',
        useEn: 'Text of the messages you send',
      ),
      (
        key: 'userBubbleBorder',
        zh: '我的气泡描边',
        en: 'My bubble border',
        useZh: '线框样式气泡的边',
        useEn: 'Edge of the outlined bubble',
      ),
      (
        key: 'assistantBubble',
        zh: '回复卡片',
        en: 'Reply card',
        useZh: '回复用卡片样式时的底色',
        useEn: 'Fill of replies shown as cards',
      ),
      (key: 'onAssistantBubble', zh: '回复文字', en: 'Reply text', useZh: '回复正文', useEn: 'Text of replies'),
      (
        key: 'assistantBorder',
        zh: '回复卡片描边',
        en: 'Reply card border',
        useZh: '卡片和引用样式的边',
        useEn: 'Edge of card and quote replies',
      ),
    ],
  ),
  (
    '输入框与发送键',
    'Composer & send',
    [
      (key: 'composerFill', zh: '输入框底色', en: 'Composer fill', useZh: '输入框的填充色', useEn: 'Fill of the composer'),
      (key: 'composerBorder', zh: '输入框描边', en: 'Composer border', useZh: '输入框的边', useEn: 'Edge of the composer'),
      (key: 'sendButton', zh: '发送键', en: 'Send button', useZh: '能发送时的底色', useEn: 'Fill when a message can be sent'),
      (key: 'onSendButton', zh: '发送键图标', en: 'Send icon', useZh: '能发送时的箭头', useEn: 'Arrow when a message can be sent'),
    ],
  ),
  (
    '代码',
    'Code',
    [
      (key: 'codeWellBg', zh: '代码块底色', en: 'Code block', useZh: '代码块的底', useEn: 'Fill of code blocks'),
      (
        key: 'codeWellHeader',
        zh: '代码块标题条',
        en: 'Code header',
        useZh: '写着语言名的那一条',
        useEn: 'The bar with the language name',
      ),
      (key: 'codeWellFg', zh: '代码文字', en: 'Code text', useZh: '代码块里的字', useEn: 'Text inside code blocks'),
      (key: 'codeWellBorder', zh: '代码块描边', en: 'Code border', useZh: '代码块的边', useEn: 'Edge of code blocks'),
      (
        key: 'inlineCodeBg',
        zh: '行内代码底色',
        en: 'Inline code',
        useZh: '句子中间的代码的底',
        useEn: 'Fill of code inside a sentence',
      ),
      (
        key: 'inlineCodeFg',
        zh: '行内代码文字',
        en: 'Inline code text',
        useZh: '句子中间的代码的字',
        useEn: 'Text of code inside a sentence',
      ),
      (
        key: 'syntaxKeyword',
        zh: '关键字',
        en: 'Keywords',
        useZh: 'if、return、class 这类词',
        useEn: 'Words like if, return, class',
      ),
      (key: 'syntaxString', zh: '字符串', en: 'Strings', useZh: '引号里的文字', useEn: 'Text inside quotes'),
      (key: 'syntaxNumber', zh: '数字', en: 'Numbers', useZh: '数字和常量', useEn: 'Numbers and constants'),
      (key: 'syntaxComment', zh: '注释', en: 'Comments', useZh: '写给人看的说明', useEn: 'Notes written for people'),
      (key: 'syntaxFunction', zh: '函数名', en: 'Functions', useZh: '函数和方法的名字', useEn: 'Names of functions and methods'),
      (key: 'syntaxType', zh: '类型名', en: 'Types', useZh: '类和类型的名字', useEn: 'Names of classes and types'),
    ],
  ),
  (
    '状态色',
    'Status',
    [
      (key: 'success', zh: '成功', en: 'Success', useZh: '完成、通过', useEn: 'Done and passed'),
      (key: 'warning', zh: '提醒', en: 'Warning', useZh: '需要留意', useEn: 'Needs attention'),
      (key: 'danger', zh: '危险', en: 'Danger', useZh: '出错、删除', useEn: 'Errors and deletion'),
      (key: 'info', zh: '信息', en: 'Info', useZh: '一般提示', useEn: 'Neutral notices'),
    ],
  ),
];

/// The name the colour list gives [key]; null for a key it has no name for.
String? studioColorName(String key, {required bool english}) {
  for (final (_, _, tokens) in _colorGroups) {
    for (final token in tokens) {
      if (token.key == key) return english ? token.en : token.zh;
    }
  }
  return null;
}

/// The highlighter's own colour for a syntax role.
const _syntaxScopes = {
  'syntaxKeyword': 'keyword',
  'syntaxString': 'string',
  'syntaxNumber': 'number',
  'syntaxComment': 'comment',
  'syntaxFunction': 'title',
  'syntaxType': 'type',
};

/// The colour [key] shows in [theme] when the pack leaves it alone, where that can be told from the theme.
Color? _defaultColor(String key, ThemeData theme, ThemePack pack) {
  final scheme = theme.colorScheme;
  final surfaces = theme.extension<DshSurfaces>()!;
  final colors = theme.extension<DshColors>()!;
  final style = theme.extension<DshThemeStyle>();
  final send = pack.components.sendButtonStyle;
  return switch (key) {
    'backdropTop' => surfaces.backdropTop,
    'backdropBottom' => surfaces.backdropBottom,
    'glowPrimary' => surfaces.glowPrimary,
    'glowSecondary' => surfaces.glowSecondary,
    'surface' => scheme.surface,
    'onSurface' || 'heading' || 'patternInk' => scheme.onSurface,
    'onSurfaceVariant' => scheme.onSurfaceVariant,
    'outline' => scheme.outline,
    'outlineVariant' || 'userBubbleBorder' || 'assistantBorder' => scheme.outlineVariant,
    'primary' || 'link' || 'rule' => scheme.primary,
    'onPrimary' => scheme.onPrimary,
    'primaryContainer' => scheme.primaryContainer,
    'onPrimaryContainer' => scheme.onPrimaryContainer,
    'userBubble' => surfaces.userBubble,
    'onUserBubble' => surfaces.onUserBubble,
    'assistantBubble' => style?.assistantBubble ?? surfaces.card.fill,
    'onAssistantBubble' => style?.onAssistantBubble ?? scheme.onSurface,
    'codeWellBg' => colors.codeWellBg,
    'codeWellHeader' => colors.codeWellHeader,
    'codeWellFg' => colors.codeWellFg,
    'codeWellBorder' => colors.codeWellBorder,
    'composerFill' || 'chromeFill' => surfaces.chrome.fill,
    'composerBorder' || 'hairline' => surfaces.chrome.hairline,
    'sendButton' => switch (send) {
      ThemeSendButtonStyle.ink => scheme.onSurface,
      ThemeSendButtonStyle.tonal => scheme.primaryContainer,
      ThemeSendButtonStyle.outlined => Colors.transparent,
      ThemeSendButtonStyle.primary => scheme.primary,
    },
    'onSendButton' => switch (send) {
      ThemeSendButtonStyle.ink => scheme.surface,
      ThemeSendButtonStyle.tonal => scheme.onPrimaryContainer,
      ThemeSendButtonStyle.outlined => scheme.primary,
      ThemeSendButtonStyle.primary => scheme.onPrimary,
    },
    'cardFill' => surfaces.card.fill,
    'sheetFill' => surfaces.sheet.fill,
    'textTertiary' => colors.textTertiary,
    'success' => colors.success,
    'warning' => colors.warning,
    'danger' => colors.danger,
    'info' => colors.info,
    'inlineCodeBg' => colors.codeWellBg,
    'inlineCodeFg' => colors.codeWellFg,
    _ => dshHighlightTheme(theme.brightness, surfaces.accent)[_syntaxScopes[key]]?.color,
  };
}

/// The draft as a theme for one brightness, colours only (no loaded fonts).
ThemeData studioThemeOf(ThemePack pack, {required bool dark}) {
  // Under its own ID the draft would pick up the special-cased accent of the built-in it started from.
  final draft = pack.copyWith(id: 'draft-preview');
  final accent = AppAccent.fromThemePack(draft);
  return dark ? buildDarkTheme(accent: accent, themePack: draft) : buildLightTheme(accent: accent, themePack: draft);
}

/// The colour [key] has in the draft: the pack's own, or else what [theme] falls back to.
Color? studioTokenColor(String key, ThemeData theme, ThemePack pack) {
  final overrides = theme.brightness == Brightness.dark ? pack.palette.dark : pack.palette.light;
  final own = overrides[key];
  return own != null ? Color(own) : _defaultColor(key, theme, pack);
}

class ThemeStudioColorsSheet extends StatefulWidget {
  const ThemeStudioColorsSheet({super.key, required this.controller, this.startDark = false});

  final ThemeStudioController controller;
  final bool startDark;

  @override
  State<ThemeStudioColorsSheet> createState() => _ThemeStudioColorsSheetState();
}

class _ThemeStudioColorsSheetState extends State<ThemeStudioColorsSheet> {
  late bool _dark = widget.startDark;

  Future<void> _pick(String key, Color from) async {
    final picked = await showStudioColorPicker(context, initial: from);
    if (picked != null) widget.controller.setColor(key, picked, dark: _dark);
  }

  @override
  Widget build(BuildContext context) {
    final english = AppLocale.isEnglish;
    final theme = Theme.of(context);
    final known = {
      for (final (_, _, tokens) in _colorGroups)
        for (final token in tokens) token.key,
    };
    // Tokens the model gains later still get a row, under their own key.
    final rest = [
      for (final key in ThemeColorOverrides.tokenKeys)
        if (!known.contains(key)) (key: key, zh: key, en: key, useZh: '', useEn: ''),
    ];
    return Column(
      children: [
        SheetHeader(english ? 'All Colors' : '全部颜色'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SegmentedPill<bool>(
            segments: [PillSegment(false, english ? 'Light' : '浅色'), PillSegment(true, english ? 'Dark' : '深色')],
            selected: _dark,
            onChanged: (dark) => setState(() => _dark = dark),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            english
                ? 'Colours left empty follow the accent and material. The grey value is what is used now.'
                : '没填的颜色会跟着主色和材质走，灰色的色号就是现在用的。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, _) {
              final pack = widget.controller.pack;
              final resolved = studioThemeOf(pack, dark: _dark);
              final overrides = _dark ? pack.palette.dark : pack.palette.light;
              final mode = _dark ? 'dark' : 'light';
              return ListView(
                padding: EdgeInsets.fromLTRB(16, 0, 8, 24 + MediaQuery.viewInsetsOf(context).bottom),
                children: [
                  for (final (zh, en, tokens) in [..._colorGroups, if (rest.isNotEmpty) ('其它', 'Other', rest)]) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 4),
                      child: Text(
                        english ? en : zh,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    for (final token in tokens)
                      _ColorRow(
                        key: ValueKey('theme-color-row-$mode-${token.key}'),
                        id: '$mode-${token.key}',
                        name: english ? token.en : token.zh,
                        use: english ? token.useEn : token.useZh,
                        value: overrides[token.key],
                        fallback: _defaultColor(token.key, resolved, pack),
                        onChanged: (argb) => widget.controller.setColor(token.key, argb, dark: _dark),
                        onPick: (from) => unawaited(_pick(token.key, from)),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _ColorRow extends StatelessWidget {
  const _ColorRow({
    super.key,
    required this.id,
    required this.name,
    required this.use,
    required this.value,
    required this.fallback,
    required this.onChanged,
    required this.onPick,
  });

  final String id;
  final String name;
  final String use;
  final int? value;
  final Color? fallback;
  final ValueChanged<int?> onChanged;
  final ValueChanged<Color> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = value != null ? Color(value!) : fallback;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Semantics(
            button: true,
            label: AppLocale.isEnglish ? 'Pick $name' : '选择$name',
            child: InkResponse(
              key: ValueKey('theme-color-swatch-$id'),
              radius: 22,
              onTap: () => onPick(shown ?? scheme.primary),
              child: SizedBox.square(
                dimension: 32,
                // A colour of the pack's own fills the disc; one that is only followed sits small inside the ring.
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value != null ? shown : null,
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: value == null && shown != null
                      ? Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(color: shown, shape: BoxShape.circle),
                            child: const SizedBox.square(dimension: 14),
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: theme.textTheme.bodyMedium),
                if (use.isNotEmpty)
                  Text(use, style: theme.textTheme.bodySmall?.copyWith(color: DshColors.of(context).textTertiary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 128,
            child: StudioHexField(
              key: ValueKey('theme-color-$id'),
              value: value,
              onChanged: onChanged,
              hint: fallback == null ? '#RRGGBB' : formatThemeHexColor(fallback!.toARGB32()),
              dense: true,
            ),
          ),
          SizedBox.square(
            dimension: 40,
            child: value == null
                ? null
                : IconButton(
                    key: ValueKey('theme-color-clear-$id'),
                    tooltip: AppLocale.isEnglish ? 'Follow the default' : '恢复默认',
                    icon: Icon(AppIcons.clear, size: 18, color: scheme.onSurfaceVariant),
                    onPressed: () => onChanged(null),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A small picker over hue, lightness, chroma and opacity. Resolves to the ARGB picked, or null when dismissed.
/// [opacity] off is for a colour that has to stay solid.
Future<int?> showStudioColorPicker(BuildContext context, {required Color initial, bool opacity = true}) =>
    showAppSheet<int>(
      context,
      isScrollControlled: true,
      builder: (_) => _ColorPicker(initial: initial, opacity: opacity),
    );

class _ColorPicker extends StatefulWidget {
  const _ColorPicker({required this.initial, required this.opacity});

  final Color initial;
  final bool opacity;

  @override
  State<_ColorPicker> createState() => _ColorPickerState();
}

class _ColorPickerState extends State<_ColorPicker> {
  late Oklch _color = Oklch.fromColor(widget.initial);
  late double _alpha = widget.opacity ? widget.initial.a : 1;

  @override
  Widget build(BuildContext context) {
    final english = AppLocale.isEnglish;
    final theme = Theme.of(context);
    final color = _color.toColor(alpha: _alpha);
    final ink = ThemeData.estimateBrightnessForColor(color) == Brightness.dark && _alpha > 0.5
        ? Colors.white
        : theme.colorScheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetHeader(english ? 'Pick a Color' : '选颜色'),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: color,
                    shape: SquircleBorder(
                      borderRadius: AppShape.radiusMd,
                      side: BorderSide(color: theme.colorScheme.outlineVariant),
                    ),
                  ),
                  child: SizedBox(
                    height: 56,
                    child: Center(
                      child: Text(formatThemeHexColor(color.toARGB32()), style: AppType.mono(size: 14, color: ink)),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                HueSlider(
                  hue: _color.h,
                  brightness: theme.brightness,
                  onChanged: (hue) => setState(() => _color = _color.copyWith(h: hue)),
                ),
                const SizedBox(height: 6),
                StudioSlider(
                  label: english ? 'Lightness' : '明暗',
                  value: _color.l.clamp(0.0, 1.0).toDouble(),
                  min: 0,
                  max: 1,
                  step: 0.01,
                  fallback: _color.l.clamp(0.0, 1.0).toDouble(),
                  format: StudioSlider.percent,
                  onChanged: (v) => setState(() => _color = _color.copyWith(l: v)),
                ),
                StudioSlider(
                  label: english ? 'Vividness' : '鲜艳程度',
                  value: _color.c.clamp(0.0, 0.32).toDouble(),
                  min: 0,
                  max: 0.32,
                  step: 0.01,
                  fallback: _color.c.clamp(0.0, 0.32).toDouble(),
                  format: (v) => StudioSlider.percent(v / 0.32),
                  onChanged: (v) => setState(() => _color = _color.copyWith(c: v)),
                ),
                if (widget.opacity)
                  StudioSlider(
                    label: english ? 'Opacity' : '不透明度',
                    value: _alpha,
                    min: 0,
                    max: 1,
                    step: 0.01,
                    fallback: _alpha,
                    format: StudioSlider.percent,
                    onChanged: (v) => setState(() => _alpha = v ?? 1),
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(color.toARGB32()),
                  child: Text(english ? 'Use This Color' : '用这个颜色'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
