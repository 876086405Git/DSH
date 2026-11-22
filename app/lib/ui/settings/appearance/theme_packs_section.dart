// Theme pack management, live-preview visual Theme Studio creator,
// local PNG/font asset bundling, ZIP import/export, and Workshop entry.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../l10n/l10n.dart';
import '../../../state/appearance_state.dart';
import '../../../state/artifacts.dart' show filesChannelProvider;
import '../../../state/workshop_catalog_state.dart';
import '../../../themes/theme_library.dart';
import '../../../themes/theme_pack_validator.dart';
import '../../common/app_sheet.dart';
import '../../common/brief_notice.dart';
import '../../common/capsule_chip.dart';
import '../../common/list_page_row.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../../workshop/workshop_screen.dart';

final themePackPickerProvider = Provider<Future<File?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (picked == null) return null;
    final temp = File(
      '${(await getTemporaryDirectory()).path}/theme-import-${DateTime.now().microsecondsSinceEpoch}.zip',
    );
    final sink = temp.openWrite();
    try {
      await sink.addStream(picked.readAsByteStream());
    } finally {
      await sink.close();
    }
    return temp;
  },
);

Future<Uint8List?> _pickBoundedFile(List<String> extensions, int maxBytes) async {
  final picked = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: extensions,
  );
  if (picked == null) return null;
  final length = await picked.length();
  if (length != null && length > maxBytes) {
    throw const ThemeImportException(ThemeImportProblem.tooLarge);
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in picked.readAsByteStream()) {
    builder.add(chunk);
    if (builder.length > maxBytes) {
      throw const ThemeImportException(ThemeImportProblem.tooLarge);
    }
  }
  return builder.takeBytes();
}

String themeImportProblemText(ThemeImportException error, {required bool english}) =>
    switch (error.problem) {
      ThemeImportProblem.notAZip =>
        english ? 'Selected file is not a valid ZIP archive.' : '所选文件不是有效的 ZIP 压缩包。',
      ThemeImportProblem.noPack =>
        english ? 'No theme.json found in the archive.' : '压缩包中未找到 theme.json 清单。',
      ThemeImportProblem.badPack =>
        english
            ? 'Invalid theme.json (${error.detail ?? 'schema'}).'
            : '主题配置格式有误（${error.detail ?? 'schema'}）。',
      ThemeImportProblem.missingAsset =>
        english
            ? 'Missing referenced asset: ${error.detail ?? ''}.'
            : '缺少主题引用的素材文件：${error.detail ?? ''}。',
      ThemeImportProblem.badAsset =>
        english
            ? 'Invalid image or font asset: ${error.detail ?? ''}.'
            : '主题图片或字体素材无效：${error.detail ?? ''}。',
      ThemeImportProblem.tooLarge =>
        english ? 'Theme pack or asset exceeds size limits.' : '主题包或素材体积超出上限。',
      ThemeImportProblem.storage =>
        english ? 'Could not write theme pack to local storage.' : '无法写入本地存储。',
    };

class ThemePacksSection extends ConsumerStatefulWidget {
  const ThemePacksSection({super.key});

  @override
  ConsumerState<ThemePacksSection> createState() => _ThemePacksSectionState();
}

class _ThemePacksSectionState extends ConsumerState<ThemePacksSection> {
  bool _busy = false;

  Future<void> _selectPack(String? id) async {
    await ThemeRevealHost.run(
      context,
      () => ref.read(appearanceProvider.notifier).selectThemePack(id),
    );
  }

