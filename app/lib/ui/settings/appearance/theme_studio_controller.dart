// The Theme Studio's draft: one ThemePack that every control edits through copyWith, the files picked in this
// session, and the checks that run before a save.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;

import '../../../l10n/l10n.dart';
import '../../../pets/pet_name_alias.dart';
import '../../../themes/theme_library.dart';
import '../../../themes/theme_pack.dart';
import '../../../themes/theme_pack_validator.dart';
import 'theme_packs_section.dart' show themeImportProblemText;

enum ThemeFontRole { ui, reading, heading, code }

/// Where a bundled image is used; [stem] names the file it is stored as.
enum ThemeImageSlot {
  backdrop('backdrop'),
  hero('hero'),
  assistantAvatar('avatar-assistant'),
  userAvatar('avatar-user');

  const ThemeImageSlot(this.stem);

  final String stem;
}

const _fontExtensions = ['.ttf', '.otf'];

String _t(String zh, String en) => AppLocale.isEnglish ? en : zh;

Future<({String name, Uint8List bytes})?> _pickBounded(List<String> extensions, int maxBytes) async {
  final picked = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: extensions);
  if (picked == null) return null;
  final length = await picked.length();
  if (length != null && length > maxBytes) throw const ThemeImportException(ThemeImportProblem.tooLarge);
  final builder = BytesBuilder(copy: false);
  await for (final chunk in picked.readAsByteStream()) {
    builder.add(chunk);
    if (builder.length > maxBytes) throw const ThemeImportException(ThemeImportProblem.tooLarge);
  }
  return (name: picked.name, bytes: builder.takeBytes());
}

class ThemeStudioController extends ChangeNotifier {
  ThemeStudioController({this.initial, this.editing = false, this.existingIds = const {}}) {
    final base = initial ?? ThemePack.paper;
    _pack = _opened = editing ? base.copyWith(id: base.publicId) : _remix(base);
    final folder = base.folderPath;
    if (folder != null) {
      try {
        _onDisk = {
          for (final entity in Directory(folder).listSync(followLinks: false))
            if (entity is File) entity.uri.pathSegments.last,
        };
      } on FileSystemException {
        // Saving reports whatever turns out to be missing.
      }
    }
  }

  /// The pack the studio opened on: the theme being edited, or the template a new one starts from.
  final ThemePack? initial;

  /// True when saving under the same ID replaces [initial] instead of creating a theme.
  final bool editing;

  /// Public IDs already in the library.
  final Set<String> existingIds;

  late ThemePack _pack;
  late final ThemePack _opened;
  Set<String> _onDisk = const {};
  bool _titlesEdited = false;
  Directory? _staging;
  int _staged = 0;

  /// The draft. Its [ThemePack.id] is the public ID as typed, and its folder is still the template's, so files
  /// the draft keeps referencing are carried over on save.
  ThemePack get pack => _pack;

  /// Files picked in this session, by the name the draft references them under.
  final Map<String, Uint8List> assets = {};

  /// Font families loaded from picked files, for the live preview.
  final Map<String, String> fontFamilies = {};

  String? error;

  /// Whether closing now would lose something.
  bool get isDirty => _pack != _opened || assets.isNotEmpty;

  /// The draft as the preview's widgets read it. They load a pack's pictures from its folder, so this session's
  /// picks are laid out in one ([_stage]). The ID is not the draft's: under a built-in's ID the theme would
  /// take that built-in's special-cased accent.
  ThemePack get previewPack =>
      _pack.copyWith(id: 'draft-preview', folderPath: _staging?.path, assetRevision: _pack.assetRevision + _staged);

  void _stage(String name, Uint8List bytes) {
    try {
      var folder = _staging;
      if (folder == null) {
        folder = _staging = Directory.systemTemp.createTempSync('dsh-theme-studio-');
        // The saved pictures come along: this folder stands in for the theme's own.
        for (final saved in _onDisk) {
          if (themeImageExtensions.any(saved.toLowerCase().endsWith)) {
            File('${_pack.folderPath}/$saved').copySync('${folder.path}/$saved');
          }
        }
      }
      final file = File('${folder.path}/$name')..writeAsBytesSync(bytes);
      // The same name may have held another picture a moment ago.
      evictThemeImage(file);
      _staged++;
    } on FileSystemException {
      // The preview goes without the new picture; saving does not need the copy.
    }
  }

