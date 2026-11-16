// 自定义启动画面的导入：认文件头、量边缘颜色、按上限拷贝（视频 30 MB，图片 8 MB）、坏文件拒收、
// 视频不限时长、
// 换新时删旧文件；配置的读写与回退。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/launch/custom_launch.dart';
import 'package:dsh_app/launch/launch_import.dart';
import 'package:dsh_app/launch/launch_media.dart';
import 'package:dsh_app/plugins/native/native_effects.dart';
import 'package:dsh_app/plugins/native/native_file_platform.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements NativeFilePlatform {
  _Platform(this.files);

  final List<NativeSelectedFile> files;
  PickFileEffect? asked;
  final cancelled = <String>[];

  @override
  Future<bool> supported() async => true;

  @override
  Future<List<NativeSelectedFile>> pick(PickFileEffect effect) async {
    asked = effect;
    return files;
  }

  @override
  Future<void> cancel(String owner) async => cancelled.add(owner);
}

NativeSelectedFile _file(Uint8List bytes, {int? length}) => NativeSelectedFile(
  name: 'pick',
  length: length ?? bytes.length,
  openRead: () => Stream.fromIterable([
    for (var i = 0; i < bytes.length; i += 4096) bytes.sublist(i, i + 4096 > bytes.length ? bytes.length : i + 4096),
  ]),
);

