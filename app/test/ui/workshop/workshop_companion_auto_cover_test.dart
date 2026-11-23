import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dsh_app/companion/companion_float.dart' show companionFloatStoreProvider;
import 'package:dsh_app/companion/companion_pack.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:dsh_app/ui/workshop/workshop_companion_auto_cover.dart';
import 'package:dsh_app/workshop/workshop_models.dart' show workshopPreviewSide;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../../plugins/islands/support/fakes.dart';

class _AndroidPage extends FakeWebViewController {
  _AndroidPage(super.params);

  int get webViewIdentifier => 1;
}

class _AndroidWebView extends FakeWebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final controller = _AndroidPage(params);
    controllers.add(controller);
    return controller;
  }
}

class _NoWebView extends FakeWebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) =>
      throw UnsupportedError('No WebView');
}

// Integrity is real: only the execution of the pinned SDK in the WebView is faked.
CompanionPackStore _stagePack(Directory root) {
  const scripts = {
    'runtime/live2dcubismcore.min.js': 'core',
    'runtime/cubism-framework.js': 'framework',
    'runtime/shaders/vert.vert': 'shader',
  };
  final store = CompanionPackStore(
    root,
    expectedRuntime: runtimeDigest({
      for (final entry in scripts.entries) entry.key: sha256.convert(utf8.encode(entry.value)).toString(),
    }),
  );
  void write(String path, List<int> bytes) {
    File('${store.pack.path}/$path')
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes);
  }
  for (final entry in scripts.entries) {
    write(entry.key, utf8.encode(entry.value));
  }
  write('character/index.json', utf8.encode('["character.json","model.model3.json","model.moc3","texture.png"]'));
  write('character/character.json', utf8.encode('{"model":"model.model3.json"}'));
  write(
    'character/model.model3.json',
    utf8.encode('{"Version":3,"FileReferences":{"Moc":"model.moc3","Textures":["texture.png"]}}'),
  );
  write('character/model.moc3', [...ascii.encode('MOC3'), 1]);
  write('character/texture.png', [1]); // The integrity gate checks presence; the dummy WebView never decodes it.
  return store;
}

void _post(FakeWebViewController page, Map<String, Object?> message) => page.channels['DshCompanion']!
    .onMessageReceived(JavaScriptMessage(message: jsonEncode(message)));

Future<void> _until(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  expect(done(), isTrue, reason: 'WebView startup did not finish');
}

void main() {
  late Directory root;
  late CompanionPackStore staged;
  late _AndroidWebView web;
  late FakeIslandPlatform islands;
  late IslandPlatform priorIslands;
  late WebViewPlatform? priorWebView;
  late List<Uint8List?> results;
  late int openedLive;
  late Future<CompanionPackStore> Function() loadLive;

  setUp(() {
    root = Directory.systemTemp.createTempSync('companion-cover-');
    staged = _stagePack(Directory('${root.path}/picked'));
    openedLive = 0;
    loadLive = () async => CompanionPackStore(Directory('${root.path}/not-installed'));
    results = [];
    priorIslands = IslandPlatform.instance;
    IslandPlatform.instance = islands = FakeIslandPlatform();
    priorWebView = WebViewPlatform.instance;
    WebViewPlatform.instance = web = _AndroidWebView();
  });

  tearDown(() {
    WebViewPlatform.instance = priorWebView ?? _NoWebView();
    IslandPlatform.instance = priorIslands;
    root.deleteSync(recursive: true);
  });

  Future<void> mount(WidgetTester tester, {CompanionPackStore? store}) => tester.pumpWidget(
    ProviderScope(
      overrides: [
        operatingSystemProvider.overrideWithValue('android'),
        companionFloatStoreProvider.overrideWithValue(() {
          openedLive++;
          return loadLive();
        }),
      ],
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: WorkshopCompanionAutoCover(store: store, onResult: results.add),
      ),
    ),
  );

  testWidgets('a staged ZIP renders only its picked pack and emits a single PNG', (tester) async {
    await mount(tester, store: staged);
    await _until(tester, () => web.controllers.isNotEmpty && web.controllers.single.loads.isNotEmpty);
    // A load is issued as soon as the controller is set; its widget mounts on the next frame.
    await tester.pump();
    final page = web.controllers.single;
    final url = page.loads.single;
    expect(openedLive, 0);
    expect(islands.calls, ['attach 1']);
    expect(url.queryParameters, containsPair('mode', 'cover'));
    expect(url.queryParameters, containsPair('bare', '1'));
    expect(await page.navigate(url.toString()), NavigationDecision.navigate);
    expect(await page.navigate(url.toString(), mainFrame: false), NavigationDecision.prevent);
    expect(await page.navigate(url.resolve('../pack/character/character.json').toString()), NavigationDecision.prevent);
    expect(await page.navigate('https://example.com'), NavigationDecision.prevent);
    expect(find.byKey(fakeWebViewKey), findsOneWidget);

    final frame = image.Image(width: workshopPreviewSide, height: workshopPreviewSide, numChannels: 4)
      ..setPixelRgba(30, 30, 255, 0, 0, 255);
    final png = image.encodePng(frame);
    _post(page, {'type': 'ready'});
    expect(results, isEmpty);
    final message = {'type': 'cover', 'png': base64Encode(png)};
    _post(page, message);
    _post(page, message);
    expect(results.single, orderedEquals(png));
    await tester.pump();
    expect(find.byKey(fakeWebViewKey), findsNothing);
    expect(islands.calls, ['attach 1', 'destroy']);
    await tester.runAsync(() async {
      expect(await staged.installed(), isTrue, reason: 'read-only capture');
    });
  });

  testWidgets('current partner unavailable: no WebView or pack recovery', (tester) async {
    final previous = Directory('${root.path}/not-installed/pack.previous')..createSync(recursive: true);
    await mount(tester);
    await _until(tester, () => results.isNotEmpty);
    expect(openedLive, 1);
    expect(results, [null]);
    expect(web.controllers, isEmpty);
    expect(previous.existsSync(), isTrue);
  });

  testWidgets('a staged pack cannot execute a changed runtime', (tester) async {
    File('${staged.pack.path}/runtime/cubism-framework.js').writeAsStringSync('not the pinned runtime');
    await mount(tester, store: staged);
    await _until(tester, () => results.isNotEmpty);
    expect(results, [null]);
    expect(web.controllers, isEmpty);
  });

  testWidgets('unavailable WebView and bad render both fall back to null', (tester) async {
    WebViewPlatform.instance = _NoWebView();
    await mount(tester, store: staged);
    await _until(tester, () => results.isNotEmpty);
    expect(results, [null]);
    await tester.pumpWidget(const SizedBox());
    results.clear();

    WebViewPlatform.instance = web;
    await mount(tester, store: staged);
    await _until(tester, () => web.controllers.isNotEmpty && web.controllers.single.loads.isNotEmpty);
    _post(web.controllers.single, {'type': 'cover', 'png': 'not a PNG'});
    await tester.pump();
    expect(results, [null]);
    expect(find.byKey(fakeWebViewKey), findsNothing);
  });

  testWidgets('timeout is recoverable and unmounting ignores late source results', (tester) async {
    final store = Completer<CompanionPackStore>();
    loadLive = () => store.future;
    await mount(tester);
    await tester.pump(const Duration(seconds: 25));
    expect(results, [null]);
    await tester.pumpWidget(const SizedBox());
    results.clear();
    await mount(tester);
    await tester.pumpWidget(const SizedBox());
    store.complete(staged);
    await tester.pump(const Duration(seconds: 25));
    expect(results, isEmpty);
    expect(web.controllers, isEmpty);
  });
}