  Future<void> _importZip() async {
    if (_busy) return;
    final english = AppLocale.isEnglish;
    File? zip;
    setState(() => _busy = true);
    try {
      zip = await ref.read(themePackPickerProvider)();
      if (zip == null || !mounted) return;
      final (:id, :replaced) = await ref.read(themeLibraryProvider).install(
        zip,
        replaceExisting: true,
      );
      ref.invalidate(userThemesProvider);
      ref.invalidate(themePackByIdProvider(id));
      ref.invalidate(themeLoadedFontsProvider(id));
      if (!mounted) return;
      await _selectPack(id);
      if (!mounted) return;
      showBriefNotice(
        context,
        replaced
            ? (english ? 'Theme pack updated and applied.' : '主题包已更新并启用。')
            : (english ? 'Theme pack imported and applied.' : '主题包已导入并启用。'),
      );
    } on ThemeImportException catch (error) {
      if (mounted) {
        showBriefNotice(context, themeImportProblemText(error, english: english));
      }
    } on Object {
      if (mounted) {
        showBriefNotice(
          context,
          english ? 'Failed to import theme pack.' : '导入主题包失败。',
        );
      }
    } finally {
      if (zip != null) {
        unawaited(zip.delete().then((_) {}, onError: (_) {}));
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportZip(ThemePack pack) async {
    if (_busy) return;
    final english = AppLocale.isEnglish;
    setState(() => _busy = true);
    Directory? tempDir;
    try {
      final root = await getTemporaryDirectory();
      tempDir = await root.createTemp('dsh-theme-export-');
      final fileName = '${pack.publicId}.zip';
      final dest = File('${tempDir.path}/$fileName');
      await ref.read(themeLibraryProvider).exportZip(pack.id, dest, publicId: pack.publicId);
      final where = await ref.read(filesChannelProvider).saveToDownloads(
        dest.path,
        name: fileName,
        mime: 'application/zip',
      );
      if (!mounted) return;
      showBriefNotice(
        context,
        english ? 'Exported $fileName ($where)' : '已导出 $fileName（$where）',
      );
    } on ThemeImportException catch (error) {
      if (mounted) {
        showBriefNotice(context, themeImportProblemText(error, english: english));
      }
    } on Object {
      if (mounted) {
        showBriefNotice(
          context,
          english ? 'Failed to export theme pack.' : '导出主题包失败。',
        );
      }
    } finally {
      if (tempDir != null) {
        unawaited(tempDir.delete(recursive: true).then((_) {}, onError: (_) {}));
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removePack(ThemePack pack) async {
    final english = AppLocale.isEnglish;
    final activeId = ref.read(appearanceProvider).themePackId;
    await ref.read(themeLibraryProvider).remove(pack.id);
    ref.invalidate(userThemesProvider);
    ref.invalidate(themePackByIdProvider(pack.id));
    ref.invalidate(themeLoadedFontsProvider(pack.id));
    if (activeId == pack.id) {
      await ref.read(appearanceProvider.notifier).selectThemePack(null);
    }
    if (!mounted) return;
    showBriefNotice(
      context,
      english ? 'Removed "${pack.displayName('en')}".' : '已移除「${pack.displayName('zh')}」。',
    );
  }

  Future<void> _openStudio([ThemePack? initial, bool editing = false]) async {
    final existing = ref.read(userThemesProvider).value ?? const <ThemePack>[];
    final existingIds = {for (final t in existing) t.publicId};
    final saved = await showAppSheet<ThemePack>(
      context,
      isScrollControlled: true,
      builder: (_) => ThemeStudioSheet(
        initial: initial,
        editing: editing,
        existingIds: existingIds,
      ),
    );
    if (saved == null || !mounted) return;
    ref.invalidate(userThemesProvider);
    ref.invalidate(themePackByIdProvider(saved.id));
    ref.invalidate(themeLoadedFontsProvider(saved.id));
    await _selectPack(saved.id);
    if (!mounted) return;
    showBriefNotice(
      context,
      AppLocale.isEnglish
          ? 'Saved and applied "${saved.displayName('en')}".'
          : '已保存并启用「${saved.displayName('zh')}」。',
    );
  }

  @override
  Widget build(BuildContext context) {
    final english = AppLocale.isEnglish;
    final lang = english ? 'en' : 'zh';
    final activeId = ref.watch(appearanceProvider.select((s) => s.themePackId));
    final userThemes = ref.watch(userThemesProvider).value ?? const <ThemePack>[];
    final workshopAvailable = ref.watch(workshopAvailableProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListPageRow(
          key: const ValueKey('theme-pack-default'),
          icon: AppIcons.theme,
          title: english ? 'Mist Glass (Default)' : '晨雾玻璃（默认）',
          subtitle: english
              ? 'Translucent glass chrome with ambient hue glow'
              : '半透明磨砂玻璃与柔和环境光晕',
          trailing: activeId == null
              ? Icon(AppIcons.selected, size: 18, color: Theme.of(context).colorScheme.primary)
              : null,
          onTap: () => unawaited(_selectPack(null)),
        ),
        for (final pack in ThemePack.builtIns) ...[
          const SizedBox(height: 2),
          _ThemePackRow(
            key: ValueKey('theme-pack-${pack.id}'),
            pack: pack,
            languageCode: lang,
            selected: activeId == pack.id,
            onTap: () => unawaited(_selectPack(pack.id)),
            onCustomize: () => unawaited(_openStudio(pack)),
            onExport: () => unawaited(_exportZip(pack)),
          ),
        ],
        for (final pack in userThemes) ...[
          const SizedBox(height: 2),
          _ThemePackRow(
            key: ValueKey('theme-pack-${pack.id}'),
            pack: pack,
            languageCode: lang,
            selected: activeId == pack.id,
            onTap: () => unawaited(_selectPack(pack.id)),
            onCustomize: () => unawaited(_openStudio(pack, true)),
            onExport: () => unawaited(_exportZip(pack)),
            onDelete: () => unawaited(_removePack(pack)),
          ),
        ],
        const SizedBox(height: 2),
        ListPageRow(
          key: const ValueKey('theme-pack-studio'),
          icon: AppIcons.color,
          title: english ? 'Create Custom Theme Pack' : '自定义并创建主题包',
          subtitle: english
              ? 'Live preview · any color, surface, local font & artwork'
              : '实时预览 · 任意色号、材质、本地字体与背景/插画自由组合',
          chevron: true,
          onTap: () => unawaited(_openStudio(ref.read(activeThemePackProvider))),
        ),
        const SizedBox(height: 2),
        ListPageRow(
          key: const ValueKey('theme-pack-import'),
          icon: AppIcons.download,
          title: english ? 'Import Theme Pack (.zip)' : '导入主题包 (.zip)',
          subtitle: english
              ? 'Load a declarative theme.json archive with fonts or artwork'
              : '导入含 theme.json、自定义字体或插画的主题压缩包',
          onTap: _busy ? null : () => unawaited(_importZip()),
        ),
        if (workshopAvailable) ...[
          const SizedBox(height: 2),
          ListPageRow(
            key: const ValueKey('theme-pack-workshop'),
            icon: AppIcons.workshop,
            title: english ? 'Theme Workshop' : '主题创意工坊',
            subtitle: english
                ? 'Discover community themes or publish your own'
                : '浏览安装社区创作者的主题，或将你的作品投稿上架',
            chevron: true,
            onTap: () {
              ref.read(workshopCatalogProvider.notifier).setKind(WorkshopKindFilter.theme);
              unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const WorkshopScreen()),
                ),
              );
            },
          ),
        ],
      ],
    );
  }
}

enum _PackMenuAction { customize, exportZip, delete }

class _ThemePackRow extends StatelessWidget {
  const _ThemePackRow({
    super.key,
    required this.pack,
    required this.languageCode,
    required this.selected,
    required this.onTap,
    required this.onCustomize,
    required this.onExport,
    this.onDelete,
  });

  final ThemePack pack;
  final String languageCode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onCustomize;
  final VoidCallback onExport;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final accent = AppAccent.fromThemePack(pack);
    final seed = accent.seedFor(Theme.of(context).brightness);
    final bgOverride = dark ? pack.palette.dark.backdropTop : pack.palette.light.backdropTop;
    final bgDot = bgOverride != null
        ? Color(bgOverride)
        : (dark ? NeutralTones.forAccent(accent).night : NeutralTones.forAccent(accent).mist);
    final subtitle = pack.description.isNotEmpty
        ? pack.description
        : [
            pack.surfaces.preset.name,
            if (pack.typography.readingFont != 'system') pack.typography.readingFont,
            ...pack.tags,
          ].join(' · ');
    final english = languageCode == 'en';

    return ListPageRow(
      leading: SizedBox(
        width: 24,
        height: 24,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bgDot,
            shape: BoxShape.circle,
            border: Border.all(color: seed, width: 2.5),
          ),
          child: Center(
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: seed, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
      title: pack.displayName(languageCode),
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(AppIcons.selected, size: 18, color: scheme.primary),
            ),
          PopupMenuButton<_PackMenuAction>(
            icon: Icon(AppIcons.more, size: 18, color: scheme.onSurfaceVariant),
            tooltip: english ? 'More actions' : '更多操作',
            onSelected: (action) => switch (action) {
              _PackMenuAction.customize => onCustomize(),
              _PackMenuAction.exportZip => onExport(),
              _PackMenuAction.delete => onDelete?.call(),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _PackMenuAction.customize,
                child: Text(english ? 'Edit / Remix' : '以此为模板编辑'),
              ),
              PopupMenuItem(
                value: _PackMenuAction.exportZip,
                child: Text(english ? 'Export ZIP' : '导出主题包 (.zip)'),
              ),
              if (onDelete != null)
                PopupMenuItem(
                  value: _PackMenuAction.delete,
                  child: Text(
                    english ? 'Remove' : '移除主题包',
                    style: TextStyle(color: scheme.error),
                  ),
                ),
            ],
          ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Interactive visual Theme Studio with live preview, arbitrary hex colors,
/// and local PNG / TTF / OTF asset bundling into a valid schema-1 ThemePack.
class ThemeStudioSheet extends ConsumerStatefulWidget {
  const ThemeStudioSheet({
    super.key,
    this.initial,
    this.editing = false,
    this.existingIds = const {},
  });

  final ThemePack? initial;
  final bool editing;
  final Set<String> existingIds;

  @override
  ConsumerState<ThemeStudioSheet> createState() => _ThemeStudioSheetState();
}

class _ThemeStudioSheetState extends ConsumerState<ThemeStudioSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _idController;
  late final TextEditingController _descController;
  late final TextEditingController _seedHexController;
  late final TextEditingController _lightBgHexController;
  late final TextEditingController _darkBgHexController;
  late final TextEditingController _bubbleHexController;

  late int _seed;
  late double _tintHue;
  late double _tintChroma;
  late double _glowOpacity;
  late ThemeSurfacePreset _surfacePreset;
  late double _backdropOpacity;
  late bool _backdropRepeat;
  String? _backdropImage;
  late String _uiFont;
  late String _readingFont;
  late String _codeFont;
  late double _readingLineHeight;
  late double _cornerScale;
  late double _turnGap;
  late double _inTurnGap;
  late double _gutter;
  late ThemeHeaderStyle _headerStyle;
  late ThemeComposerStyle _composerStyle;
  late ThemeSendButtonStyle _sendButtonStyle;
  late ThemeUserBubbleStyle _userBubbleStyle;
  late ThemeAssistantStyle _assistantStyle;
  late bool _useReadingFontForReply;
  late ThemeSuggestionCardStyle _suggestionCardStyle;
  late ThemeCodeBlockStyle _codeBlockStyle;
  late ThemeEmptyLayout _emptyLayout;
  late ThemeHeroStyle _heroStyle;
  String? _heroImage;
  late bool _useReadingFontForGreeting;
  late bool _showConnectedSubtitle;
  late ThemeSuggestionsDisplay _suggestionsDisplay;
  late String _initialLightBgHex;
  late String _initialDarkBgHex;
  late String _initialBubbleHex;
  late String _initialReadingFont;
  late ThemeSurfacePreset _initialSurfacePreset;

  final Map<String, Uint8List> _pickedAssets = {};
  bool _previewDark = false;
  bool _saving = false;
  String? _error;

  static const _seedSwatches = <(int, String, String, double)>[
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

  @override
  void initState() {
    super.initState();
    final base = widget.initial ?? ThemePack.paper;
    String nextAvailableId(String stem) {
      final baseStem = stem.length > 30 ? stem.substring(0, 30).replaceAll(RegExp(r'-+$'), '') : stem;
      var candidate = '$baseStem-custom';
      var seq = 2;
      while (widget.existingIds.contains(candidate) || ThemePack.builtInById(candidate) != null) {
        candidate = '$baseStem-custom-$seq';
        seq++;
      }
      return candidate;
    }

    _nameController = TextEditingController(
      text: widget.editing ? base.name : '${base.name} · 自定义',
    );
    _idController = TextEditingController(
      text: widget.editing ? base.publicId : nextAvailableId(base.publicId),
    );
    _descController = TextEditingController(text: base.description);
    _seed = base.palette.seed;
    _seedHexController = TextEditingController(text: formatThemeHexColor(_seed));
    _initialLightBgHex = base.palette.light.backdropTop != null
        ? formatThemeHexColor(base.palette.light.backdropTop!)
        : '';
    _initialDarkBgHex = base.palette.dark.backdropTop != null
        ? formatThemeHexColor(base.palette.dark.backdropTop!)
        : '';
    _initialBubbleHex = base.palette.light.userBubble != null
        ? formatThemeHexColor(base.palette.light.userBubble!)
        : '';
    _initialReadingFont = base.typography.readingFont;
    _initialSurfacePreset = base.surfaces.preset;
    _lightBgHexController = TextEditingController(text: _initialLightBgHex);
    _darkBgHexController = TextEditingController(text: _initialDarkBgHex);
    _bubbleHexController = TextEditingController(text: _initialBubbleHex);
    _tintHue = base.palette.tintHue ?? 74;
    _tintChroma = base.palette.tintChroma;
    _glowOpacity = base.palette.glowOpacity;
    _surfacePreset = base.surfaces.preset;
    _backdropImage = base.surfaces.backdropImage;
    _backdropOpacity = base.surfaces.backdropOpacity;
    _backdropRepeat = base.surfaces.backdropRepeat;
    _uiFont = base.typography.uiFont;
    _readingFont = base.typography.readingFont;
    _codeFont = base.typography.codeFont;
    _readingLineHeight = base.typography.readingLineHeight;
    _cornerScale = base.shapes.cornerScale;
    _turnGap = base.shapes.turnGap;
    _inTurnGap = base.shapes.inTurnGap;
    _gutter = base.shapes.gutter;
    _headerStyle = base.components.headerStyle;
    _composerStyle = base.components.composerStyle;
    _sendButtonStyle = base.components.sendButtonStyle;
    _userBubbleStyle = base.components.userBubbleStyle;
    _assistantStyle = base.components.assistantStyle;
    _useReadingFontForReply = base.components.useReadingFontForReply;
    _suggestionCardStyle = base.components.suggestionCardStyle;
    _codeBlockStyle = base.components.codeBlockStyle;
    _emptyLayout = base.emptyState.layout;
    _heroStyle = base.emptyState.heroStyle;
    _heroImage = base.emptyState.heroImage;
    if (_heroStyle == ThemeHeroStyle.customImage && _heroImage == null) {
      _heroStyle = ThemeHeroStyle.badge;
    }
    _useReadingFontForGreeting = base.emptyState.useReadingFontForGreeting;
    _showConnectedSubtitle = base.emptyState.showConnectedSubtitle;
    _suggestionsDisplay = base.emptyState.suggestionsDisplay;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    _descController.dispose();
    _seedHexController.dispose();
    _lightBgHexController.dispose();
    _darkBgHexController.dispose();
    _bubbleHexController.dispose();
    super.dispose();
  }

  ThemePack _buildDraftPack({required String id, required String name}) {
    final base = widget.initial ?? ThemePack.paper;
    final lightBgText = _lightBgHexController.text.trim();
    final darkBgText = _darkBgHexController.text.trim();
    final bubbleText = _bubbleHexController.text.trim();
    final lightBgEdited = lightBgText != _initialLightBgHex;
    final darkBgEdited = darkBgText != _initialDarkBgHex;
    final bubbleEdited = bubbleText != _initialBubbleHex;
    final surfacePresetEdited = _surfacePreset != _initialSurfacePreset;
    final readingFontEdited = _readingFont != _initialReadingFont;
    final lightBg = parseThemeHexColor(lightBgText);
    final darkBg = parseThemeHexColor(darkBgText);
    final lightBubble = parseThemeHexColor(bubbleText);
    final isPaper = _surfacePreset == ThemeSurfacePreset.paper;
    final baseLight = base.palette.light;
    final baseDark = base.palette.dark;
    final seedEdited = _seed != base.palette.seed;

    return ThemePack(
      id: id,
      name: name,
      titleZh: widget.editing && name == base.name ? base.titleZh : name,
      titleEn: widget.editing && name == base.name ? base.titleEn : name,
      description: _descController.text.trim(),
      tags: widget.editing && base.tags.isNotEmpty
          ? base.tags
          : [
              _surfacePreset.name,
              if (_readingFont != 'system' && !ThemeTypographySpec.isCustomFontAsset(_readingFont)) _readingFont,
              if (_backdropImage != null) 'wallpaper',
            ],
      author: widget.editing ? base.author : null,
      license: widget.editing ? base.license : null,
      source: widget.editing ? base.source : null,
      folderPath: base.folderPath,
      palette: ThemePaletteSpec(
        seed: _seed,
        seedDark: seedEdited ? null : base.palette.seedDark,
        tintHue: _tintHue,
        tintChroma: _tintChroma,
        glowOpacity: _glowOpacity,
        light: ThemeColorOverrides(
          backdropTop: lightBgEdited
              ? lightBg
              : (baseLight.backdropTop ?? (isPaper ? 0xFFF7F4EC : null)),
          backdropBottom: lightBgEdited
              ? lightBg
              : (baseLight.backdropBottom ?? (isPaper ? 0xFFF5F1E7 : null)),
          glowPrimary: baseLight.glowPrimary,
          glowSecondary: baseLight.glowSecondary,
          surface: baseLight.surface,
          onSurface: baseLight.onSurface,
          onSurfaceVariant: baseLight.onSurfaceVariant,
          outline: baseLight.outline,
          outlineVariant: baseLight.outlineVariant,
          primary: seedEdited ? null : baseLight.primary,
          onPrimary: baseLight.onPrimary,
          primaryContainer: baseLight.primaryContainer,
          onPrimaryContainer: baseLight.onPrimaryContainer,
          userBubble: bubbleEdited
              ? lightBubble
              : (baseLight.userBubble ?? (isPaper ? 0xFFECE8E2 : null)),
          onUserBubble: bubbleEdited
              ? (lightBubble != null
                  ? (ThemeData.estimateBrightnessForColor(Color(lightBubble)) == Brightness.dark
                      ? 0xFFF7F7F7
                      : 0xFF1F1E1B)
                  : null)
              : (baseLight.onUserBubble ?? (isPaper ? 0xFF1F1E1B : null)),
          assistantBubble: baseLight.assistantBubble,
          onAssistantBubble: baseLight.onAssistantBubble,
          codeWellBg: baseLight.codeWellBg,
          codeWellHeader: baseLight.codeWellHeader,
          codeWellFg: baseLight.codeWellFg,
          codeWellBorder: baseLight.codeWellBorder,
        ),
        dark: ThemeColorOverrides(
          backdropTop: darkBgEdited
              ? darkBg
              : (baseDark.backdropTop ?? (isPaper ? 0xFF181614 : null)),
          backdropBottom: darkBgEdited
              ? darkBg
              : (baseDark.backdropBottom ?? (isPaper ? 0xFF161412 : null)),
          glowPrimary: baseDark.glowPrimary,
          glowSecondary: baseDark.glowSecondary,
          surface: baseDark.surface,
          onSurface: baseDark.onSurface,
          onSurfaceVariant: baseDark.onSurfaceVariant,
          outline: baseDark.outline,
          outlineVariant: baseDark.outlineVariant,
          primary: seedEdited ? null : baseDark.primary,
          onPrimary: baseDark.onPrimary,
          primaryContainer: baseDark.primaryContainer,
          onPrimaryContainer: baseDark.onPrimaryContainer,
          userBubble: baseDark.userBubble ?? (isPaper ? 0xFF2F2A25 : null),
          onUserBubble: baseDark.onUserBubble ?? (isPaper ? 0xFFECE9E2 : null),
          assistantBubble: baseDark.assistantBubble,
          onAssistantBubble: baseDark.onAssistantBubble,
          codeWellBg: baseDark.codeWellBg,
          codeWellHeader: baseDark.codeWellHeader,
          codeWellFg: baseDark.codeWellFg,
          codeWellBorder: baseDark.codeWellBorder,
        ),
      ),
      surfaces: ThemeSurfaceSpec(
        preset: _surfacePreset,
        chromeBlur: surfacePresetEdited ? null : base.surfaces.chromeBlur,
        sheetBlur: surfacePresetEdited ? null : base.surfaces.sheetBlur,
        cardOpacity: surfacePresetEdited ? null : base.surfaces.cardOpacity,
        pillOpacity: surfacePresetEdited ? null : base.surfaces.pillOpacity,
        hairlineWidth: surfacePresetEdited
            ? (isPaper || _surfacePreset == ThemeSurfacePreset.outlined ? 1.0 : 0.6)
            : base.surfaces.hairlineWidth,
        rimOpacity: surfacePresetEdited ? null : base.surfaces.rimOpacity,
        shadowOpacity: surfacePresetEdited ? null : base.surfaces.shadowOpacity,
        backdropImage: _backdropImage,
        backdropOpacity: _backdropOpacity,
        backdropRepeat: _backdropRepeat,
      ),
      typography: ThemeTypographySpec(
        uiFont: _uiFont,
        readingFont: _readingFont,
        headingFont: readingFontEdited ? _readingFont : base.typography.headingFont,
        codeFont: _codeFont,
        readingScale: base.typography.readingScale,
        readingLineHeight: _readingLineHeight,
        headingScale: _useReadingFontForGreeting != base.emptyState.useReadingFontForGreeting
            ? (_useReadingFontForGreeting ? 1.12 : 1.0)
            : base.typography.headingScale,
      ),
      shapes: ThemeShapeSpec(
        cornerScale: _cornerScale,
        borderWidth: surfacePresetEdited
            ? (isPaper || _surfacePreset == ThemeSurfacePreset.outlined ? 1.0 : 0.6)
            : base.shapes.borderWidth,
        turnGap: _turnGap,
        inTurnGap: _inTurnGap,
        gutter: _gutter,
      ),
      components: ThemeComponentSpec(
        headerStyle: _headerStyle,
        composerStyle: _composerStyle,
        sendButtonStyle: _sendButtonStyle,
        userBubbleStyle: _userBubbleStyle,
        assistantStyle: _assistantStyle,
        useReadingFontForReply: _useReadingFontForReply,
        suggestionCardStyle: _suggestionCardStyle,
        codeBlockStyle: _codeBlockStyle,
      ),
      emptyState: ThemeEmptyStateSpec(
        layout: _emptyLayout,
        heroStyle: _heroStyle,
        heroImage: _heroStyle == ThemeHeroStyle.customImage ? _heroImage : null,
        useReadingFontForGreeting: _useReadingFontForGreeting,
        showConnectedSubtitle: _showConnectedSubtitle,
        suggestionsDisplay: _suggestionsDisplay,
      ),
    );
  }

  Future<void> _pickPngAsset({required bool isBackdrop}) async {
    final english = AppLocale.isEnglish;
    try {
      final bytes = await _pickBoundedFile(const ['png'], themeImageByteCap);
      if (bytes == null || !mounted) return;
      final fileName = isBackdrop ? 'backdrop.png' : 'hero.png';
      // Pre-validate PNG bytes via ThemePackValidator rules before keeping.
      ThemePackValidator.validateParts(
        ThemePack(
          id: 'preview-check',
          name: 'Check',
          surfaces: isBackdrop ? ThemeSurfaceSpec(backdropImage: fileName) : const ThemeSurfaceSpec(),
          emptyState: isBackdrop
              ? const ThemeEmptyStateSpec()
              : ThemeEmptyStateSpec(heroStyle: ThemeHeroStyle.customImage, heroImage: fileName),
        ).toJson(),
        {fileName: bytes},
      );
      setState(() {
        _error = null;
        _pickedAssets[fileName] = bytes;
        if (isBackdrop) {
          _backdropImage = fileName;
        } else {
          _heroImage = fileName;
          _heroStyle = ThemeHeroStyle.customImage;
        }
      });
    } on ThemeValidationException catch (e) {
      if (mounted) {
        setState(() => _error = english ? 'Invalid PNG (${e.code})' : 'PNG 图片校验未通过（${e.code}）');
      }
    } on ThemeImportException catch (e) {
      if (mounted) setState(() => _error = themeImportProblemText(e, english: english));
    } on Object {
      if (mounted) setState(() => _error = english ? 'Could not read image.' : '读取图片失败。');
    }
  }

  Future<void> _pickFontAsset() async {
    final english = AppLocale.isEnglish;
    try {
      final bytes = await _pickBoundedFile(const ['ttf', 'otf'], themeFontByteCap);
      if (bytes == null || !mounted) return;
      if (!isValidThemeFontBytes(bytes)) {
        setState(() => _error = english ? 'Not a valid TTF/OTF font.' : '不是有效的 TTF/OTF 字体文件。');
        return;
      }
      final isOtf = bytes.length >= 4 && String.fromCharCodes(bytes.sublist(0, 4)) == 'OTTO';
      final fileName = isOtf ? 'reading.otf' : 'reading.ttf';
      setState(() {
        _error = null;
        _pickedAssets[fileName] = bytes;
        _readingFont = fileName;
        _useReadingFontForReply = true;
      });
    } on ThemeImportException catch (e) {
      if (mounted) setState(() => _error = themeImportProblemText(e, english: english));
    } on Object {
      if (mounted) setState(() => _error = english ? 'Could not read font.' : '读取字体失败。');
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final english = AppLocale.isEnglish;
    final name = _nameController.text.trim();
    final rawId = _idController.text.trim().toLowerCase();
    if (name.isEmpty) {
      setState(() => _error = english ? 'Please enter a theme name.' : '请填写主题名称。');
      return;
    }
    if (!isValidThemeId(rawId) || ThemePack.builtInById(rawId) != null) {
      setState(
        () => _error = english
            ? 'ID must be lower-case letters/digits/hyphens and not a built-in ID.'
            : '主题 ID 需为小写字母、数字和连字符，且不能与内置 ID 重名。',
      );
      return;
    }
    for (final (label, text) in [
      (english ? 'Primary Hex' : '主色色号', _seedHexController.text.trim()),
      (english ? 'Light Backdrop Hex' : '浅色背景色号', _lightBgHexController.text.trim()),
      (english ? 'Dark Backdrop Hex' : '深色背景色号', _darkBgHexController.text.trim()),
      (english ? 'User Bubble Hex' : '气泡底色色号', _bubbleHexController.text.trim()),
    ]) {
      if (text.isNotEmpty && parseThemeHexColor(text) == null) {
        setState(() => _error = english ? '$label must be #RRGGBB.' : '$label 需为 #RRGGBB 格式。');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    final editingSameId = widget.editing && widget.initial != null && rawId == widget.initial!.publicId;
    if (!editingSameId && widget.existingIds.contains(rawId)) {
      setState(
        () => _error = english
            ? 'A theme with ID "$rawId" already exists. Pick a different ID.'
            : '主题 ID「$rawId」已存在，请换一个 ID 以免覆盖原主题。',
      );
      return;
    }
    try {
      final pack = _buildDraftPack(id: rawId, name: name);
      final saved = await ref.read(themeLibraryProvider).saveCustom(
        pack,
        assets: _pickedAssets,
        allowOverwrite: editingSameId,
        editingLocalId: editingSameId ? widget.initial!.id : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } on ThemeImportException catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = themeImportProblemText(error, english: english);
        });
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  Widget _groupTitle(String title) => Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 8),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    ),
  );

  Widget _choices<T>(List<(T, String)> items, T current, ValueChanged<T> onPick) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final (val, label) in items)
        CapsuleChoiceChip(
          label: label,
          selected: current == val,
          onSelected: () => setState(() => onPick(val)),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final english = AppLocale.isEnglish;
    final theme = Theme.of(context);
    final draft = _buildDraftPack(id: 'draft-preview', name: _nameController.text.trim().isEmpty ? 'Preview' : _nameController.text.trim());
    final previewAccent = AppAccent.fromThemePack(draft);
    final previewTheme = _previewDark
        ? buildDarkTheme(accent: previewAccent, themePack: draft)
        : buildLightTheme(accent: previewAccent, themePack: draft);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SheetHeader(
          english ? 'Theme Studio' : '主题工坊创作器',
          actions: [
            TextButton(
              onPressed: () => setState(() => _previewDark = !_previewDark),
              child: Text(
                _previewDark
                    ? (english ? 'Dark' : '深色')
                    : (english ? 'Light' : '浅色'),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: _ThemeMiniPreview(
            themeData: previewTheme,
            backdropBytes: _backdropImage != null ? _pickedAssets[_backdropImage!] : null,
            english: english,
          ),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const ValueKey('theme-studio-name'),
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: english ? 'Theme Name' : '主题名称',
                    hintText: english ? 'e.g. Warm Paper' : '例如：松烟纸墨',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('theme-studio-id'),
                  controller: _idController,
                  decoration: InputDecoration(
                    labelText: english ? 'Theme ID (kebab-case)' : '主题 ID（小写字母与连字符）',
                    hintText: 'warm-paper',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const ValueKey('theme-studio-description'),
                  controller: _descController,
                  decoration: InputDecoration(
                    labelText: english ? 'Summary (optional)' : '风格简介（可选）',
                  ),
                ),
                _groupTitle(english ? '1. Colors & Custom Hex' : '1. 主色、自定义色号与光晕'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (rgb, zh, en, hue) in _seedSwatches)
                      CapsuleChoiceChip(
                        label: english ? en : zh,
                        selected: _seed == rgb,
                        onSelected: () => setState(() {
                          _seed = rgb;
                          _tintHue = hue;
                          _seedHexController.text = formatThemeHexColor(rgb);
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('theme-studio-seed-hex'),
                        controller: _seedHexController,
                        decoration: InputDecoration(
                          labelText: english ? 'Primary #RRGGBB' : '自定义主色 #RRGGBB',
                          prefixIcon: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(color: Color(_seed), shape: BoxShape.circle),
                            ),
                          ),
                        ),
                        onChanged: (value) {
                          final parsed = parseThemeHexColor(value);
                          if (parsed != null) setState(() => _seed = parsed);
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('theme-studio-bubble-hex'),
                        controller: _bubbleHexController,
                        decoration: InputDecoration(
                          labelText: english ? 'Bubble #RRGGBB' : '用户气泡色（选填）',
                          hintText: '#ECE8E2',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('theme-studio-light-bg-hex'),
                        controller: _lightBgHexController,
                        decoration: InputDecoration(
                          labelText: english ? 'Light Page #RRGGBB' : '浅色底色（选填）',
                          hintText: '#F7F4EC',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: const ValueKey('theme-studio-dark-bg-hex'),
                        controller: _darkBgHexController,
                        decoration: InputDecoration(
                          labelText: english ? 'Dark Page #RRGGBB' : '深色底色（选填）',
                          hintText: '#181614',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _choices<double>(
                  [
                    (0.0, english ? 'No Glow' : '无光晕（纯纸面）'),
                    (0.45, english ? 'Soft Glow' : '微弱柔光'),
                    (1.0, english ? 'Full Glow' : '完整环境光晕'),
                  ],
                  _glowOpacity,
                  (v) => _glowOpacity = v,
                ),
                _groupTitle(english ? '2. Surface Material & Backdrop Texture' : '2. 表面材质与包内背景/肌理'),
                _choices<ThemeSurfacePreset>(
                  [
                    (ThemeSurfacePreset.glass, english ? 'Frosted Glass' : '磨砂玻璃'),
                    (ThemeSurfacePreset.paper, english ? 'Solid Paper' : '实心纸面'),
                    (ThemeSurfacePreset.flat, english ? 'Flat Minimal' : '纯平极简'),
                    (ThemeSurfacePreset.outlined, english ? 'Wireframe Outlined' : '高对比线框'),
                  ],
                  _surfacePreset,
                  (v) => _surfacePreset = v,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(AppIcons.image, size: 16),
                      label: Text(
                        _backdropImage == null
                            ? (english ? 'Bundle Backdrop PNG' : '选择背景/肌理 PNG')
                            : (english ? 'Backdrop: $_backdropImage' : '已选背景：$_backdropImage'),
                      ),
                      onPressed: () => unawaited(_pickPngAsset(isBackdrop: true)),
                    ),
                    if (_backdropImage != null) ...[
                      CapsuleChoiceChip(
                        label: english ? 'Tile Repeat' : '无缝平铺底纹',
                        selected: _backdropRepeat,
                        onSelected: () => setState(() => _backdropRepeat = !_backdropRepeat),
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          _pickedAssets.remove(_backdropImage);
                          _backdropImage = null;
                        }),
                        child: Text(english ? 'Clear' : '清除背景图'),
                      ),
                    ],
                  ],
                ),
                if (_backdropImage != null)
                  Row(
                    children: [
                      Text(
                        english
                            ? 'Opacity ${(_backdropOpacity * 100).round()}%'
                            : '背景图不透明度 ${(_backdropOpacity * 100).round()}%',
                        style: theme.textTheme.bodySmall,
                      ),
                      Expanded(
                        child: Slider(
                          value: _backdropOpacity,
                          min: 0.05,
                          max: 1.0,
                          onChanged: (v) => setState(() => _backdropOpacity = v),
                        ),
                      ),
                    ],
                  ),
                _groupTitle(english ? '3. Typography & Local Font' : '3. 字体角色、行高与自带字体'),
                _choices<String>(
                  [
                    ('system', english ? 'Reply: System Sans' : '回复：系统无衬线'),
                    ('serif', english ? 'Reply: Book Serif' : '回复：书卷衬线'),
                    ('mono', english ? 'Reply: Code Mono' : '回复：极客等宽'),
                  ],
                  ThemeTypographySpec.isCustomFontAsset(_readingFont) ? '' : _readingFont,
                  (v) {
                    _readingFont = v;
                    _useReadingFontForReply = v != 'system';
                    _useReadingFontForGreeting = v == 'serif';
                  },
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(AppIcons.files, size: 16),
                      label: Text(
                        ThemeTypographySpec.isCustomFontAsset(_readingFont)
                            ? (english ? 'Font: $_readingFont' : '已打包字体：$_readingFont')
                            : (english ? 'Bundle TTF/OTF Font' : '导入本地 .ttf/.otf 字体'),
                      ),
                      onPressed: () => unawaited(_pickFontAsset()),
                    ),
                    if (ThemeTypographySpec.isCustomFontAsset(_readingFont))
                      TextButton(
                        onPressed: () => setState(() {
                          _pickedAssets.remove(_readingFont);
                          _readingFont = 'system';
                          _useReadingFontForReply = false;
                        }),
                        child: Text(english ? 'Use System' : '改回系统字体'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                _choices<double>(
                  [
                    (1.45, english ? 'Compact Line (1.45)' : '紧凑行高 (1.45)'),
                    (1.55, english ? 'Standard Line (1.55)' : '标准行高 (1.55)'),
                    (1.68, english ? 'Book Line (1.68)' : '书卷舒展 (1.68)'),
                  ],
                  _readingLineHeight,
                  (v) => _readingLineHeight = v,
                ),
                _groupTitle(english ? '4. Corner Geometry & Spacing' : '4. 圆角几何与对话间距'),
                _choices<double>(
                  [
                    (0.28, english ? 'Sharp (0.28x)' : '硬朗终端 (0.28x)'),
                    (0.85, english ? 'Bookish (0.85x)' : '书卷微圆 (0.85x)'),
                    (1.0, english ? 'Standard (1.0x)' : '经典连续 (1.0x)'),
                    (1.32, english ? 'Soft Cloud (1.32x)' : '云朵大圆角 (1.32x)'),
                  ],
                  _cornerScale,
                  (v) => _cornerScale = v,
                ),
                const SizedBox(height: 8),
                _choices<double>(
                  [
                    (16.0, english ? 'Density: Compact' : '间距：紧凑'),
                    (24.0, english ? 'Density: Standard' : '间距：标准'),
                    (30.0, english ? 'Density: Airy' : '间距：舒展'),
                  ],
                  _turnGap,
                  (v) {
                    _turnGap = v;
                    _inTurnGap = v <= 18 ? 6.0 : (v >= 28 ? 10.0 : 8.0);
                    _gutter = v <= 18 ? 14.0 : 16.0;
                  },
                ),
                _groupTitle(english ? '5. Header, Composer, Bubbles & Code' : '5. 顶栏、输入框、消息与代码块'),
                _choices<ThemeHeaderStyle>(
                  [
                    (ThemeHeaderStyle.glass, english ? 'Header: Glass' : '顶栏：玻璃'),
                    (ThemeHeaderStyle.ghost, english ? 'Header: Ghost' : '顶栏：透明无框'),
                    (ThemeHeaderStyle.outlined, english ? 'Header: Outlined' : '顶栏：细线框'),
                    (ThemeHeaderStyle.minimal, english ? 'Header: Minimal' : '顶栏：柔和实底'),
                  ],
                  _headerStyle,
                  (v) => _headerStyle = v,
                ),
                const SizedBox(height: 8),
                _choices<ThemeComposerStyle>(
                  [
                    (ThemeComposerStyle.floatingGlass, english ? 'Input: Glass' : '输入框：玻璃'),
                    (ThemeComposerStyle.solidPaper, english ? 'Input: Solid Paper' : '输入框：实心纸面'),
                    (ThemeComposerStyle.outlined, english ? 'Input: Outlined' : '输入框：线框'),
                  ],
                  _composerStyle,
                  (v) => _composerStyle = v,
                ),
                const SizedBox(height: 8),
                _choices<ThemeSendButtonStyle>(
                  [
                    (ThemeSendButtonStyle.primary, english ? 'Key: Accent' : '按键：主色'),
                    (ThemeSendButtonStyle.ink, english ? 'Key: Ink Contrast' : '按键：深墨反白'),
                    (ThemeSendButtonStyle.tonal, english ? 'Key: Soft Tonal' : '按键：柔和容器'),
                  ],
                  _sendButtonStyle,
                  (v) => _sendButtonStyle = v,
                ),
                const SizedBox(height: 8),
                _choices<ThemeUserBubbleStyle>(
                  [
                    (ThemeUserBubbleStyle.soft, english ? 'User: Soft' : '用户：软气泡'),
                    (ThemeUserBubbleStyle.outlined, english ? 'User: Outlined' : '用户：细框信笺'),
                    (ThemeUserBubbleStyle.accent, english ? 'User: Accent' : '用户：主色容器'),
                    (ThemeUserBubbleStyle.minimal, english ? 'User: Right Rule' : '用户：右侧竖线'),
                  ],
                  _userBubbleStyle,
                  (v) => _userBubbleStyle = v,
                ),
                const SizedBox(height: 8),
                _choices<ThemeAssistantStyle>(
                  [
                    (ThemeAssistantStyle.plain, english ? 'AI: Plain' : '助手：无框裸排'),
                    (ThemeAssistantStyle.card, english ? 'AI: Book Card' : '助手：独立卡片'),
                    (ThemeAssistantStyle.leftRule, english ? 'AI: Left Rule' : '助手：左侧引线'),
                  ],
                  _assistantStyle,
                  (v) => _assistantStyle = v,
                ),
                const SizedBox(height: 8),
                _choices<ThemeCodeBlockStyle>(
                  [
                    (ThemeCodeBlockStyle.well, english ? 'Code: Well' : '代码：代码井'),
                    (ThemeCodeBlockStyle.outlined, english ? 'Code: Outlined' : '代码：通透线框'),
                    (ThemeCodeBlockStyle.card, english ? 'Code: Card' : '代码：柔和卡片'),
                  ],
                  _codeBlockStyle,
                  (v) => _codeBlockStyle = v,
                ),
                _groupTitle(english ? '6. Empty State & Artwork' : '6. 新对话页版式与插画'),
                _choices<ThemeEmptyLayout>(
                  [
                    (ThemeEmptyLayout.centered, english ? 'Centered' : '居中对称'),
                    (ThemeEmptyLayout.editorial, english ? 'Editorial Left' : '书卷左对齐'),
                    (ThemeEmptyLayout.compact, english ? 'Compact' : '紧凑布局'),
                  ],
                  _emptyLayout,
                  (v) => _emptyLayout = v,
                ),
                const SizedBox(height: 8),
                _choices<ThemeHeroStyle>(
                  [
                    (ThemeHeroStyle.whale, english ? 'Hero: Whale' : '徽标：鲸尾'),
                    (ThemeHeroStyle.badge, english ? 'Hero: Stamp' : '徽标：方章'),
                    (ThemeHeroStyle.hidden, english ? 'Hero: Hidden' : '徽标：隐藏'),
                  ],
                  _heroStyle == ThemeHeroStyle.customImage ? ThemeHeroStyle.badge : _heroStyle,
                  (v) => _heroStyle = v,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(AppIcons.image, size: 16),
                      label: Text(
                        _heroStyle == ThemeHeroStyle.customImage && _heroImage != null
                            ? (english ? 'Hero PNG: $_heroImage' : '已选头图：$_heroImage')
                            : (english ? 'Bundle Hero PNG' : '自定义新对话页插画 PNG'),
                      ),
                      onPressed: () => unawaited(_pickPngAsset(isBackdrop: false)),
                    ),
                    if (_heroStyle == ThemeHeroStyle.customImage && _heroImage != null)
                      TextButton(
                        onPressed: () => setState(() {
                          _pickedAssets.remove(_heroImage);
                          _heroImage = null;
                          _heroStyle = ThemeHeroStyle.badge;
                        }),
                        child: Text(english ? 'Clear' : '清除插画'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                _choices<ThemeSuggestionsDisplay>(
                  [
                    (ThemeSuggestionsDisplay.expanded, english ? 'Suggestions: Expanded' : '建议卡：展开'),
                    (ThemeSuggestionsDisplay.grid, english ? 'Suggestions: 2-Col Grid' : '建议卡：双列网格'),
                    (ThemeSuggestionsDisplay.collapsible, english ? 'Suggestions: Collapsible' : '建议卡：折叠快速上手'),
                  ],
                  _suggestionsDisplay,
                  (v) {
                    _suggestionsDisplay = v;
                    _showConnectedSubtitle = v != ThemeSuggestionsDisplay.collapsible;
                    if (v == ThemeSuggestionsDisplay.collapsible) {
                      _suggestionCardStyle = ThemeSuggestionCardStyle.paper;
                    }
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  key: const ValueKey('theme-studio-save'),
                  onPressed: _saving ? null : () => unawaited(_save()),
                  child: Text(
                    english ? 'Save & Apply Theme Pack' : '保存并启用主题包',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact live miniature chat preview rendered directly with the draft ThemeData.
class _ThemeMiniPreview extends StatelessWidget {
  const _ThemeMiniPreview({
    required this.themeData,
    required this.english,
    this.backdropBytes,
  });

  final ThemeData themeData;
  final bool english;
  final Uint8List? backdropBytes;

  @override
  Widget build(BuildContext context) {
    final surfaces = themeData.extension<DshSurfaces>()!;
    final style = themeData.extension<DshThemeStyle>()!;
    final dsh = themeData.extension<DshColors>()!;
    final scheme = themeData.colorScheme;
    final rMd = style.scaleRadius(AppShape.md);
    final rLg = style.scaleRadius(AppShape.lg);
    final userBg = switch (style.components.userBubbleStyle) {
      ThemeUserBubbleStyle.accent => scheme.primaryContainer,
      ThemeUserBubbleStyle.minimal => Colors.transparent,
      ThemeUserBubbleStyle.outlined => surfaces.userBubble.withValues(alpha: 0.72),
      ThemeUserBubbleStyle.soft => surfaces.userBubble,
    };
    final userFg = switch (style.components.userBubbleStyle) {
      ThemeUserBubbleStyle.accent => scheme.onPrimaryContainer,
      ThemeUserBubbleStyle.minimal => scheme.onSurface,
      _ => surfaces.onUserBubble,
    };
    final aiTextBase = (themeData.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(
      color: style.onAssistantBubble ?? scheme.onSurface,
    );
    final aiTextStyle = style.components.useReadingFontForReply
        ? style.readingTextStyle(aiTextBase).copyWith(fontSize: 12 * style.typography.readingScale)
        : aiTextBase;
    final keyBg = switch (style.components.sendButtonStyle) {
      ThemeSendButtonStyle.ink => scheme.onSurface,
      ThemeSendButtonStyle.tonal => scheme.primaryContainer,
      ThemeSendButtonStyle.primary => scheme.primary,
    };
    final keyFg = switch (style.components.sendButtonStyle) {
      ThemeSendButtonStyle.ink => scheme.surface,
      ThemeSendButtonStyle.tonal => scheme.onPrimaryContainer,
      ThemeSendButtonStyle.primary => scheme.onPrimary,
    };

    Widget aiBlock = Text(
      english ? 'Typography & surfaces update live as you tune.' : '字体、材质与卡片风格会随调节实时变化。',
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: aiTextStyle,
    );
    if (style.components.assistantStyle == ThemeAssistantStyle.card) {
      aiBlock = DecoratedBox(
        decoration: BoxDecoration(
          color: style.assistantBubble ?? surfaces.card.fill,
          borderRadius: BorderRadius.circular(rMd),
          border: Border.all(color: scheme.outlineVariant, width: style.borderWidth.clamp(0.5, 2.0)),
        ),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: aiBlock),
      );
    } else if (style.components.assistantStyle == ThemeAssistantStyle.leftRule) {
      aiBlock = DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: scheme.primary.withValues(alpha: 0.7), width: 2.5)),
        ),
        child: Padding(padding: const EdgeInsets.only(left: 8), child: aiBlock),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [surfaces.backdropTop, surfaces.backdropBottom],
          ),
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          children: [
            if (backdropBytes != null)
              Positioned.fill(
                child: Opacity(
                  opacity: style.surfaces.backdropOpacity.clamp(0.0, 1.0),
                  child: Image.memory(
                    backdropBytes!,
                    fit: style.surfaces.backdropRepeat ? BoxFit.none : BoxFit.cover,
                    repeat: style.surfaces.backdropRepeat ? ImageRepeat.repeat : ImageRepeat.noRepeat,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: style.components.headerStyle == ThemeHeaderStyle.ghost
                              ? Colors.transparent
                              : surfaces.chrome.fallbackFill,
                          borderRadius: BorderRadius.circular(style.scaleRadius(12)),
                          border: style.components.headerStyle == ThemeHeaderStyle.ghost
                              ? null
                              : Border.all(color: surfaces.chrome.hairline, width: surfaces.chrome.hairlineWidth),
                        ),
                        child: Text(
                          english ? 'Live Preview' : '实时预览',
                          style: themeData.textTheme.labelSmall?.copyWith(color: scheme.onSurface),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: dsh.codeWellBg,
                          borderRadius: BorderRadius.circular(style.scaleRadius(6)),
                          border: Border.all(color: dsh.codeWellBorder, width: 0.6),
                        ),
                        child: Text(
                          'code()',
                          style: style.codeTextStyle(AppType.monoSmall(color: dsh.codeWellFg)).copyWith(fontSize: 10),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: DecoratedBox(
                      decoration: style.components.userBubbleStyle == ThemeUserBubbleStyle.minimal
                          ? BoxDecoration(border: Border(right: BorderSide(color: scheme.primary, width: 2.5)))
                          : BoxDecoration(
                              color: userBg,
                              borderRadius: BorderRadius.circular(rLg),
                              border: style.components.userBubbleStyle == ThemeUserBubbleStyle.outlined
                                  ? Border.all(color: scheme.outlineVariant, width: style.borderWidth.clamp(0.8, 2.0))
                                  : null,
                            ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                        child: Text(
                          english ? 'Make it look like warm paper' : '帮我调成温润的书卷风格',
                          style: (themeData.textTheme.bodySmall ?? const TextStyle(fontSize: 12)).copyWith(color: userFg),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  aiBlock,
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 28,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: surfaces.chrome.fallbackFill,
                            borderRadius: BorderRadius.circular(style.scaleRadius(14)),
                            border: Border.all(color: surfaces.chrome.hairline, width: surfaces.chrome.hairlineWidth),
                          ),
                          child: Text(
                            english ? 'Message...' : '发消息…',
                            style: themeData.textTheme.labelSmall?.copyWith(color: dsh.textTertiary),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(color: keyBg, shape: BoxShape.circle),
                        child: Icon(AppIcons.send, size: 14, color: keyFg),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