  @override
  void dispose() {
    try {
      _staging?.deleteSync(recursive: true);
    } on FileSystemException {
      // A temporary folder: the system clears it.
    }
    super.dispose();
  }

  ThemePack _remix(ThemePack base) {
    final publicId = base.publicId;
    final stem = publicId.length > 30 ? publicId.substring(0, 30).replaceAll(RegExp(r'-+$'), '') : publicId;
    var id = '$stem-custom';
    for (var n = 2; existingIds.contains(id) || ThemePack.builtInById(id) != null; n++) {
      id = '$stem-custom-$n';
    }
    // A new theme is the user's own: the template's titles, tags and attribution stay behind.
    return ThemePack(
      id: id,
      name: AppLocale.isEnglish ? '${base.displayName('en')} · Custom' : '${base.name} · 自定义',
      description: base.description,
      palette: base.palette,
      surfaces: base.surfaces,
      typography: base.typography,
      shapes: base.shapes,
      components: base.components,
      emptyState: base.emptyState,
      folderPath: base.folderPath,
      assetRevision: base.assetRevision,
    );
  }

  void update(ThemePack next) {
    _pack = next;
    error = null;
    notifyListeners();
  }

  void fail(String message) {
    error = message;
    notifyListeners();
  }

  void palette(ThemePaletteSpec Function(ThemePaletteSpec p) change) =>
      update(_pack.copyWith(palette: change(_pack.palette)));

  void surfaces(ThemeSurfaceSpec Function(ThemeSurfaceSpec s) change) =>
      update(_pack.copyWith(surfaces: change(_pack.surfaces)));

  void typography(ThemeTypographySpec Function(ThemeTypographySpec t) change) =>
      update(_pack.copyWith(typography: change(_pack.typography)));

  void shapes(ThemeShapeSpec Function(ThemeShapeSpec s) change) => update(_pack.copyWith(shapes: change(_pack.shapes)));

  void components(ThemeComponentSpec Function(ThemeComponentSpec c) change) =>
      update(_pack.copyWith(components: change(_pack.components)));

  void emptyState(ThemeEmptyStateSpec Function(ThemeEmptyStateSpec e) change) =>
      update(_pack.copyWith(emptyState: change(_pack.emptyState)));

  /// [ThemePack.copyWith] cannot clear these, so the pack is rebuilt around them.
  void setMeta({
    ValueGetter<String?>? titleZh,
    ValueGetter<String?>? titleEn,
    ValueGetter<String?>? author,
    ValueGetter<String?>? license,
    ValueGetter<String?>? source,
  }) {
    if (titleZh != null || titleEn != null) _titlesEdited = true;
    final p = _pack;
    update(
      ThemePack(
        id: p.id,
        name: p.name,
        titleZh: titleZh != null ? titleZh() : p.titleZh,
        titleEn: titleEn != null ? titleEn() : p.titleEn,
        description: p.description,
        tags: p.tags,
        author: author != null ? author() : p.author,
        license: license != null ? license() : p.license,
        source: source != null ? source() : p.source,
        palette: p.palette,
        surfaces: p.surfaces,
        typography: p.typography,
        shapes: p.shapes,
        components: p.components,
        emptyState: p.emptyState,
        folderPath: p.folderPath,
        assetRevision: p.assetRevision,
      ),
    );
  }

  /// Titles win over the name wherever a theme is listed, so a rename drops the ones it inherited; titles typed
  /// in this session are the user's and stay.
  void setName(String name) {
    _pack = _pack.copyWith(name: name);
    if (_titlesEdited) {
      update(_pack);
    } else {
      setMeta(titleZh: () => null, titleEn: () => null);
      _titlesEdited = false;
    }
  }

