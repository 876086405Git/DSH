// A tavern character's Live2D model (docs/design/roleplay-ui.md §4: a
// character with a Live2D pack is drawn with it, on the companion's stage).
// One pack per character, kept the way the companion room keeps hers
// (CompanionPackStore), and drawn by her stage without the room around it
// (CompanionStage.bare) in the visual novel layout.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../companion/companion_pack.dart';

/// `<app support>/tavern/live2d`: a folder per character.
final tavernLive2dRootProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getApplicationSupportDirectory()).path}/tavern/live2d'),
);

/// The companion room's installed pack: a bare model borrows its runtime.
final tavernCompanionPackProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getApplicationSupportDirectory()).path}/companion/pack'),
);

/// The pack that comes inside the app, if this build has one.
final tavernBundledPackProvider = Provider<Future<Uint8List?> Function()>((ref) => loadBundledCompanionPack);

/// A zip the person picks, copied where the unzipper can seek (picks may be
/// content URIs); null when backed out. The caller deletes it.
final tavernLive2dPickerProvider = Provider<Future<File?> Function()>(
  (ref) => () async {
    final picked = await FilePicker.pickFile();
    if (picked == null) return null;
    final temp = File(
      '${(await getTemporaryDirectory()).path}/tavern-live2d-${DateTime.now().microsecondsSinceEpoch}.zip',
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

/// The runtime a pack must carry (the companion's pin; tests bring their own).
final tavernLive2dRuntimeProvider = Provider<String>((ref) => companionRuntimeDigest);

/// The character's store, installed or not.
Future<CompanionPackStore> tavernLive2dStore(
  Future<Directory> Function() root,
  String characterId, {
  String expectedRuntime = companionRuntimeDigest,
}) async => CompanionPackStore(
  // Any ID as a folder name, nothing that climbs out.
  Directory('${(await root()).path}/${base64Url.encode(utf8.encode(characterId)).replaceAll('=', '')}'),
  expectedRuntime: expectedRuntime,
  // One model per card: a new one replaces the old.
  shelve: false,
);

/// The character's installed pack; null for none (or no storage to look in).
final tavernLive2dProvider = FutureProvider.autoDispose.family<CompanionPackStore?, String>((ref, characterId) async {
  try {
    final store = await tavernLive2dStore(
      ref.watch(tavernLive2dRootProvider),
      characterId,
      expectedRuntime: ref.watch(tavernLive2dRuntimeProvider),
    );
    return await store.installed() ? store : null;
  } on Object {
    return null;
  }
});

/// Installs [zip] (a model's folder zipped, or a whole pack) as the
/// character's. A model on its own needs the Live2D runtime: the companion
/// room's, when it has one that is still the pinned runtime, else the pack
/// inside the app; with neither, [CompanionPackProblem.noRuntime].
Future<void> installTavernLive2d(
  CompanionPackStore store,
  String zip, {
  required Future<Directory> Function() companionPack,
  required Future<Uint8List?> Function() bundled,
}) async {
  try {
    await store.install(zip);
    return;
  } on CompanionPackException catch (error) {
    if (error.problem != CompanionPackProblem.noRuntime) rethrow;
  }
  final runtime = Directory('${(await companionPack()).path}/runtime');
  if (await _pinnedRuntime(runtime, store.expectedRuntime)) {
    // Beside where the model will go: the install copies it in with it.
    await _copy(runtime, Directory('${store.pack.path}/runtime'));
  } else {
    final bytes = await bundled();
    if (bytes == null) throw const CompanionPackException(CompanionPackProblem.noRuntime);
    final whole = File('${store.root.path}.runtime-${DateTime.now().microsecondsSinceEpoch}.zip');
    try {
      await store.root.create(recursive: true);
      await whole.writeAsBytes(bytes, flush: true);
      await store.install(whole.path);
    } finally {
      if (await whole.exists()) await whole.delete();
    }
  }
  await store.install(zip);
}

/// Takes the character's model away, folder and all.
Future<void> removeTavernLive2d(CompanionPackStore store) async {
  if (await store.root.exists()) await store.root.delete(recursive: true);
}

/// Lets a deleted character's model go.
Future<void> forgetTavernLive2d(Future<Directory> Function() root, String characterId) async {
  try {
    await removeTavernLive2d(await tavernLive2dStore(root, characterId));
  } on Object {
    // Nothing there, or no storage: nothing to let go.
  }
}

/// Whether [runtime] holds exactly the runtime the app pins: it is code the
/// page runs, so a copy is checked like a download.
Future<bool> _pinnedRuntime(Directory runtime, String expected) async {
  if (!await runtime.exists()) return false;
  final hashes = <String, String>{};
  await for (final entity in runtime.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final name = 'runtime/${entity.path.substring(runtime.path.length + 1).replaceAll(r'\', '/')}';
    hashes[name] = (await sha256.bind(entity.openRead()).first).toString();
  }
  return hashes.isNotEmpty && runtimeDigest(hashes) == expected;
}

Future<void> _copy(Directory from, Directory to) async {
  await for (final entity in from.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final target = File('${to.path}/${entity.path.substring(from.path.length + 1)}');
    await target.parent.create(recursive: true);
    await entity.copy(target.path);
  }
}

/// What the stage does for one page of the story ([type], [args] for
/// `stage.command`): listening while you speak; for hers, her mouth moving
/// about as long as reading it aloud takes, and a feeling the words make plain.
List<(String, Map<String, Object?>)> tavernStageCues({required bool you, required String text, String? marker}) {
  if (you) {
    return const [
      ('mood', {'mood': 'listening'}),
    ];
  }
  return [
    const ('mood', {'mood': 'idle'}),
    ('say', {'chars': text.runes.length}),
    // A marker ([表情:x]) first: one of the stage's feelings by name, or the
    // feeling its word names; else what the words show.
    if ((marker == null
                ? null
                : (_emotionWords.containsKey(marker.toLowerCase()) ? marker.toLowerCase() : tavernEmotionIn(marker))) ??
            tavernEmotionIn(text)
        case final emotion?)
      ('emotion', {'name': emotion}),
  ];
}

/// The feeling a paragraph names first, as one of the stage's emotions; null
/// when it names none. Words for a cold or bitter smile don't count as happy.
String? tavernEmotionIn(String text) {
  final plain = text.replaceAll(RegExp('冷笑|嘲笑|苦笑|讥笑|干笑|皮笑肉不笑|sneer', caseSensitive: false), '');
  int? first;
  String? found;
  for (final MapEntry(key: emotion, value: words) in _emotionWords.entries) {
    final at = RegExp(words, caseSensitive: false).firstMatch(plain)?.start;
    if (at != null && (first == null || at < first)) {
      first = at;
      found = emotion;
    }
  }
  return found;
}

const _emotionWords = {
  'happy': r'笑|开心|高兴|欣喜|雀跃|\bsmil|\blaugh|\bgrin|\bgiggl',
  'shy': r'脸红|害羞|羞涩|红了脸|耳根.{0,2}红|\bblush',
  'surprised': r'惊讶|吃惊|愣住|一愣|诧异|瞪大|\bgasp|\bsurprised|\bstartled',
  'angry': r'生气|愤怒|恼火|发火|怒|\bangry|\bglare',
  'sad': r'哭|泪|难过|伤心|哽咽|\bcr(y|ies|ied)\b|\btears|\bsob',
  'worried': r'担心|不安|紧张|忧虑|\bworr|\bnervous|\banxious',
  'confused': r'疑惑|困惑|歪头|不解|茫然|\bconfus|\bpuzzl|\bfrown',
};
