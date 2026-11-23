// 自定义壁纸的导入（启动画面那条链路，换成壁纸的预算）和持久化：只要照片、15 MB 以内、
// PNG / JPEG / WebP（动图记成动图）、坏文件和视频拒收、换图删旧文件、取景和观感的读写与回退。

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/plugins/native/native_effects.dart';
import 'package:dsh_app/plugins/native/native_file_platform.dart';
import 'package:dsh_app/state/wallpaper_state.dart';
import 'package:dsh_app/wallpaper/custom_wallpaper.dart';
import 'package:dsh_app/wallpaper/wallpaper_import.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

class _Platform implements NativeFilePlatform {
  _Platform(this.files, {this.throwing});

  final List<NativeSelectedFile> files;
  final Object? throwing;
  PickFileEffect? asked;
  final cancelled = <String>[];

  @override
  Future<bool> supported() async => true;

  @override
  Future<List<NativeSelectedFile>> pick(PickFileEffect effect) async {
    asked = effect;
    if (throwing != null) throw throwing!;
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

Uint8List _bytes(String path) => File(path).readAsBytesSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('wallpaper-import');
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => dir.deleteSync(recursive: true));

  WallpaperImport importer(_Platform platform) => WallpaperImport(platform: platform, directory: () async => dir);