  void setColor(String key, int? argb, {required bool dark}) => palette(
    (p) => dark ? p.copyWith(dark: p.dark.withToken(key, argb)) : p.copyWith(light: p.light.withToken(key, argb)),
  );

  /// A new accent drops the dark seed and the primary overrides, which would keep showing the old accent.
  void setSeed(int argb, {double? tintHue}) => palette(
    (p) => p.copyWith(
      seed: argb,
      seedDark: argb == p.seed ? null : () => null,
      tintHue: tintHue == null ? null : () => tintHue,
      light: argb == p.seed ? null : p.light.withToken('primary', null),
      dark: argb == p.seed ? null : p.dark.withToken('primary', null),
    ),
  );

  /// The quick bubble field also picks a readable text colour; the full colour list sets each on its own.
  void setUserBubble(int? argb) {
    int? ink;
    if (argb != null) {
      final luminance = Color(argb).computeLuminance();
      ink = (luminance + 0.05) * (luminance + 0.05) > 0.15 ? 0xFF1F1E1B : 0xFFF7F7F7;
    }
    palette((p) => p.copyWith(light: p.light.withToken('userBubble', argb).withToken('onUserBubble', ink)));
  }

  /// The quick page colour is flat: both ends of the backdrop gradient.
  void setBackdropColor(int? argb, {required bool dark}) => palette((p) {
    final next = (dark ? p.dark : p.light).withToken('backdropTop', argb).withToken('backdropBottom', argb);
    return dark ? p.copyWith(dark: next) : p.copyWith(light: next);
  });

  /// Fine tuning belongs to the material it was made for, so another preset starts clean.
  void setPreset(ThemeSurfacePreset preset) {
    if (preset == _pack.surfaces.preset) return;
    final crisp = preset == ThemeSurfacePreset.paper || preset == ThemeSurfacePreset.outlined;
    update(
      _pack.copyWith(
        surfaces: _pack.surfaces.copyWith(
          preset: preset,
          chromeBlur: () => null,
          sheetBlur: () => null,
          cardOpacity: () => null,
          pillOpacity: () => null,
          hairlineWidth: () => null,
          rimOpacity: () => null,
          shadowOpacity: () => null,
        ),
        shapes: _pack.shapes.copyWith(borderWidth: crisp ? 1.0 : 0.6),
      ),
    );
  }

  String fontOf(ThemeFontRole role) => switch (role) {
    ThemeFontRole.ui => _pack.typography.uiFont,
    ThemeFontRole.reading => _pack.typography.readingFont,
    ThemeFontRole.heading => _pack.typography.headingFont,
    ThemeFontRole.code => _pack.typography.codeFont,
  };

  void chooseFont(ThemeFontRole role, String value) {
    final t = _pack.typography;
    var next = _pack.copyWith(
      typography: switch (role) {
        ThemeFontRole.ui => t.copyWith(uiFont: value),
        ThemeFontRole.reading => t.copyWith(readingFont: value, headingFont: value),
        ThemeFontRole.heading => t.copyWith(headingFont: value),
        ThemeFontRole.code => t.copyWith(codeFont: value),
      },
    );
    // The reply font is the one quick choice, so headings and the reply and greeting switches follow it.
    if (role == ThemeFontRole.reading) {
      next = next.copyWith(
        components: next.components.copyWith(useReadingFontForReply: value != 'system'),
        emptyState: ThemeTypographySpec.isCustomFontAsset(value)
            ? null
            : next.emptyState.copyWith(useReadingFontForGreeting: value == 'serif'),
      );
    }
    update(next);
  }

  /// Every font file a role could use: referenced, picked in this session, or already in the theme's folder.
  List<String> get fontFiles {
    bool isFont(String name) => _fontExtensions.any(name.toLowerCase().endsWith);
    return {..._pack.referencedFonts, ...assets.keys.where(isFont), ..._onDisk.where(isFont)}.toList()..sort();
  }

  String? imageOf(ThemeImageSlot slot) => switch (slot) {
    ThemeImageSlot.backdrop => _pack.surfaces.backdropImage,
    ThemeImageSlot.hero => _pack.emptyState.heroImage,
    ThemeImageSlot.assistantAvatar => _pack.components.assistantAvatar,
    ThemeImageSlot.userAvatar => _pack.components.userAvatar,
  };