/// A [w] × [h] PNG: [inner] in the middle, [edge] in a frame around it (transparent when null).
Future<Uint8List> _png(int w, int h, {Color? edge, Color inner = const Color(0xFF4060A0)}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  if (edge != null) canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = edge);
  // A frame an eighth of the short side: still the edge after the 64 px read.
  final f = (w < h ? w : h) / 8;
  canvas.drawRect(Rect.fromLTWH(f, f, w - 2 * f, h - 2 * f), Paint()..color = inner);
  final image = await recorder.endRecording().toImage(w, h);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('launch-import');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  LaunchImport importer(List<NativeSelectedFile> files, {ClipProber? probe}) =>
      LaunchImport(platform: _Platform(files), probeClip: probe ?? (_, _) async => null, directory: () async => dir);

  group('file types', () {
    test('known by their first bytes, not their names', () {
      Uint8List h(List<int> bytes) => Uint8List.fromList([...bytes, ...List.filled(32, 0)]);
      expect(LaunchFileType.sniff(h([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), LaunchFileType.png);
      expect(LaunchFileType.sniff(h([0xFF, 0xD8, 0xFF, 0xE0])), LaunchFileType.jpeg);
      expect(LaunchFileType.sniff(h('GIF89a'.codeUnits)), LaunchFileType.gif);
      expect(LaunchFileType.sniff(h([...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBP'.codeUnits])), LaunchFileType.webp);
      expect(LaunchFileType.sniff(h([0, 0, 0, 0x18, ...'ftypmp42'.codeUnits])), LaunchFileType.mp4);
      expect(LaunchFileType.sniff(h([0x1A, 0x45, 0xDF, 0xA3])), LaunchFileType.webm);
      expect(LaunchFileType.sniff(h('%PDF-1.7'.codeUnits)), isNull);
      expect(LaunchFileType.sniff(Uint8List(2)), isNull);
    });
  });

  group('edge colour', () {
    test('the mean of the outer ring', () {
      // 3 × 3: the ring red, the middle blue.
      final rgba = Uint8List.fromList([
        for (var i = 0; i < 9; i++) ...(i == 4 ? [0, 0, 255, 255] : [200, 10, 20, 255]),
      ]);
      final (edge, see) = edgeColour(rgba, 3, 3);
      expect(see, isFalse);
      expect(edge, 0xFFC80A14);
    });

    test('a see-through ring has no colour: a cut-out', () {
      final rgba = Uint8List.fromList([
        for (var i = 0; i < 16; i++) ...(i == 5 || i == 6 || i == 9 || i == 10 ? [0, 0, 255, 255] : [0, 0, 0, 0]),
      ]);
      final (edge, see) = edgeColour(rgba, 4, 4);
      expect(edge, isNull);
      expect(see, isTrue);
    });
  });

  group('import', () {
    test('a photo: copied into the app, its size, its edge, filling the screen', () async {
      final png = await _png(300, 600, edge: const Color(0xFF102030));
      final platform = _Platform([_file(png)]);
      final (custom, problem) = await LaunchImport(platform: platform, directory: () async => dir).pick();
      expect(problem, isNull);
      expect(custom!.kind, LaunchMediaKind.image);
      expect((custom.width, custom.height), (300, 600));
      expect(custom.fit, LaunchFit.fill);
      expect(custom.backdrop, LaunchBackdrop.edge);
      expect(custom.edge, 0xFF102030);
      expect(custom.path, startsWith(dir.path));
      expect(custom.path, endsWith('.png'));
      expect(File(custom.path).readAsBytesSync(), png);
      // The system picker offered photos and videos, one file, 30 MB: the app's own budget.
      final asked = platform.asked!;
      expect((asked.visual, asked.images, asked.maxFiles, asked.maxBytes), (true, true, 1, CustomLaunch.maxVideoBytes));
      expect(asked.own, isTrue, reason: 'a plugin\'s 8 MB budget would refuse it natively');
      // Its size is kept (the notice says it once).
      expect(custom.bytes, png.length);
      expect(platform.cancelled, [asked.request]);
      // Nothing else left behind.
      expect(dir.listSync().map((e) => e.path), [custom.path]);
    });

    test('a cut-out (transparent edge) sits whole and centred on the launch colour', () async {
      final png = await _png(200, 200);
      final (custom, _) = await importer([_file(png)]).pick();
      expect(custom!.fit, LaunchFit.center);
      expect(custom.backdrop, LaunchBackdrop.auto);
      expect(custom.edge, isNull);
    });

    test('replacing keeps the old fit and background choice, and the old file until it is saved', () async {
      final first = (await importer([
        _file(await _png(100, 100, edge: const Color(0xFF000000))),
      ]).pick()).$1!.copyWith(backdrop: LaunchBackdrop.white);
      final (second, _) = await LaunchImport(
        platform: _Platform([_file(await _png(120, 80, edge: const Color(0xFFFFFFFF)))]),
        directory: () async => dir,
        now: () => DateTime(2030),
      ).pick(previous: first);
      expect(File(first.path).existsSync(), isTrue, reason: 'the controller removes it once the new one is saved');
      expect(File(second!.path).existsSync(), isTrue);
      expect(second.backdrop, LaunchBackdrop.white);
    });

    test('over 30 MB is refused, before or while copying', () async {
      final big = Uint8List(CustomLaunch.maxVideoBytes + 1);
      expect((await importer([_file(big)]).pick()).$2, LaunchImportProblem.overLimit);
      // A provider that under-reports its size.
      expect((await importer([_file(big, length: 10)]).pick()).$2, LaunchImportProblem.overLimit);
      expect(dir.listSync(), isEmpty);
    });

    test('a picture over 8 MB is refused; a clip of 20 MB is kept', () async {
      final png = await _png(64, 64, edge: const Color(0xFF000000));
      final picture = Uint8List(CustomLaunch.maxImageBytes + 1)..setRange(0, png.length, png);
      expect((await importer([_file(picture)]).pick()).$2, LaunchImportProblem.tooLarge);
      expect(dir.listSync(), isEmpty);
      final clip = Uint8List(20 * 1024 * 1024)..setRange(0, 12, [0, 0, 0, 0x18, ...'ftypmp42'.codeUnits]);
      final (custom, problem) = await importer(
        [_file(clip)],
        probe: (path, p) async {
          File(p).writeAsBytesSync(await _png(9, 16));
          return const ClipProbe(duration: Duration(seconds: 8), width: 1080, height: 1920);
        },
      ).pick();
      expect(problem, isNull);
      expect(custom!.bytes, 20 * 1024 * 1024);
    });

    test('something that isn\'t a picture or a clip is refused', () async {
      final (custom, problem) = await importer([_file(Uint8List.fromList(utf8.encode('%PDF-1.7 not a picture')))])
          .pick();
      expect(custom, isNull);
      expect(problem, LaunchImportProblem.unsupported);
      expect(dir.listSync(), isEmpty);
    });

    test('a damaged picture is refused', () async {
      final png = await _png(64, 64, edge: const Color(0xFF000000));
      final broken = Uint8List.fromList(png.sublist(0, 40));
      expect((await importer([_file(broken)]).pick()).$2, LaunchImportProblem.unreadable);
      expect(dir.listSync(), isEmpty);
    });

    test('a clip: probed for length, its first frame kept as the poster', () async {
      final mp4 = Uint8List.fromList([0, 0, 0, 0x18, ...'ftypmp42'.codeUnits, ...List.filled(64, 0)]);
      final poster = await _png(90, 160, edge: const Color(0xFF223344));
      String? posterPath;
      final (custom, problem) = await importer(
        [_file(mp4)],
        probe: (path, p) async {
          posterPath = p;
          File(p).writeAsBytesSync(poster);
          return const ClipProbe(duration: Duration(milliseconds: 2900), width: 1080, height: 1920);
        },
      ).pick();
      expect(problem, isNull);
      expect(custom!.kind, LaunchMediaKind.video);
      expect(custom.poster, posterPath);
      expect((custom.width, custom.height), (1080, 1920));
      expect(custom.edge, 0xFF223344);
      expect(custom.durationMs, 2900);
    });

    test('a clip of any length is kept (it plays whole, a tap skips it)', () async {
      final mp4 = Uint8List.fromList([0, 0, 0, 0x18, ...'ftypisom'.codeUnits, ...List.filled(64, 0)]);
      final (custom, problem) = await importer(
        [_file(mp4)],
        probe: (path, p) async {
          File(p).writeAsBytesSync(await _png(9, 16));
          return const ClipProbe(duration: Duration(seconds: 42), width: 1080, height: 1920);
        },
      ).pick();
      expect(problem, isNull);
      expect(custom!.durationMs, 42000);
    });

    test('cancelled', () async {
      expect((await importer(const []).pick()).$2, LaunchImportProblem.cancelled);
    });
  });

  group('stored', () {
    test('round trip, and a missing file reads as none', () async {
      final file = File('${dir.path}/custom-1.png')..writeAsBytesSync(await _png(10, 10));
      final custom = CustomLaunch(
        kind: LaunchMediaKind.image,
        path: file.path,
        width: 10,
        height: 10,
        fit: LaunchFit.center,
        backdrop: LaunchBackdrop.black,
        on: false,
      );
      await CustomLaunch.save(custom);
      expect(await CustomLaunch.load(), custom);
      file.deleteSync();
      expect(await CustomLaunch.load(), isNull);
    });

    test('framing (zoom, alignX, alignY) round trips and clamps out-of-range values', () async {
      final file = File('${dir.path}/custom-frame.png')..writeAsBytesSync(await _png(10, 10));
      final framed = CustomLaunch(
        kind: LaunchMediaKind.image,
        path: file.path,
        width: 10,
        height: 10,
        zoom: 2.5,
        alignX: -0.4,
        alignY: 0.75,
      );
      await CustomLaunch.save(framed);
      expect(await CustomLaunch.load(), framed);

      final clamped = CustomLaunch.fromJson({...framed.toJson(), 'zoom': 99, 'alignX': -5, 'alignY': 3})!;
      expect((clamped.zoom, clamped.alignX, clamped.alignY), (CustomLaunch.maxZoom, -1.0, 1.0));
    });

    test('garbage reads as none', () async {
      SharedPreferences.setMockInitialValues({CustomLaunch.prefsKey: '{"kind": "nope"'});
      expect(await CustomLaunch.load(), isNull);
    });

    test('background per choice; auto follows the system', () {
      const c = CustomLaunch(kind: LaunchMediaKind.image, path: '/x', width: 1, height: 1, edge: 0xFF123456);
      expect(c.background(dark: false), LaunchColors.mistTop);
      expect(c.background(dark: true), LaunchColors.nightTop);
      expect(c.copyWith(backdrop: LaunchBackdrop.edge).background(dark: true), const Color(0xFF123456));
      expect(c.copyWith(backdrop: LaunchBackdrop.white).background(dark: true), const Color(0xFFFFFFFF));
      expect(c.copyWith(backdrop: LaunchBackdrop.black).background(dark: false), const Color(0xFF000000));
    });
  });

  group('decode size', () {
    test('no larger than the screen needs, never larger than the file', () {
      const screen = Size(1080, 2400);
      final fill = LaunchMedia.targetSize(4000, 3000, screen, LaunchFit.fill);
      // Covering 1080 × 2400 from 4:3 needs 2400 tall.
      expect(fill.height, 2400);
      expect(fill.width, 3200);
      final center = LaunchMedia.targetSize(4000, 3000, screen, LaunchFit.center);
      expect(center.width, 1080);
      final small = LaunchMedia.targetSize(300, 300, screen, LaunchFit.fill);
      expect((small.width, small.height), (300, 300));
      // Zoomed in: decodes enough detail for the zoomed window, capped at the file's own size.
      final zoomed = LaunchMedia.targetSize(4000, 3000, const Size(540, 1200), LaunchFit.fill, zoom: 2);
      expect((zoomed.width, zoomed.height), (3200, 2400));
      final capped = LaunchMedia.targetSize(4000, 3000, screen, LaunchFit.fill, zoom: 3);
      expect((capped.width, capped.height), (4000, 3000));
    });
  });
}
