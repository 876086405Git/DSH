// Decoded pet sheets, shared by every sprite on screen. Deepy's 5× sheets are
// ~139 MB decoded in all (docs/design/pets.md §3.3), so nothing is decoded
// ahead: a sheet is decoded when it first plays, the current pet's idle main
// sheet stays, and the rest live in a small LRU.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'pet_pack.dart';

/// Process-wide cache of decoded sheets. Callers get their own handle
/// ([ui.Image.clone]) and dispose it when done, so evicting a sheet never
/// pulls it from under a sprite that still draws it.
class PetSheets {
  PetSheets._();

  static final instance = PetSheets._();

  /// Sheets kept besides the pinned ones.
  static const capacity = 3;

  final LinkedHashMap<String, ui.Image> _images = LinkedHashMap();
  final Map<String, _Decode> _loading = {};
  final Set<String> _pinned = {};

  static String keyOf(PetPack pack, PetAnimation anim) => '${pack.id}/${anim.sheet}';

  /// Off: nothing decodes, so no pet is drawn (widget tests other than the
  /// pet's own switch it off in `flutter_test_config.dart`).
  @visibleForTesting
  static bool enabled = true;

  /// A handle to [anim]'s sheet when it is already decoded; null otherwise.
  ui.Image? peek(PetPack pack, PetAnimation anim) {
    if (!enabled) return null;
    final key = keyOf(pack, anim);
    final image = _images.remove(key);
    if (image == null) return null;
    _images[key] = image;
    return image.clone();
  }

  /// A handle to [anim]'s sheet, decoding it first if needed.
  Future<ui.Image> load(PetPack pack, PetAnimation anim, AssetBundle bundle) async {
    if (!enabled) throw StateError('pet sheets are off');
    final ready = peek(pack, anim);
    if (ready != null) return ready;
    final key = keyOf(pack, anim);
    final job =
        _loading[key] ??
        _start(key, () async {
          // A brought pet's sheets are files; the built-in ones are assets.
          if (pack.dir case final dir?) return File('$dir/${anim.sheet}').readAsBytes();
          final data = await bundle.load('${PetPack.folder(pack.id)}/${anim.sheet}');
          return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        });
    try {
      await job.done;
    } on Object {
      // The old files' read, forgotten meanwhile, failed (they were being
      // swapped out): no reason the new ones won't read. A current job's
      // failure is the caller's to know.
      if (job.stale) return load(pack, anim, bundle);
      rethrow;
    }
    // Forgotten meanwhile (the pet brought again or removed): its files
    // changed, so read them again. Evicted by another decode: decode it again.
    final kept = job.stale ? null : _images[key];
    if (kept == null) return load(pack, anim, bundle);
    return kept.clone();
  }

  /// Keeps [anim]'s sheet decoded for good (idle's main animation) while
  /// [pack] is the pet. The pet before it goes back to the LRU, so trying
  /// pet after pet doesn't keep every one of them decoded.
  void pin(PetPack pack, PetAnimation anim) {
    _pinned
      ..clear()
      ..add(keyOf(pack, anim));
    _evict();
  }

  /// No pet shown: the last one's idle sheet goes back to the LRU too.
  void unpin() {
    _pinned.clear();
    _evict();
  }

  _Decode _start(String key, Future<Uint8List> Function() read) {
    final job = _Decode();
    _loading[key] = job;
    job.done = _decode(key, job, read);
    return job;
  }

  Future<void> _decode(String key, _Decode job, Future<Uint8List> Function() read) async {
    try {
      final codec = await ui.instantiateImageCodec(await read());
      final frame = await codec.getNextFrame();
      codec.dispose();
      // Forgotten while it decoded: the old file's picture never lands.
      if (job.stale) {
        frame.image.dispose();
        return;
      }
      _images.remove(key)?.dispose();
      _images[key] = frame.image;
      _evict();
    } finally {
      // Only its own slot: after a forget, a newer decode may hold the key.
      unawaited(
        Future<void>.microtask(() {
          if (identical(_loading[key], job)) _loading.remove(key);
        }),
      );
    }
  }

  void _evict() {
    var unpinned = _images.keys.where((k) => !_pinned.contains(k)).length;
    for (final key in [..._images.keys]) {
      if (unpinned <= capacity) break;
      if (_pinned.contains(key)) continue;
      _images.remove(key)?.dispose();
      unpinned--;
    }
  }

  /// The system is short of memory: only the pinned sheets stay decoded. A
  /// sprite still drawing one keeps its own handle; the next load decodes it
  /// again.
  void trim() {
    for (final key in [..._images.keys]) {
      if (!_pinned.contains(key)) _images.remove(key)?.dispose();
    }
  }

  /// Drops [packId]'s sheets: a brought pet replaced or removed. Its decodes
  /// still running never land, and no new load waits on them.
  void forget(String packId) {
    final prefix = '$packId/';
    for (final key in [..._images.keys]) {
      if (key.startsWith(prefix)) _images.remove(key)?.dispose();
    }
    _pinned.removeWhere((key) => key.startsWith(prefix));
    _loading.removeWhere((key, job) {
      if (!key.startsWith(prefix)) return false;
      job.stale = true;
      return true;
    });
  }

  /// Drops everything (tests).
  void clear() {
    for (final image in _images.values) {
      image.dispose();
    }
    _images.clear();
    _pinned.clear();
    for (final job in _loading.values) {
      job.stale = true;
    }
    _loading.clear();
  }
}

/// One sheet decoding. [PetSheets.forget] marks it [stale]: its picture is
/// dropped when it comes, and whoever waited on it loads again.
class _Decode {
  bool stale = false;
  late final Future<void> done;
}
