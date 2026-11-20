import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/state/image_snapshots.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

Future<Uint8List> _unexpectedLoad() async => throw StateError('Historical image must not reload');

void main() {
  late Directory root;
  late ImageSnapshots store;

  Future<File> get({
    ImageSnapshots? from,
    String host = 'host',
    String session = 'session',
    int turn = 1,
    String path = '/workspace/image.png',
    String text = 'original',
    Future<Uint8List> Function()? load,
    int maxBytes = 20 * 1024 * 1024,
  }) => (from ?? store).get(
    host: host,
    sessionId: session,
    turn: turn,
    path: path,
    load: load ?? () async => _bytes(text),
    maxBytes: maxBytes,
  );

  Future<List<File>> contents() async {
    final entries = await Directory('${root.path}/image-snapshots/contents').list(followLinks: false).toList();
    return entries.whereType<File>().toList();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('image-snapshots-test-');
    store = ImageSnapshots(root: () async => root);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('provider can be replaced for the UI without a platform directory', () {
    final container = ProviderContainer(overrides: [imageSnapshotsProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);
    expect(container.read(imageSnapshotsProvider), same(store));
  });

  test('same turn stays fixed after source changes; another turn reads new bytes', () async {
    final source = File('${root.path}/source.png');
    await source.writeAsBytes(_bytes('before'));
    var calls = 0;
    Future<Uint8List> load() {
      calls++;
      return source.readAsBytes();
    }

    final first = await get(load: load);
    await source.writeAsBytes(_bytes('after'));
    final again = await get(load: load);
    final next = await get(turn: 2, load: load);

    expect(again.path, first.path);
    expect(await first.readAsString(), 'before');
    expect(await next.readAsString(), 'after');
    expect(next.path, isNot(first.path));
    expect(calls, 2);
    expect(await source.readAsString(), 'after');
  });

  test('host, session, turn and full path independently scope the first read', () async {
    final requests = <Future<File>>[
      get(text: 'base'),
      get(host: 'other-host', text: 'host'),
      get(session: 'other-session', text: 'session'),
      get(turn: 2, text: 'turn'),
      get(path: '/workspace/other.png', text: 'path'),
      get(path: '/workspace/image.png ', text: 'space'),
    ];
    final files = await Future.wait(requests);
    expect(await Future.wait(files.map((file) => file.readAsString())), [
      'base',
      'host',
      'session',
      'turn',
      'path',
      'space',
    ]);
    expect(files.map((file) => file.path).toSet(), hasLength(6));
    final pairA = await get(host: 'a/b', session: 'c', text: 'pair-a');
    final pairB = await get(host: 'a', session: 'b/c', text: 'pair-b');
    expect(await pairA.readAsString(), 'pair-a');
    expect(await pairB.readAsString(), 'pair-b');
  });

  test('identical bytes share the SHA256 content file across turns and sessions', () async {
    final first = await get(text: 'same');
    final next = await get(turn: 2, text: 'same');
    final other = await get(host: 'other', session: 'other', text: 'same');
    expect(next.path, first.path);
    expect(other.path, first.path);
    expect(first.uri.pathSegments.last, sha256.convert(_bytes('same')).toString());
    expect(await contents(), hasLength(1));
    final index = await File('${root.path}/image-snapshots/index.json').readAsString();
    expect(index, isNot(contains('/workspace/image.png')));
  });

  test('a replacement store reads persisted references, not current source bytes', () async {
    final first = await get(text: 'saved');
    final reopened = ImageSnapshots(root: () async => root);
    final again = await get(from: reopened, load: _unexpectedLoad);
    expect(again.path, first.path);
    expect(await again.readAsString(), 'saved');
  });

  test('content budget counts a shared hash only once', () async {
    store = ImageSnapshots(root: () async => root, maxBytes: 4);
    final first = await get(text: 'same');
    await get(turn: 2, text: 'same');
    await get(session: 'other', text: 'same');
    expect(await get(load: _unexpectedLoad).then((file) => file.readAsString()), 'same');
    expect(await first.exists(), isTrue);
    expect(await contents(), hasLength(1));
  });

  test('content LRU survives reopening; reclaimed keys never load another image', () async {
    store = ImageSnapshots(root: () async => root, maxBytes: 8);
    final a = await get(turn: 1, text: 'aaaa');
    final b = await get(turn: 2, text: 'bbbb');
    await get(turn: 1, load: _unexpectedLoad);
    final reopened = ImageSnapshots(root: () async => root, maxBytes: 8);
    final c = await get(from: reopened, turn: 3, text: 'cccc');

    expect(await a.exists(), isTrue);
    expect(await b.exists(), isFalse);
    expect(await c.readAsString(), 'cccc');
    await expectLater(get(from: reopened, turn: 2, load: _unexpectedLoad), throwsA(isA<ImageSnapshotMissing>()));

    // Reintroducing the same hash is safe for a new turn, not for the old key.
    final replacement = await get(from: reopened, turn: 4, text: 'bbbb');
    expect(await replacement.readAsString(), 'bbbb');
    final again = ImageSnapshots(root: () async => root, maxBytes: 8);
    await expectLater(get(from: again, turn: 2, load: _unexpectedLoad), throwsA(isA<ImageSnapshotMissing>()));
    final sizes = await Future.wait((await contents()).map((file) => file.length()));
    expect(sizes.fold<int>(0, (a, b) => a + b), lessThanOrEqualTo(8));
  });

  test('external content removal reports missing without falling back to the loader', () async {
    final first = await get();
    await first.delete();
    final reopened = ImageSnapshots(root: () async => root);
    await expectLater(get(from: reopened, load: _unexpectedLoad), throwsA(isA<ImageSnapshotMissing>()));
  });

  test('removeSession preserves shared content and other hosts or sessions', () async {
    final shared = await get(text: 'shared');
    final unique = await get(turn: 2, text: 'unique');
    await get(session: 'other', text: 'shared');
    final otherHost = await get(host: 'other', text: 'host');
    final unrelated = File('${root.path}/unrelated.txt');
    await unrelated.writeAsString('keep');

    await store.removeSession('host', 'session');
    expect(await unique.exists(), isFalse);
    expect(await shared.exists(), isTrue);
    expect(await get(session: 'other', load: _unexpectedLoad).then((file) => file.readAsString()), 'shared');
    expect(await otherHost.readAsString(), 'host');
    expect(await unrelated.readAsString(), 'keep');

    final reopened = ImageSnapshots(root: () async => root);
    final newSession = await get(from: reopened, text: 'new');
    expect(await newSession.readAsString(), 'new');
    await reopened.removeSession('host', 'session');
    await reopened.removeSession('host', 'session');
    await reopened.removeSession('host', 'other');
    expect(await shared.exists(), isFalse);
    expect(await otherHost.exists(), isTrue);
    await reopened.removeSession('other', 'session');
    expect(await contents(), isEmpty);
  });

  test('loader failure does not fix a key or poison later operations', () async {
    final failure = StateError('read failed');
    await expectLater(get(load: () async => throw failure), throwsA(same(failure)));
    final retried = await get(text: 'retry');
    expect(await retried.readAsString(), 'retry');
    expect(await get(load: _unexpectedLoad).then((file) => file.readAsString()), 'retry');
  });

  test('root and persistence failures can be retried without a partial reference', () async {
    var failRoot = true;
    store = ImageSnapshots(
      root: () async {
        if (failRoot) throw const FileSystemException('root unavailable');
        return root;
      },
    );
    await expectLater(get(load: _unexpectedLoad), throwsA(isA<FileSystemException>()));
    failRoot = false;
    final blocker = Directory('${root.path}/image-snapshots/index.json');
    await blocker.create(recursive: true);
    await expectLater(get(text: 'blocked'), throwsA(isA<FileSystemException>()));
    await blocker.delete();
    expect(await get(text: 'ready').then((file) => file.readAsString()), 'ready');
  });

  test('failed index commit does not leave a fixed key or a staging file', () async {
    final blocker = Directory('${root.path}/image-snapshots/index.json.tmp');
    await blocker.create(recursive: true);
    await expectLater(get(text: 'failed'), throwsA(isA<FileSystemException>()));
    await blocker.delete();
    expect(await get(text: 'retried').then((file) => file.readAsString()), 'retried');
    expect(await root.list(recursive: true).where((file) => file.path.endsWith('.tmp')).toList(), isEmpty);
  });

  test('single image limit rejects before binding and permits a smaller retry', () async {
    await expectLater(get(text: '12345', maxBytes: 4), throwsA(isA<ImageSnapshotTooLarge>()));
    expect(await contents(), isEmpty);
    final first = await get(text: '1234', maxBytes: 4);
    await expectLater(get(maxBytes: 3, load: _unexpectedLoad), throwsA(isA<ImageSnapshotTooLarge>()));
    expect(await get(maxBytes: 4, load: _unexpectedLoad).then((file) => file.readAsString()), '1234');
    expect(await first.exists(), isTrue);
  });

  test('an image larger than the whole content budget cannot evict itself into success', () async {
    store = ImageSnapshots(root: () async => root, maxBytes: 3);
    await expectLater(get(text: '1234'), throwsA(isA<ImageSnapshotTooLarge>()));
    expect(await get(text: '123').then((file) => file.readAsString()), '123');
  });

  test('concurrent identical reads share one loader and the same immutable file', () async {
    final entered = Completer<void>();
    final bytes = Completer<Uint8List>();
    var calls = 0;
    Future<Uint8List> load() {
      calls++;
      entered.complete();
      return bytes.future;
    }

    final first = get(load: load);
    await entered.future;
    final second = get(load: load);
    bytes.complete(_bytes('shared'));
    final files = await Future.wait([first, second]);
    expect(calls, 1);
    expect(files[0].path, files[1].path);
    expect(await files[0].readAsString(), 'shared');
    expect(await contents(), hasLength(1));
  });

  test('concurrent failed reads share the error and the next call can retry', () async {
    final entered = Completer<void>();
    final bytes = Completer<Uint8List>();
    var calls = 0;
    Future<Uint8List> load() {
      calls++;
      entered.complete();
      return bytes.future;
    }

    final first = get(load: load);
    await entered.future;
    final second = get(load: load);
    final failure = StateError('load failed');
    final observations = [expectLater(first, throwsA(same(failure))), expectLater(second, throwsA(same(failure)))];
    bytes.completeError(failure);
    await Future.wait(observations);
    expect(calls, 1);
    expect(await get(text: 'retry').then((file) => file.readAsString()), 'retry');
  });

  test('stores sharing a root serialize writes without losing references', () async {
    final other = ImageSnapshots(root: () async => root);
    final files = await Future.wait([
      get(text: 'one'),
      get(from: other, turn: 2, text: 'two'),
      get(from: other, turn: 3, text: 'one'),
    ]);
    expect(files[0].path, files[2].path);
    expect(await get(from: other, load: _unexpectedLoad).then((file) => file.readAsString()), 'one');
    expect(await get(turn: 2, load: _unexpectedLoad).then((file) => file.readAsString()), 'two');
    expect(await contents(), hasLength(2));
  });

  test('a slow load does not block cached keys across sessions hosts stores or roots', () async {
    await get(text: 'cached');
    await get(session: 'other', text: 'session');
    await get(host: 'other', text: 'host');
    final otherRoot = await root.createTemp('other-root-');
    final separate = ImageSnapshots(root: () async => otherRoot);
    await get(from: separate, text: 'root');
    final reopened = ImageSnapshots(root: () async => root);
    final entered = Completer<void>();
    final bytes = Completer<Uint8List>();
    final slow = get(
      turn: 2,
      load: () {
        entered.complete();
        return bytes.future;
      },
    );
    await entered.future;
    final reads = [
      get(load: _unexpectedLoad),
      get(from: reopened, load: _unexpectedLoad),
      get(session: 'other', load: _unexpectedLoad),
      get(host: 'other', load: _unexpectedLoad),
      get(from: separate, load: _unexpectedLoad),
    ];
    try {
      final files = await Future.wait(reads).timeout(const Duration(seconds: 5));
      expect(await Future.wait(files.map((file) => file.readAsString())), [
        'cached',
        'cached',
        'session',
        'host',
        'root',
      ]);
      await separate.removeSession('host', 'session').timeout(const Duration(seconds: 5));
      expect(bytes.isCompleted, isFalse);
    } finally {
      bytes.complete(_bytes('slow'));
      await Future.wait([slow, ...reads]);
    }
  });

  test('competing stores recheck a key before publishing a late source load', () async {
    final entered = Completer<void>();
    final bytes = Completer<Uint8List>();
    final slow = get(
      load: () {
        entered.complete();
        return bytes.future;
      },
    );
    await entered.future;
    final other = ImageSnapshots(root: () async => root);
    final winner = get(from: other, text: 'first successful snapshot');
    try {
      final file = await winner.timeout(const Duration(seconds: 5));
      expect(await file.readAsString(), 'first successful snapshot');
      expect(bytes.isCompleted, isFalse);
    } finally {
      bytes.complete(_bytes('late different bytes'));
      await Future.wait([slow, winner]);
    }
    expect((await slow).path, (await winner).path);
    expect(await (await slow).readAsString(), 'first successful snapshot');
    expect(await contents(), hasLength(1));
  });

  test('cleanup finishes before a blocked load and late bytes cannot revive the session', () async {
    final entered = Completer<void>();
    final bytes = Completer<Uint8List>();
    final first = get(
      load: () {
        entered.complete();
        return bytes.future;
      },
    );
    final observed = first.then<Object>((file) => file, onError: (Object error, StackTrace _) => error);
    await entered.future;
    final other = ImageSnapshots(root: () async => root);
    final cleanup = other.removeSession('host', 'session');
    try {
      await cleanup.timeout(const Duration(seconds: 5));
      expect(bytes.isCompleted, isFalse);
      expect(await contents(), isEmpty);
      // A new request must not join the cancelled request in the old instance.
      expect(await get(text: 'new').timeout(const Duration(seconds: 5)).then((file) => file.readAsString()), 'new');
    } finally {
      bytes.complete(_bytes('late old'));
      await observed;
      await cleanup;
    }
    expect(await observed, isA<ImageSnapshotMissing>());
    expect(await get(from: other, load: _unexpectedLoad).then((file) => file.readAsString()), 'new');
    expect(await contents(), hasLength(1));
  });
}