  void setImage(ThemeImageSlot slot, String? name) => switch (slot) {
    ThemeImageSlot.backdrop => surfaces((s) => s.copyWith(backdropImage: () => name)),
    ThemeImageSlot.hero => emptyState(
      (e) => e.copyWith(
        heroImage: () => name,
        heroStyle: name != null
            ? ThemeHeroStyle.customImage
            : (e.heroStyle == ThemeHeroStyle.customImage ? ThemeHeroStyle.badge : null),
      ),
    ),
    ThemeImageSlot.assistantAvatar => components((c) => c.copyWith(assistantAvatar: () => name)),
    ThemeImageSlot.userAvatar => components((c) => c.copyWith(userAvatar: () => name)),
  };

  Future<void> pickImage(ThemeImageSlot slot) async {
    try {
      final picked = await _pickBounded(const ['png', 'webp', 'gif'], themeImageByteCap);
      if (picked != null) useImage(slot, picked.bytes);
    } on ThemeImportException catch (e) {
      fail(themeImportProblemText(e, english: AppLocale.isEnglish));
    } on Object {
      fail(_t('读取图片失败。', 'Could not read the image.'));
    }
  }

  /// Makes [bytes] the picture in [slot], once they pass the checks a pack's pictures go through.
  void useImage(ThemeImageSlot slot, Uint8List bytes) {
    // The stored name takes the type the bytes really are, whatever the picked file was called.
    final extension = themeImageExtensions.where((e) => themeImageHeaderMatches('x$e', bytes)).firstOrNull;
    if (extension == null) return fail(_t('这不是 PNG、WebP 或 GIF 图片。', 'Not a PNG, WebP or GIF image.'));
    final name = '${slot.stem}$extension';
    try {
      ThemePackValidator.validateParts(
        ThemePack(
          id: 'asset-check',
          name: 'check',
          surfaces: ThemeSurfaceSpec(backdropImage: name),
        ).toJson(),
        {name: bytes},
      );
    } on ThemeValidationException catch (e) {
      return fail(_t('这张图片没通过检查（${e.code}）。', 'This image did not pass the check (${e.code}).'));
    }
    assets[name] = bytes;
    _stage(name, bytes);
    setImage(slot, name);
  }

  /// The file name [bytes] go under, starting from [base]: the name they already have when this
  /// very file is in the draft or the folder, else the first one no other font answers to. A pack
  /// takes names that differ only in case or Unicode form for one name, so those count as taken.
  String _fontNameFor(String base, String extension, Uint8List bytes) {
    for (var n = 1; ; n++) {
      final name = n == 1 ? '$base$extension' : '$base-$n$extension';
      final alias = petNameAlias(name);
      final picked = assets.keys.where((k) => petNameAlias(k) == alias).firstOrNull;
      if (picked != null) {
        if (listEquals(assets[picked], bytes)) return picked;
        continue;
      }
      final saved = _onDisk.where((k) => petNameAlias(k) == alias).firstOrNull;
      if (saved == null) return name;
      try {
        if (listEquals(File('${_pack.folderPath}/$saved').readAsBytesSync(), bytes)) return saved;
      } on FileSystemException {
        // Unreadable: taken, as far as this pick can tell.
      }
    }
  }

  Future<void> pickFont(ThemeFontRole role) async {
    try {
      final picked = await _pickBounded(const ['ttf', 'otf'], themeFontByteCap);
      if (picked != null) await useFont(role, picked.name, picked.bytes);
    } on ThemeImportException catch (e) {
      fail(themeImportProblemText(e, english: AppLocale.isEnglish));
    } on Object {
      fail(_t('读取字体失败。', 'Could not read the font.'));
    }
  }

