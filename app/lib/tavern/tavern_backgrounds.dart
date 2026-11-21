// A chat's background picture: the stage under its messages
// (docs/design/roleplay-ui.md §2, layer 1). Picked and kept the way the app's
// own wallpaper is (lib/wallpaper/wallpaper_import.dart), in a folder of the
// tavern's own, and drawn the same way: softened, with the page's colour laid
// over it wherever text would lose contrast (WallpaperBackdrop.scene). A card
// that names a background of its own (§10) gives the chat one when the chat
// has not picked a picture (tavern_card_theme.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../wallpaper/custom_wallpaper.dart';
import '../wallpaper/wallpaper_import.dart';

export '../wallpaper/wallpaper_import.dart' show LaunchImportProblem;

/// `<app support>/tavern/backgrounds`: the tavern's own pictures, apart from the wallpaper's.
Future<Directory> tavernBackgroundDirectory() async =>
    Directory('${(await getApplicationSupportDirectory()).path}/tavern/backgrounds').create(recursive: true);

final tavernBackgroundImportProvider = Provider<WallpaperImport>(
  (ref) => WallpaperImport(directory: tavernBackgroundDirectory),
);

/// One chat's picture, or null for none.
class TavernChatBackground extends Notifier<CustomWallpaper?> {
  TavernChatBackground(this.chatId);

  final String chatId;

  /// Set once a picture is chosen or removed: a late read never undoes it.
  var _chosen = false;

  static String keyFor(String chatId) => 'tavern.background.$chatId';

  @override
  CustomWallpaper? build() {
    unawaited(_load());
    return null;
  }

  Future<void> _load() async {
    CustomWallpaper? stored;
    try {
      stored = _read(await SharedPreferences.getInstance(), chatId);
      // Its file gone (the app's data cleared in part): none.
      if (stored != null && !File(stored.path).existsSync()) stored = null;
    } catch (_) {}
    if (!_chosen && ref.mounted) state = stored;
  }

  /// The system picker; the pick shows at once and is kept. Null when it did, else why not
  /// ([LaunchImportProblem.cancelled] included).
  Future<LaunchImportProblem?> choose() async {
    final (picked, problem) = await ref.read(tavernBackgroundImportProvider).pick(previous: state);
    if (picked == null) return problem ?? LaunchImportProblem.unreadable;
    await _store(picked);
    return null;
  }

  /// Back to the page's own gradient; the picture's file goes.
  Future<void> remove() async {
    final previous = state;
    await _store(null);
    if (previous != null) await WallpaperImport.removeFile(previous.path);
  }

  Future<void> _store(CustomWallpaper? picture) async {
    _chosen = true;
    if (ref.mounted) state = picture;
    try {
      final prefs = await SharedPreferences.getInstance();
      picture == null
          ? await prefs.remove(keyFor(chatId))
          : await prefs.setString(keyFor(chatId), jsonEncode(picture.toJson()));
    } catch (_) {}
  }

  static CustomWallpaper? _read(SharedPreferences prefs, String chatId) {
    final raw = prefs.getString(keyFor(chatId));
    return raw == null ? null : CustomWallpaper.fromJson(jsonDecode(raw));
  }
}

final tavernChatBackgroundProvider = NotifierProvider.autoDispose
    .family<TavernChatBackground, CustomWallpaper?, String>(TavernChatBackground.new);

/// Lets a deleted chat's picture go: its file and its entry.
Future<void> forgetTavernBackground(String chatId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final picture = TavernChatBackground._read(prefs, chatId);
    await prefs.remove(TavernChatBackground.keyFor(chatId));
    if (picture != null) await WallpaperImport.removeFile(picture.path);
  } catch (_) {}
}