  group('import', () {
    test('asks the picker for photos only, 15 MB, and keeps a checked copy', () async {
      final platform = _Platform([_file(_bytes(brightFixture))]);
      final (wallpaper, problem) = await importer(platform).pick();
      expect(problem, isNull);
      expect(platform.asked!.images, isTrue);
      expect(platform.asked!.visual, isFalse, reason: 'no videos in the picker');
      expect(platform.asked!.maxBytes, 15 * 1024 * 1024);
      expect(platform.asked!.own, isTrue, reason: 'a plugin\'s 8 MB budget would refuse 15 MB natively');
      expect(platform.asked!.action, 'wallpaper');
      expect(platform.cancelled, hasLength(1));
      expect((wallpaper!.width, wallpaper.height), (720, 1280));
      expect(wallpaper.path, startsWith(dir.path));
      expect(wallpaper.path, endsWith('.jpg'));
      expect(File(wallpaper.path).readAsBytesSync(), _bytes(brightFixture));
      // The edge colour (the launch chain's), drawn while it bakes.
      expect(wallpaper.edge, isNotNull);
      expect(wallpaper.on, isTrue);
      expect((wallpaper.zoom, wallpaper.alignX, wallpaper.alignY), (1.0, 0.0, 0.0));
    });

    test('PNG, JPEG and WebP are known by their bytes', () async {
      for (final (path, ext) in [(pngFixture, '.png'), (brightFixture, '.jpg'), (darkFixture, '.webp')]) {
        final (wallpaper, problem) = await importer(_Platform([])).keep(Stream.value(_bytes(path)));
        expect(problem, isNull, reason: path);
        expect(wallpaper!.path, endsWith(ext));
      }
    });

    test('an animation is known as one (its first frame is what bakes); a still is not', () async {
      final (wallpaper, problem) = await importer(_Platform([])).keep(Stream.value(_bytes(gifFixture)));
      expect(problem, isNull);
      expect((wallpaper!.width, wallpaper.height), (120, 200));
      expect((wallpaper.animated, wallpaper.play), (true, true));
      // Replaced by a still: the choices stay, the animation doesn't.
      final tuned = wallpaper.copyWith(guard: false, play: false);
      final (still, _) = await importer(_Platform([])).keep(Stream.value(_bytes(pngFixture)), previous: tuned);
      expect((still!.animated, still.play, still.guard), (false, false, false));
    });

    test('over 15 MB: refused before and while copying, nothing left behind', () async {
      final big = _file(Uint8List(16), length: 15 * 1024 * 1024 + 1);
      expect((await importer(_Platform([big])).pick()).$2, LaunchImportProblem.tooLarge);
      // The size the picker said was wrong: the copy stops at the limit.
      final lying = NativeSelectedFile(
        name: 'pick',
        length: 10,
        openRead: () => Stream.fromIterable(List.generate(16, (_) => Uint8List(1024 * 1024))),
      );
      expect((await importer(_Platform([lying])).pick()).$2, LaunchImportProblem.tooLarge);
      expect(dir.listSync(), isEmpty);
    });

    test('a video, a PDF, a broken picture: refused, nothing left behind', () async {
      final mp4 = Uint8List.fromList([0, 0, 0, 0x18, ...'ftypmp42'.codeUnits, ...List.filled(64, 0)]);
      expect((await importer(_Platform([_file(mp4)])).pick()).$2, LaunchImportProblem.unsupported);
      final pdf = Uint8List.fromList([...'%PDF-1.7'.codeUnits, ...List.filled(64, 0)]);
      expect((await importer(_Platform([_file(pdf)])).pick()).$2, LaunchImportProblem.unsupported);
      expect((await importer(_Platform([_file(_bytes(brokenFixture))])).pick()).$2, LaunchImportProblem.unreadable);
      expect((await importer(_Platform([_file(Uint8List(0))])).pick()).$2, LaunchImportProblem.unreadable);
      expect(dir.listSync(), isEmpty);
    });

    test('the picker refusing a large file, or failing: says which', () async {
      final big = _Platform([], throwing: PlatformException(code: 'too-large'));
      expect((await importer(big).pick()).$2, LaunchImportProblem.tooLarge);
      final broken = _Platform([], throwing: PlatformException(code: 'busy'));
      expect((await importer(broken).pick()).$2, LaunchImportProblem.unavailable);
      expect(big.cancelled, hasLength(1), reason: 'the request is let go either way');
    });

    test('closed picker, or none: says so', () async {
      expect((await importer(_Platform([])).pick()).$2, LaunchImportProblem.cancelled);
      final unsupported = _UnsupportedPlatform();
      final (_, problem) = await WallpaperImport(platform: unsupported, directory: () async => dir).pick();
      expect(problem, LaunchImportProblem.unavailable);
    });

    test('a new picture keeps the look, starts the framing over, and leaves the old file to the save', () async {
      final (first, _) = await importer(_Platform([])).keep(Stream.value(_bytes(brightFixture)));
      final tuned = first!.copyWith(zoom: 2, alignX: 0.5, blur: 0.7, lighten: 0.1, dim: 0.6);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      final (second, problem) = await importer(_Platform([])).keep(Stream.value(_bytes(darkFixture)), previous: tuned);
      expect(problem, isNull);
      expect(File(first.path).existsSync(), isTrue, reason: 'the controller removes it once the new one is saved');
      expect(File(second!.path).existsSync(), isTrue);
      expect((second.blur, second.lighten, second.dim), (0.7, 0.1, 0.6));
      expect((second.zoom, second.alignX), (1.0, 0.0));
      // A refused pick keeps the old one.
      final (none, refused) = await importer(_Platform([_file(_bytes(brokenFixture))])).pick(previous: second);
      expect(none, isNull);
      expect(refused, LaunchImportProblem.unreadable);
      expect(File(second.path).existsSync(), isTrue);
    });
  });