  /// Makes [bytes], picked as the file [pickedName], the font of [role].
  Future<void> useFont(ThemeFontRole role, String pickedName, Uint8List bytes) async {
    if (!isValidThemeFontBytes(bytes)) return fail(_t('这不是有效的 TTF/OTF 字体。', 'Not a valid TTF/OTF font.'));
    final extension = String.fromCharCodes(bytes.sublist(0, 4)) == 'OTTO' ? '.otf' : '.ttf';
    final stem = pickedName
        .replaceFirst(RegExp(r'\.[^.]*$'), '')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '-')
        .replaceAll(RegExp(r'^[-_]+|-+$'), '');
    final base = stem.isEmpty ? 'font-${role.name}' : stem.substring(0, stem.length.clamp(0, 60));
    // Another file of this name may already serve a role: this one takes a name of its own.
    final name = _fontNameFor(base, extension, bytes);
    assets[name] = bytes;
    try {
      // A family per pick: a replaced file must not show the font loaded before it.
      final family = 'dsh-studio-${identityHashCode(bytes)}-$name';
      await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      fontFamilies[name] = family;
    } on Object {
      // The preview keeps its fallback font; the file is still saved.
    }
    chooseFont(role, name);
  }

  bool isMissing(String? name) => name != null && !assets.containsKey(name) && !_onDisk.contains(name);

  Set<String> get missingAssets {
    final pack = forSave;
    return {...pack.referencedImages, ...pack.referencedFonts}.where(isMissing).toSet();
  }

  /// Swaps the whole draft for one parsed from JSON. The folder stays, and so does the ID of a theme being
  /// edited: the JSON describes a look, not which theme is open.
  void replaceWith(ThemePack parsed) {
    _titlesEdited = true;
    update(
      parsed.copyWith(
        id: editing ? _pack.id : parsed.id,
        folderPath: _pack.folderPath,
        assetRevision: _pack.assetRevision,
      ),
    );
  }

  /// The draft as it is written: tidy text, and no hero image left behind by a style that no longer shows one.
  ThemePack get forSave {
    final empty = _pack.emptyState;
    return _pack.copyWith(
      id: _pack.id.trim().toLowerCase(),
      name: _pack.name.trim(),
      description: _pack.description.trim(),
      emptyState: empty.heroStyle != ThemeHeroStyle.customImage && empty.heroImage != null
          ? empty.copyWith(heroImage: () => null)
          : null,
    );
  }

  /// Whether a save replaces [initial] rather than adding a theme.
  bool get savesOverInitial => editing && initial != null && forSave.id == initial!.publicId;

  /// What stops a save, in the user's words; null when the draft can go to the library.
  String? get saveBlocker {
    final pack = forSave;
    if (pack.name.isEmpty) return _t('请填写主题名称。', 'Please enter a theme name.');
    if (!isValidThemeId(pack.id) || ThemePack.builtInById(pack.id) != null) {
      return _t(
        '主题 ID 只能用小写字母、数字和连字符，且不能和内置主题重名。',
        'The ID takes lower-case letters, digits and hyphens, and cannot be a built-in theme\'s.',
      );
    }
    if (!savesOverInitial && existingIds.contains(pack.id)) {
      return _t(
        '主题 ID「${pack.id}」已经有了，换一个以免盖掉原来的主题。',
        'A theme with ID "${pack.id}" already exists. Pick another ID so it is not replaced.',
      );
    }
    final empty = pack.emptyState;
    final drawsGlyph = empty.heroStyle == ThemeHeroStyle.glyph || empty.heroStyle == ThemeHeroStyle.seal;
    if (drawsGlyph && empty.heroGlyph == null) {
      return _t('文字和印章样式要先填 1–4 个字。', 'The glyph and seal styles need 1–4 characters.');
    }
    if (empty.heroStyle == ThemeHeroStyle.customImage && empty.heroImage == null) {
      return _t('请先选一张主视觉图。', 'Pick a hero image first.');
    }
    final missing = missingAssets;
    if (missing.isNotEmpty) {
      return _t(
        '还缺素材文件：${missing.join('、')}。请在用到它的地方重新选一个。',
        'Missing files: ${missing.join(', ')}. Pick them again where they are used.',
      );
    }
    return null;
  }
}
