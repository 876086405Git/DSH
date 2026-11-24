// PetSheets.forget against decodes already running: a brought pet imported
// again must never show the old file's picture.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'pet_library_test.dart' show png;

/// Each sheet read waits until the test hands it bytes.
class _GatedBundle extends CachingAssetBundle {
  final reads = <Completer<ByteData>>[];

  @override
  Future<ByteData> load(String key) {
    final read = Completer<ByteData>();
    reads.add(read);
    return read.future;
  }

  void give(int read, Uint8List bytes) => reads[read].complete(ByteData.sublistView(bytes));

  void fail(int read) => reads[read].completeError(const FileSystemException('gone'));
}

const _anim = PetAnimation(
  name: 'idle',
  sheet: 'idle.png',
  frameWidth: 8,
  frameHeight: 8,
  cols: 1,
  box: Rect.fromLTWH(0, 0, 8, 8),
  frames: [PetFrame(0, 100)],
);

const _pack = PetPack(
  id: 'user-cat',
  name: '小猫',
  canvas: Size(8, 8),
  anchorX: 4,
  baseline: 8,
  contentBox: Rect.fromLTWH(0, 0, 8, 8),
  animations: {'idle': _anim},
  states: {
    'idle': ['idle'],
  },
);

/// Every sheet reads at once.
class _ReadyBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => ByteData.sublistView(png(8, 8));
}

PetPack _petOf(String id) => PetPack(
  id: id,
  name: id,
  canvas: const Size(8, 8),
  anchorX: 4,
  baseline: 8,
  contentBox: const Rect.fromLTWH(0, 0, 8, 8),
  animations: const {'idle': _anim},
  states: const {
    'idle': ['idle'],
  },
);

void main() {
  setUp(() => PetSheets.enabled = true);
  tearDown(() {
    PetSheets.instance.clear();
    PetSheets.enabled = false;
  });

  testWidgets('a decode running when its pet is forgotten never lands, and nothing new waits on it', (tester) async {
    await tester.runAsync(() async {
      final bundle = _GatedBundle();
      final sheets = PetSheets.instance;
      final before = sheets.load(_pack, _anim, bundle);
      await pumpEventQueue();
      expect(bundle.reads, hasLength(1));

      // Imported again: the next load reads the new file, it doesn't join the old read.
      sheets.forget(_pack.id);
      final after = sheets.load(_pack, _anim, bundle);
      await pumpEventQueue();
      expect(bundle.reads, hasLength(2));

      bundle.give(1, png(16, 8));
      final fresh = await after;
      expect(fresh.width, 16);
      fresh.dispose();

      // The old file's decode finishes last: it must not replace the new picture.
      bundle.give(0, png(8, 8));
      final late = await before;
      expect(late.width, 16, reason: 'whoever waited on the old read gets the new picture');
      late.dispose();
      final cached = sheets.peek(_pack, _anim)!;
      expect(cached.width, 16);
      cached.dispose();
    });
  });

  testWidgets("an old read that fails after the forget doesn't fail its waiters: they get the new one", (tester) async {
    await tester.runAsync(() async {
      final bundle = _GatedBundle();
      final sheets = PetSheets.instance;
      final before = sheets.load(_pack, _anim, bundle);
      await pumpEventQueue();
      sheets.forget(_pack.id);
      // The old files went away under the read.
      bundle.fail(0);
      await pumpEventQueue();
      expect(bundle.reads, hasLength(2), reason: 'read again');
      bundle.give(1, png(16, 8));
      final image = await before;
      expect(image.width, 16);
      image.dispose();
    });
  });

  testWidgets('a read that fails for the current files still fails', (tester) async {
    await tester.runAsync(() async {
      final bundle = _GatedBundle();
      final load = PetSheets.instance.load(_pack, _anim, bundle);
      await pumpEventQueue();
      bundle.fail(0);
      await expectLater(load, throwsA(isA<FileSystemException>()));
      expect(bundle.reads, hasLength(1));
    });
  });

  testWidgets("a pet switched away from keeps its idle sheet only as one of the LRU's", (tester) async {
    await tester.runAsync(() async {
      final sheets = PetSheets.instance;
      final bundle = _ReadyBundle();
      final first = _petOf('first'), second = _petOf('second');
      sheets.pin(first, _anim);
      (await sheets.load(first, _anim, bundle)).dispose();
      sheets.pin(second, _anim);
      (await sheets.load(second, _anim, bundle)).dispose();
      for (final id in ['a', 'b', 'c']) {
        (await sheets.load(_petOf(id), _anim, bundle)).dispose();
      }
      expect(sheets.peek(first, _anim), isNull);
      sheets.peek(second, _anim)!.dispose();
    });
  });

  testWidgets('without a forget, loads of one sheet share one read', (tester) async {
    await tester.runAsync(() async {
      final bundle = _GatedBundle();
      final a = PetSheets.instance.load(_pack, _anim, bundle);
      final b = PetSheets.instance.load(_pack, _anim, bundle);
      await pumpEventQueue();
      expect(bundle.reads, hasLength(1));
      bundle.give(0, png(8, 8));
      for (final image in [await a, await b]) {
        expect(image.width, 8);
        image.dispose();
      }
    });
  });

  testWidgets('a trim (memory pressure) drops the sheets nobody pins; a sprite keeps its own handle', (tester) async {
    await tester.runAsync(() async {
      final sheets = PetSheets.instance;
      final bundle = _ReadyBundle();
      final pinned = _petOf('pinned'), other = _petOf('other');
      sheets.pin(pinned, _anim);
      (await sheets.load(pinned, _anim, bundle)).dispose();
      final drawing = await sheets.load(other, _anim, bundle);
      sheets.trim();
      expect(sheets.peek(other, _anim), isNull);
      sheets.peek(pinned, _anim)!.dispose();
      expect(drawing.debugDisposed, isFalse);
      drawing.dispose();
    });
  });
}