  group('stored', () {
    test('round-trips; out-of-range values come back in range', () async {
      final file = File('${dir.path}/w.png')..writeAsBytesSync(_bytes(pngFixture));
      final w = CustomWallpaper(
        path: file.path,
        width: 300,
        height: 200,
        edge: 0xFF336699,
        zoom: 2.5,
        alignX: -0.4,
        alignY: 0.8,
        blur: 0.6,
        lighten: 0.15,
        dim: 0.45,
        guard: false,
        animated: true,
        play: false,
        on: false,
      );
      await CustomWallpaper.save(w);
      expect(await CustomWallpaper.load(), w);
      // Stored before these existed: guarded, a still, and it would play.
      final old = CustomWallpaper.fromJson(
        w.toJson()..removeWhere((k, _) => const {'guard', 'animated', 'play'}.contains(k)),
      )!;
      expect((old.guard, old.animated, old.play), (true, false, true));
      SharedPreferences.setMockInitialValues({
        CustomWallpaper.prefsKey: jsonEncode({
          ...w.toJson(),
          'zoom': 40,
          'alignX': -9,
          'blur': 'soft',
          'dim': double.nan.toString(),
        }),
      });
      final read = (await CustomWallpaper.load())!;
      expect(read.zoom, CustomWallpaper.maxZoom);
      expect(read.alignX, -1);
      expect(read.blur, CustomWallpaper.defaultBlur);
      expect(read.dim, CustomWallpaper.defaultDim);
    });

    test('its file gone, or nonsense stored: none (the default backdrop)', () async {
      SharedPreferences.setMockInitialValues({
        CustomWallpaper.prefsKey: jsonEncode({'path': '${dir.path}/gone.png', 'width': 10, 'height': 10}),
      });
      expect(await CustomWallpaper.load(), isNull);
      SharedPreferences.setMockInitialValues({CustomWallpaper.prefsKey: '{not json'});
      expect(await CustomWallpaper.load(), isNull);
      SharedPreferences.setMockInitialValues({
        CustomWallpaper.prefsKey: jsonEncode({'path': '', 'width': 0, 'height': 10}),
      });
      expect(await CustomWallpaper.load(), isNull);
    });

    test('the controller: choose, switch off and back (the picture stays), frame, blur, tone per mode', () async {
      final container = ProviderContainer(
        overrides: [
          wallpaperImportProvider.overrideWithValue(
            WallpaperImport(platform: _Platform([_file(_bytes(brightFixture))]), directory: () async => dir),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(await container.read(customWallpaperProvider.future), isNull);
      final notifier = container.read(customWallpaperProvider.notifier);
      expect(await notifier.choose(), isNull);
      final chosen = container.read(customWallpaperProvider).value!;
      expect(chosen.on, isTrue);

      await notifier.use(false);
      expect(container.read(customWallpaperProvider).value!.on, isFalse);
      expect(File(chosen.path).existsSync(), isTrue, reason: 'back to the default keeps the picture');
      await notifier.use(true);

      await notifier.frame(zoom: 9, alignX: 0.25, alignY: -2);
      await notifier.setBlur(0.55);
      await notifier.setTone(Brightness.light, 0.3);
      await notifier.setTone(Brightness.dark, 0.65);
      await notifier.setGuard(false);
      await notifier.setPlay(false);
      final now = container.read(customWallpaperProvider).value!;
      expect((now.guard, now.play), (false, false));
      expect((now.zoom, now.alignX, now.alignY), (CustomWallpaper.maxZoom, 0.25, -1.0));
      expect((now.blur, now.lighten, now.dim), (0.55, 0.3, 0.65));
      expect(now.toneFor(Brightness.light), 0.3);
      expect(now.toneFor(Brightness.dark), 0.65);
      // What the next launch reads.
      expect(await CustomWallpaper.load(), now);
    });
  });

  group('framing', () {
    const w = CustomWallpaper(path: 'p', width: 1000, height: 1000);
    const phone = Size(400, 800);

    test('zoom 1 covers the screen, centred', () {
      final r = w.window(phone);
      expect(r.height, 1000);
      expect(r.width, 500);
      expect(r.left, 250);
      expect(r.top, 0);
    });

    test('alignment moves the window within the spare picture; zoom shrinks it', () {
      expect(w.copyWith(alignX: -1).window(phone).left, 0);
      expect(w.copyWith(alignX: 1).window(phone).right, 1000);
      final zoomed = w.copyWith(zoom: 2, alignX: 1, alignY: -1).window(phone);
      expect((zoomed.width, zoomed.height), (250, 500));
      expect((zoomed.right, zoomed.top), (1000, 0));
    });

    test('the same framing in a smaller decode of the picture', () {
      final full = w.copyWith(zoom: 1.5, alignX: 0.3, alignY: 0.6).window(phone);
      final half = w.copyWith(zoom: 1.5, alignX: 0.3, alignY: 0.6).windowIn(const Size(500, 500), phone);
      expect(half.left * 2, moreOrLessEquals(full.left));
      expect(half.width * 2, moreOrLessEquals(full.width));
    });
  });
}

class _UnsupportedPlatform implements NativeFilePlatform {
  @override
  Future<bool> supported() async => false;

  @override
  Future<List<NativeSelectedFile>> pick(PickFileEffect effect) async => const [];

  @override
  Future<void> cancel(String owner) async {}
}
