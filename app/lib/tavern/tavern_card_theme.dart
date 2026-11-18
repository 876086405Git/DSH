// A card's own look (docs/design/roleplay-ui.md §10, extensions.dshgo.theme):
// its accent, the layout it reads best in, its characters' name colours and
// its background, read leniently from the raw JSON. It reaches only the story
// (transcript, stage, picture); the app's shell keeps its own look. Its fonts
// are font files among its own assets, loaded once (tavernCardFontProvider).
// 酒馆设置 › 显示 turns all of it off.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../wallpaper/custom_wallpaper.dart';
import 'tavern_provider.dart';
import 'tavern_settings.dart';

class TavernCardTheme {
  const TavernCardTheme({
    this.accent,
    this.layout,
    this.names = const {},
    this.background,
    this.bodyFont,
    this.nameFont,
  });

  final Color? accent;

  /// The layout a chat with this card starts in, until it picks its own.
  final TavernLayout? layout;

  /// Name colours by speaker, as the card writes the names.
  final Map<String, Color> names;

  /// A file on this phone: the asset the theme names, else the card's first
  /// background asset. Remote pictures are never fetched for it.
  final String? background;

  /// Font files on this phone for the story's text and the speakers' names:
  /// `fonts` names assets, as a string (the text's) or {body, names}.
  final String? bodyFont;
  final String? nameFont;

  // Read again on each change to the library: the same look is no change.
  @override
  bool operator ==(Object other) =>
      other is TavernCardTheme &&
      other.accent == accent &&
      other.layout == layout &&
      mapEquals(other.names, names) &&
      other.background == background &&
      other.bodyFont == bodyFont &&
      other.nameFont == nameFont;

  @override
  int get hashCode => Object.hash(accent, layout, Object.hashAllUnordered(names.entries.map((e) => (e.key, e.value))), background, bodyFont, nameFont);

  bool get isEmpty =>
      accent == null && layout == null && names.isEmpty && background == null && bodyFont == null && nameFont == null;

  static TavernCardTheme of(TavernCharacter character) {
    final raw = character.theme;
    final theme = raw is Map ? raw : const {};
    final local = [
      for (final a in character.assets)
        if (a.localPath case final String path when path.isNotEmpty) (asset: a, path: path),
    ];
    String? background;
    if (theme['background'] case final String named when named.trim().isNotEmpty) {
      final want = named.trim();
      background = local.where((a) => a.asset.name == want || a.asset.uri == want).firstOrNull?.path;
    } else {
      background = local.where((a) => a.asset.type == 'background').firstOrNull?.path;
    }
    // A font the theme names: a local asset by name or URI, a font file.
    String? font(Object? named) {
      if (named is! String || named.trim().isEmpty) return null;
      final want = named.trim();
      return local
          .where((a) => a.asset.name == want || a.asset.uri == want)
          .where((a) => _fontFile.hasMatch(a.path) || a.asset.type == 'font')
          .firstOrNull
          ?.path;
    }

    final fonts = theme['fonts'];
    return TavernCardTheme(
      accent: tavernCssColor(theme['accent']),
      layout: switch (theme['layout']) {
        'bubble' || 'chat' => TavernLayout.bubble,
        'novel' => TavernLayout.novel,
        'vn' || 'visualNovel' || 'visual_novel' || 'visual-novel' || 'galgame' => TavernLayout.visualNovel,
        _ => null,
      },
      names: {
        if (theme['names'] case final Map names)
          for (final MapEntry(:key, :value) in names.entries)
            if (key is String)
              if (tavernCssColor(value) case final Color color) key: color,
      },
      background: background,
      bodyFont: switch (fonts) {
        final String body => font(body),
        final Map fonts => font(fonts['body'] ?? fonts['text'] ?? fonts['main']),
        _ => null,
      },
      nameFont: switch (fonts) {
        final Map fonts => font(fonts['names'] ?? fonts['name'] ?? fonts['title']),
        _ => null,
      },
    );
  }
}

final _fontFile = RegExp(r'\.(ttf|otf|ttc)$', caseSensitive: false);

/// [path], a font file of a card's, loaded once as a font family; its name,
/// or null when it can't be read or isn't TrueType / OpenType.
final tavernCardFontProvider = FutureProvider.family<String?, String>((ref, path) async {
  try {
    final bytes = await File(path).readAsBytes();
    if (!tavernLooksLikeFont(bytes)) return null;
    final family = 'tavern-card-font-${path.hashCode.toUnsigned(32).toRadixString(16)}';
    await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    return family;
  } on Object {
    return null;
  }
}, retry: (_, _) => null);

/// TrueType, OpenType or a collection of them, by the first four bytes.
bool tavernLooksLikeFont(Uint8List bytes) {
  if (bytes.length < 12) return false;
  final tag = String.fromCharCodes(bytes.sublist(0, 4));
  return tag == 'OTTO' ||
      tag == 'true' ||
      tag == 'ttcf' ||
      (bytes[0] == 0 && bytes[1] == 1 && bytes[2] == 0 && bytes[3] == 0);
}

/// A CSS colour as cards write them: #rgb, #rgba, #rrggbb, #rrggbbaa,
/// rgb(r, g, b) or rgba(r, g, b, a). Anything else (names, var(), hsl) is
/// null.
Color? tavernCssColor(Object? value) {
  if (value is! String) return null;
  final s = value.trim().toLowerCase();
  final hex = RegExp(r'^#([0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$').firstMatch(s)?.group(1);
  if (hex != null) {
    final full = hex.length <= 4 ? hex.split('').map((c) => '$c$c').join() : hex;
    final rgb = int.parse(full.substring(0, 6), radix: 16);
    final alpha = full.length == 8 ? int.parse(full.substring(6), radix: 16) : 0xff;
    return Color((alpha << 24) | rgb);
  }
  final fn = RegExp(r'^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+%?)\s*)?\)$').firstMatch(s);
  if (fn == null) return null;
  int channel(String v) => double.parse(v).round().clamp(0, 255);
  var alpha = 1.0;
  if (fn.group(4) case final String a) {
    alpha = a.endsWith('%') ? double.parse(a.substring(0, a.length - 1)) / 100 : double.parse(a);
  }
  return Color.fromARGB(
    (alpha.clamp(0, 1) * 255).round(),
    channel(fn.group(1)!),
    channel(fn.group(2)!),
    channel(fn.group(3)!),
  );
}

/// The card's look for a chat with [characterId]; null when there is none,
/// or 酒馆设置 says not to use it.
final tavernCardThemeProvider = Provider.autoDispose.family<TavernCardTheme?, String?>((ref, characterId) {
  if (characterId == null || !ref.watch(tavernSettingsProvider.select((s) => s.cardTheme))) return null;
  final character = ref.watch(tavernCharacterDetailProvider(characterId)).value;
  if (character == null) return null;
  final theme = TavernCardTheme.of(character);
  return theme.isEmpty ? null : theme;
});

/// The card's background at [path] as a chat picture: read in place (the
/// library keeps the file), only its size decoded. Null when it can't be
/// read or is over a wallpaper's size limit.
final tavernCardBackgroundProvider = FutureProvider.autoDispose.family<CustomWallpaper?, String>((ref, path) async {
  try {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() > CustomWallpaper.maxBytes) return null;
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final (width, height) = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    return CustomWallpaper(path: path, width: width, height: height);
  } catch (_) {
    return null;
  }
});
