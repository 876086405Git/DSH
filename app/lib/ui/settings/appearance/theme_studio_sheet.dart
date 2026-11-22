// The Theme Studio: a live preview over the groups that edit one draft ThemePack, the entry to the raw JSON,
// and the save into the local theme library.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../themes/theme_library.dart';
import '../../common/app_sheet.dart';
import '../../common/discard_guard.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import 'theme_packs_section.dart' show themeImportProblemText;
import 'theme_studio_controller.dart';
import 'theme_studio_controls.dart';
import 'theme_studio_groups.dart';
import 'theme_studio_json.dart';
import 'theme_studio_preview.dart';
import 'theme_studio_problems.dart';

/// The groups in page order, with the names the jump row shows.
const _groups = <(String id, String zh, String en)>[
  ('info', '基本信息', 'Basics'),
  ('colors', '颜色', 'Colors'),
  ('surfaces', '材质与背景', 'Material'),
  ('typography', '字体', 'Fonts'),
  ('shapes', '形状与间距', 'Shape'),
  ('components', '界面组件', 'Components'),
  ('empty', '新对话页', 'New chat'),
];

/// Creates a theme from [initial] as a template, or edits it in place when [editing]. Pops with the saved pack.
class ThemeStudioSheet extends ConsumerStatefulWidget {
  const ThemeStudioSheet({super.key, this.initial, this.editing = false, this.existingIds = const {}});

  final ThemePack? initial;
  final bool editing;
  final Set<String> existingIds;

  @override
  ConsumerState<ThemeStudioSheet> createState() => _ThemeStudioSheetState();
}

class _ThemeStudioSheetState extends ConsumerState<ThemeStudioSheet> {
  /// The preview's theme follows the draft at most this often: building a ThemeData on every tick of a slider
  /// would cost the drag its frames.
  static const _previewBeat = Duration(milliseconds: 80);

  late final _c = ThemeStudioController(
    initial: widget.initial,
    editing: widget.editing,
    existingIds: widget.existingIds,
  );
  final _open = <String>{};
  final _groupKeys = {for (final (id, _, _) in _groups) id: GlobalKey()};
  bool _previewDark = false;
  var _page = StudioPreviewPage.chat;
  bool _saving = false;

  /// The draft as a theme, as of the last beat.
  ThemeData? _resolved;
  Map<String, String>? _savedFonts;
  bool _glassBlur = true;
  Timer? _cooling;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    _c.addListener(_draftChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final blur = DshSurfaces.of(context).blurEnabled;
    if (blur != _glassBlur) {
      _glassBlur = blur;
      _resolved = null;
    }
  }

  @override
  void dispose() {
    _cooling?.cancel();
    _c.dispose();
    super.dispose();
  }

  void _resolve() {
    final draft = _c.previewPack;
    _resolved = (_previewDark ? buildDarkTheme : buildLightTheme)(
      accent: AppAccent.fromThemePack(draft),
      glassBlur: _glassBlur,
      glyphLocale: AppLocale.isEnglish ? AppLocale.zhCN : null,
      themePack: draft,
      loadedFonts: {...?_savedFonts, ..._c.fontFamilies},
    );
  }

  /// The first change shows at once; changes inside the beat after it show together when it ends.
  void _draftChanged() {
    if (_cooling != null) {
      _stale = true;
      return;
    }
    setState(_resolve);
    _cooling = Timer(_previewBeat, () {
      _cooling = null;
      if (!_stale) return;
      _stale = false;
      _draftChanged();
    });
  }

  void _toggle(String group) => setState(() => _open.remove(group) || _open.add(group));

  void _jump(String group) {
    final target = _groupKeys[group]!.currentContext;
    if (target == null) return;
    unawaited(
      Scrollable.ensureVisible(target, duration: AppMotion.of(context, AppMotion.standard), curve: AppMotion.std),
    );
  }

  Future<void> _editJson() async {
    final applied = await showAppSheet<bool>(
      context,
      heightFactor: 0.92,
      builder: (_) => ThemeStudioJsonSheet(controller: _c),
    );
    if (applied != true || !mounted) return;
    // A file the JSON names but nobody picked is flagged at its control; unfold the groups hiding one.
    final pack = _c.pack;
    final parts = pack.components;
    final fonts = pack.typography;
    setState(() {
      if (_c.isMissing(parts.assistantAvatar) || _c.isMissing(parts.userAvatar)) _open.add('components');
      if ([
        fonts.uiFont,
        fonts.headingFont,
        fonts.codeFont,
      ].any((font) => ThemeTypographySpec.isCustomFontAsset(font) && _c.isMissing(font))) {
        _open.add('typography');
      }
    });
  }

  /// The library's refusal in the studio's words, when it is about a field the studio knows.
  String _saveProblem(ThemeImportException error) {
    final detail = error.detail;
    if (error.problem == ThemeImportProblem.badPack && detail != null) {
      final said = studioProblemText(detail);
      if (said != detail) return said;
    }
    return themeImportProblemText(error, english: AppLocale.isEnglish);
  }

