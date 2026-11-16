// 「保存到相册」: pictures keep their own bytes when a gallery takes them
// (PNG, JPEG, GIF, WebP) and become PNG otherwise; they are named after
// what the conversation calls them, with the right extension; `dsh/media`
// gets the bytes, and the person gets 「已保存到相册」 or why not.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/media/gallery.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/chat/widgets/image_actions.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../chat/support/harness.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// A 1×1 red 24-bit BMP: decodable, but not something a gallery takes.
final _bmp = Uint8List.fromList([
  0x42, 0x4D, 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0, // file header
  40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 24, 0, // info header
  0, 0, 0, 0, 4, 0, 0, 0, 0x13, 0x0B, 0, 0, 0x13, 0x0B, 0, 0, //
  0, 0, 0, 0, 0, 0, 0, 0, //
  0x00, 0x00, 0xFF, 0x00, // one pixel (B, G, R) and the row padding
]);

const _channel = MethodChannel('dsh/media');

/// Records `dsh/media` calls; answers with [answer].
List<MethodCall> _mockMedia(Future<Object?> Function(MethodCall call) answer) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) {
    calls.add(call);
    return answer(call);
  });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null),
  );
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('galleryFileName', () {
    final now = DateTime(2026, 10, 24, 15, 30, 12);

    test('keeps the conversation\'s name with the type\'s extension', () {
      expect(galleryFileName('chart.png', 'image/png'), 'chart.png');
      expect(galleryFileName('/root/workspace/out/plot.final.jpeg', 'image/jpeg'), 'plot.final.jpg');
      expect(galleryFileName('scan.bmp', 'image/png'), 'scan.png');
      expect(galleryFileName('a:b*c?.webp', 'image/webp'), 'a_b_c_.webp');
    });

    test('nothing worth keeping: a dated name', () {
      expect(galleryFileName(null, 'image/png', now: now), 'DSH_20261024_153012.png');
      expect(galleryFileName('图片', 'image/gif', now: now), 'DSH_20261024_153012.gif');
      expect(galleryFileName('  ', 'image/jpeg', now: now), 'DSH_20261024_153012.jpg');
    });

    test('UTF-16 cap never splits a supplementary character', () {
      final prefix = '图' * 79;
      final name = galleryFileName('$prefix😀.png', 'image/png');
      expect(utf8.decode(utf8.encode(name)), name, reason: 'a valid title must remain valid through UTF-8');
      expect(name, '$prefix.png');
    });

    test('UTF-16 cap preserves complete pairs and the original size budget', () {
      final prefix = '图' * 78;
      expect(galleryFileName('$prefix😀suffix.png', 'image/png'), '$prefix😀.png');
      expect(galleryFileName('${'图' * 81}.webp', 'image/webp'), '${'图' * 80}.webp');
      expect(galleryFileName('${'a' * 81}.jpeg', 'image/jpeg'), '${'a' * 80}.jpg');
    });
  });

  group('galleryImage', () {
    test('a picture a gallery takes stays as it is', () async {
      final image = await galleryImage(_png);
      expect(image.mime, 'image/png');
      expect(identical(image.bytes, _png), isTrue);
    });

    test('anything else Flutter can read becomes PNG', () async {
      final image = await galleryImage(_bmp);
      expect(image.mime, 'image/png');
      expect(image.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('not a picture: unsupported', () async {
      await expectLater(
        galleryImage(Uint8List.fromList(utf8.encode('<svg/>'))),
        throwsA(isA<GallerySaveException>().having((e) => e.code, 'code', 'unsupported')),
      );
    });
  });

  group('imageProviderBytes', () {
    test('memory, resized and file images give their stored bytes', () async {
      expect(await imageProviderBytes(MemoryImage(_png)), _png);
      expect(await imageProviderBytes(ResizeImage(MemoryImage(_png), width: 10)), _png);
      final dir = await Directory.systemTemp.createTemp('gallery_test');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/a.png')..writeAsBytesSync(_png);
      expect(await imageProviderBytes(FileImage(file)), _png);
    });

    test('web images are downloaded again; a failed one says so', () async {
      final ok = MockClient((request) async {
        expect(request.headers['Referer'], 'https://example.com/');
        return http.Response.bytes(_png, 200);
      });
      expect(
        await imageProviderBytes(
          const NetworkImage('https://example.com/a.png', headers: {'Referer': 'https://example.com/'}),
          client: ok,
        ),
        _png,
      );
      final missing = MockClient((_) async => http.Response('', 404));
      await expectLater(
        imageProviderBytes(const NetworkImage('https://example.com/b.png'), client: missing),
        throwsA(isA<GallerySaveException>().having((e) => e.code, 'code', 'download')),
      );
    });
  });

  group('saveToGallery', () {
    test('sends the bytes, the name and the type; returns the place', () async {
      final calls = _mockMedia((_) async => 'Pictures/DSH Go/chart.png');
      final where = await saveToGallery(const MediaChannel(), _png, name: 'chart.png');
      expect(where, 'Pictures/DSH Go/chart.png');
      expect(calls.single.method, 'saveImage');
      final args = calls.single.arguments as Map;
      expect(args['name'], 'chart.png');
      expect(args['mime'], 'image/png');
      expect(args['bytes'], _png);
    });

    test('refused storage comes back as permission', () async {
      _mockMedia((_) async => throw PlatformException(code: 'permission'));
      await expectLater(
        saveToGallery(const MediaChannel(), _png, name: 'a.png'),
        throwsA(isA<GallerySaveException>().having((e) => e.code, 'code', 'permission')),
      );
    });

    test('Android\'s refusals keep their codes; backing out of HarmonyOS\'s window is its own', () async {
      for (final (native, code) in [
        ('invalid', 'unsupported'),
        ('failed', 'failed'),
        ('anything else', 'failed'),
        ('cancelled', 'cancelled'),
      ]) {
        _mockMedia((_) async => throw PlatformException(code: native));
        await expectLater(
          saveToGallery(const MediaChannel(), _png, name: 'a.png'),
          throwsA(isA<GallerySaveException>().having((e) => e.code, 'code', code)),
          reason: native,
        );
      }
    });

    group('what saving a picture says', () {
      bool? saved;

      Future<bool?> save(WidgetTester tester, String os) async {
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => saved = await saveImageToGallery(context, () async => _png, name: 'a.png'),
                  child: const Text('save'),
                ),
              ),
            ),
            overrides: [operatingSystemProvider.overrideWithValue(os)],
          ),
        );
        saved = null;
        await tester.tap(find.text('save'));
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        return saved;
      }

      for (final (os, place) in [('android', 'Pictures/DSH Go/a.png'), ('ohos', 'file://media/Photo/1/a.png')]) {
        testWidgets('$os: saved says so, whatever the place looks like', (tester) async {
          _mockMedia((_) async => place);
          expect(await save(tester, os), isTrue);
          expect(find.text('已保存到相册'), findsOneWidget);
          expect(find.textContaining('file://'), findsNothing);
          await tester.pumpAndSettle(const Duration(seconds: 3));
        });

        testWidgets('$os: a real failure still says so', (tester) async {
          _mockMedia((_) async => throw PlatformException(code: 'failed'));
          expect(await save(tester, os), isFalse);
          expect(find.text('保存失败，请重试'), findsOneWidget);
          await tester.pumpAndSettle(const Duration(seconds: 5));
        });
      }

      testWidgets('ohos: backing out of the album window reads as nothing, neither failed nor saved', (tester) async {
        _mockMedia((_) async => throw PlatformException(code: 'cancelled', message: '保存图片已取消。'));
        expect(await save(tester, 'ohos'), isFalse);
        expect(find.byType(SnackBar), findsNothing);
      });
    });

    test('UTF-16 cap does not send a replacement character through the media channel', () async {
      final prefix = '图' * 79;
      final expected = '$prefix.png';
      final calls = _mockMedia((call) async {
        final args = call.arguments as Map;
        return 'Pictures/DSH Go/${args['name']}';
      });
      final where = await saveToGallery(const MediaChannel(), _png, name: '$prefix😀.png');
      final args = calls.single.arguments as Map;
      expect(args['name'], expected);
      expect(args['bytes'], _png);
      expect(args['mime'], 'image/png');
      expect(where, 'Pictures/DSH Go/$expected');
    });
  });

  group('toasts', () {
    Future<void> pumpButton(WidgetTester tester) async {
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Center(
              child: GallerySaveButton(load: () async => _png, name: 'chart.png'),
            ),
          ),
        ),
      );
    }

    testWidgets('saved: 已保存到相册, and the key shows a tick for a moment', (tester) async {
      _mockMedia((_) async => 'Pictures/DSH Go/chart.png');
      await pumpButton(tester);
      await tester.tap(find.byTooltip('保存到相册'));
      await pumpFrames(tester, 2);
      expect(find.text('已保存到相册'), findsOneWidget);
      expect(find.byIcon(AppIcons.done), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byIcon(AppIcons.save), findsOneWidget);
    });

    testWidgets('refused storage: the reason and 去设置', (tester) async {
      final calls = _mockMedia((call) async {
        if (call.method == 'openSettings') return true;
        throw PlatformException(code: 'permission');
      });
      await pumpButton(tester);
      await tester.tap(find.byTooltip('保存到相册'));
      await pumpFrames(tester, 2);
      expect(find.text('没有存储权限，未能保存'), findsOneWidget);
      expect(find.byIcon(AppIcons.done), findsNothing);
      await pumpFrames(tester);
      await tester.tap(find.text('去设置'));
      await tester.pump();
      expect([for (final c in calls) c.method], ['saveImage', 'openSettings']);
    });

    testWidgets('long-press menu: save goes through the same path', (tester) async {
      final calls = _mockMedia((_) async => 'Pictures/DSH Go/chart.png');
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          overrides: [mediaChannelProvider.overrideWithValue(const MediaChannel())],
          Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  onPressed: () =>
                      showImageActions(context, image: MemoryImage(_png), load: () async => _png, name: 'chart.png'),
                  child: const Text('长按'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('长按'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存到相册'));
      await pumpFrames(tester);
      expect(calls.single.method, 'saveImage');
      expect(find.text('已保存到相册'), findsOneWidget);
    });
  });
}
