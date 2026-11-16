import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/io/gameplay_pack_codec.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('pack size accounting precedes inflation and catalog adoption', () async {
    final h = await ScriptFixture.open();
    final original = _zip();
    // The payloads stay tiny: inconsistent central sizes make any attempted
    // content read fail, so the specific size error proves metadata preflight.
    final oneLargeFile = _withSizes(original, {'unlisted.bin': 128 * 1024 * 1024 + 1});
    await expectLater(h.engine.importGameplayPack(oneLargeFile), throwsA(_sizeError()));
    final aggregate = _withSizes(original, {'declared.bin': 64 * 1024 * 1024, 'unlisted.bin': 64 * 1024 * 1024});
    await expectLater(h.engine.importGameplayPack(aggregate), throwsA(_sizeError()));
    expect(await h.engine.listGameplayPacks(), isEmpty);

    // A dishonest smaller size must still hit archive's actual decode limit.
    final understated = _withSizes(original, {'declared.bin': 1});
    expect(() => decodeGameplayPack(understated), throwsA(isA<ArchiveException>()));
    h.expectNoGeneration();
  });

  test('pack entry count and symbolic links are checked before content reads', () {
    final allowed = _zip(directories: 4093);
    expect(decodeGameplayPack(allowed).files.keys, unorderedEquals(['pack.json', 'declared.bin', 'unlisted.bin']));
    expect(
      () => decodeGameplayPack(_zip(directories: 4094)),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('4096 ZIP entries'))),
    );

    final link = _zip();
    final view = ByteData.sublistView(link);
    final header = _centralHeader(link, 'unlisted.bin');
    view.setUint16(header + 4, (3 << 8) | 20, Endian.little);
    view.setUint32(header + 38, 0xa1ff << 16, Endian.little);
    // ZipDecoder normally reads a link target before invoking its callback.
    // Its deliberately broken CRC would otherwise hide the symlink rejection.
    view.setUint32(header + 16, view.getUint32(header + 16, Endian.little) ^ 1, Endian.little);
    expect(
      () => decodeGameplayPack(link),
      throwsA(isA<FormatException>().having((error) => error.message, 'message', contains('symbolic links'))),
    );
  });

  test('bounded imports retain undeclared bytes and their content identity', () async {
    final h = await ScriptFixture.open();
    final original = _zip();
    final decoded = decodeGameplayPack(original);
    expect(decoded.files['unlisted.bin'], [7, 0, 255]);
    final installed = await h.engine.importGameplayPack(original);
    final resource = await h.engine.readGameplayPackResource(installed.ref, 'declared');
    expect(resource!.bytes, [1, 2, 3]);
    expect(await h.engine.readGameplayPackResource(installed.ref, 'unlisted.bin'), isNull);
    expect(await h.engine.exportInstalledGameplayPack(installed.ref), original);

    final changedUnlisted = _zip(unlisted: const [7, 0, 254]);
    expect(decodeGameplayPack(changedUnlisted).digest, isNot(decoded.digest));
    await expectLater(
      h.engine.importGameplayPack(changedUnlisted),
      throwsA(isA<TavernGameplayException>().having((error) => error.code, 'code', 'version_conflict')),
    );
    expect((await h.engine.listGameplayPacks()).single.ref.toJson(), installed.ref.toJson());
    expect(await h.engine.exportInstalledGameplayPack(installed.ref), original);
    h.expectNoGeneration();
  });
}

TypeMatcher<FormatException> _sizeError() =>
    isA<FormatException>().having((error) => error.message, 'message', contains('128 MiB uncompressed limit'));

Uint8List _zip({int directories = 0, List<int> unlisted = const [7, 0, 255]}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'pack.json',
        jsonEncode({
          'formatVersion': 1,
          'packId': 'bounded-pack',
          'packVersion': 'one',
          'resources': [
            {'localId': 'declared', 'kind': 'opaque', 'path': 'declared.bin'},
          ],
        }),
      ),
    )
    ..addFile(ArchiveFile.bytes('declared.bin', [1, 2, 3]))
    ..addFile(ArchiveFile.bytes('unlisted.bin', unlisted));
  for (var i = 0; i < directories; i++) {
    archive.addFile(ArchiveFile.directory('folder$i/'));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive, modified: DateTime.utc(2026, 11, 14)));
}

Uint8List _withSizes(Uint8List original, Map<String, int> sizes) {
  final bytes = Uint8List.fromList(original);
  final view = ByteData.sublistView(bytes);
  for (final entry in sizes.entries) {
    view.setUint32(_centralHeader(bytes, entry.key) + 24, entry.value, Endian.little);
  }
  return bytes;
}

// These fixtures are small, non-ZIP64 archives with no archive comment.
int _centralHeader(Uint8List bytes, String name) {
  final view = ByteData.sublistView(bytes);
  var at = view.getUint32(bytes.length - 6, Endian.little);
  while (view.getUint32(at, Endian.little) == 0x02014b50) {
    final nameLength = view.getUint16(at + 28, Endian.little);
    final extraLength = view.getUint16(at + 30, Endian.little);
    final commentLength = view.getUint16(at + 32, Endian.little);
    final actual = utf8.decode(Uint8List.sublistView(bytes, at + 46, at + 46 + nameLength));
    if (actual == name) {
      return at;
    }
    at += 46 + nameLength + extraLength + commentLength;
  }
  throw StateError('Missing fixture central-directory entry: $name');
}