  Future<void> _save() async {
    if (_saving) return;
    final blocker = _c.saveBlocker;
    if (blocker != null) return _c.fail(blocker);
    setState(() => _saving = true);
    try {
      final replaces = _c.savesOverInitial;
      final saved = await ref
          .read(themeLibraryProvider)
          .saveCustom(
            _c.forSave,
            assets: _c.assets,
            allowOverwrite: replaces,
            editingLocalId: replaces ? widget.initial!.id : null,
          );
      if (mounted) Navigator.of(context).pop(saved);
    } on ThemeImportException catch (error) {
      if (mounted) _c.fail(_saveProblem(error));
    } on Object catch (error) {
      if (mounted) _c.fail(error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final english = AppLocale.isEnglish;
    final savedFonts = ref.watch(themeLoadedFontsProvider(widget.initial?.id)).value ?? const <String, String>{};
    if (_resolved == null || !identical(savedFonts, _savedFonts)) {
      _savedFonts = savedFonts;
      _resolve();
    }
    final resolved = _resolved!;
    Widget group(String id, Widget Function(bool open, VoidCallback onToggle) build) =>
        KeyedSubtree(key: _groupKeys[id], child: build(_open.contains(id), () => _toggle(id)));
    return DiscardGuard(
      listenable: _c,
      isDirty: () => _c.isDirty,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SheetHeader(
            english ? 'Theme Studio' : '主题工坊创作器',
            actions: [
              SheetIconButton(
                key: const ValueKey('theme-studio-json'),
                icon: AppIcons.code,
                tooltip: english ? 'Edit as JSON' : '直接编辑 JSON',
                onPressed: () => unawaited(_editJson()),
              ),
            ],
          ),
          _PreviewDock(
            theme: resolved,
            page: _page,
            dark: _previewDark,
            onPage: (page) => setState(() => _page = page),
            onDark: (dark) => setState(() {
              _previewDark = dark;
              _resolve();
            }),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(
              spacing: 6,
              children: [
                for (final (id, zh, en) in _groups)
                  ActionChip(
                    key: ValueKey('theme-studio-jump-$id'),
                    label: Text(english ? en : zh),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: const StadiumBorder(),
                    onPressed: () => _jump(id),
                  ),
              ],
            ),
          ),
          Flexible(
            child: ListenableBuilder(
              listenable: _c,
              builder: (context, _) => SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 20 + MediaQuery.viewInsetsOf(context).bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    group('info', (open, onToggle) => StudioInfoGroup(c: _c, open: open, onToggle: onToggle)),
                    group(
                      'colors',
                      (open, onToggle) =>
                          StudioColorGroup(c: _c, open: open, onToggle: onToggle, previewDark: _previewDark),
                    ),
                    group(
                      'surfaces',
                      (open, onToggle) => StudioSurfaceGroup(c: _c, open: open, onToggle: onToggle, resolved: resolved),
                    ),
                    group(
                      'typography',
                      (open, onToggle) => StudioTypographyGroup(c: _c, open: open, onToggle: onToggle),
                    ),
                    group(
                      'shapes',
                      (open, onToggle) => StudioShapeGroup(c: _c, open: open, onToggle: onToggle, resolved: resolved),
                    ),
                    group(
                      'components',
                      (open, onToggle) => StudioComponentGroup(c: _c, open: open, onToggle: onToggle),
                    ),
                    group('empty', (open, onToggle) => StudioEmptyStateGroup(c: _c, open: open, onToggle: onToggle)),
                    if (_c.error case final error?) ...[
                      const SizedBox(height: 12),
                      Text(
                        error,
                        key: const ValueKey('theme-studio-error'),
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: Theme.of(context).colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 18),
                    FilledButton(
                      key: const ValueKey('theme-studio-save'),
                      onPressed: _saving ? null : () => unawaited(_save()),
                      child: Text(english ? 'Save & Apply Theme Pack' : '保存并启用主题包'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The preview with its two switches beside it. With the keyboard up it gives its room to the fields: it
/// shrinks, and on a short screen steps aside until the keyboard is gone.
class _PreviewDock extends StatelessWidget {
  const _PreviewDock({
    required this.theme,
    required this.page,
    required this.dark,
    required this.onPage,
    required this.onDark,
  });

  final ThemeData theme;
  final StudioPreviewPage page;
  final bool dark;
  final ValueChanged<StudioPreviewPage> onPage;
  final ValueChanged<bool> onDark;

  /// The handle, the title, the jump row and enough of the controls to work in.
  static const _reserved = 360.0;

  /// Below this the page is too small to tell anything from.
  static const _least = 120.0;

  @override
  Widget build(BuildContext context) {
    final english = AppLocale.isEnglish;
    final screen = MediaQuery.sizeOf(context).height - MediaQuery.viewPaddingOf(context).top;
    final room = screen - MediaQuery.viewInsetsOf(context).bottom - _reserved;
    if (room < _least) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ThemeStudioPreview(
            theme: theme,
            page: page,
            height: room.clamp(_least, ThemeStudioPreview.fullHeight).toDouble(),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 12,
              children: [
                StudioChoice<StudioPreviewPage>(
                  label: english ? 'Preview' : '预览哪一页',
                  items: [
                    (StudioPreviewPage.chat, english ? 'Chat' : '对话'),
                    (StudioPreviewPage.newChat, english ? 'New chat' : '新对话页'),
                  ],
                  value: page,
                  onChanged: onPage,
                ),
                StudioChoice<bool>(
                  label: english ? 'Appearance' : '明暗',
                  items: [(false, english ? 'Light' : '浅色'), (true, english ? 'Dark' : '深色')],
                  value: dark,
                  onChanged: onDark,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
