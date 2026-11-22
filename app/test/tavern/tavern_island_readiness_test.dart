import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/tavern/tavern_island_story.dart';
import 'package:dsh_app/tavern/tavern_islands.dart';
import 'package:dsh_app/tavern/tavern_provider.dart';
import 'package:dsh_app/tavern/tavern_settings.dart';
import 'package:dsh_app/ui/tavern/tavern_canvas_view.dart';
import 'package:dsh_app/ui/tavern/tavern_island.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

const _html = '<script>getChatMessages(getCurrentMessageId());</script>';
const _text = 'The current message is ready.';

TavernIslandStory _story({bool current = false}) => TavernIslandStory(
  floors: {
    'opening': (floor: 0, data: const {}),
    if (current)
      'reply': (
        floor: 2,
        data: const {
          'stat_data': {'count': 7},
        },
      ),
  },
  chat: const {},
  last: (floor: current ? 2 : 0, data: const {}),
);

Future<void> _mount(
  WidgetTester tester,
  Stream<TavernIslandStory> Function() stories, {
  String html = _html,
  bool noScripts = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tavernSettingsProvider.overrideWith(() => _Settings(noScripts)),
        tavernCanvasLibrariesProvider.overrideWith((ref) async => const []),
        tavernPersonaSelectionProvider('chat').overrideWith(
          (ref) async => const PersonaSelection(
            persona: null,
            source: PersonaSelectionSource.none,
            boundPersonaId: null,
            defaultPersonaId: null,
          ),
        ),
        tavernIslandStoryProvider('chat').overrideWith((ref) => stories()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TavernIslandMessage(
            chatId: 'chat',
            nodeId: 'reply',
            text: _text,
            name: 'Speaker',
            user: false,
            child: TavernHtmlIsland(html: html),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> _loadedStory(String html) {
  final match = RegExp(r'var dshStory=([^\n]*);').firstMatch(html)!;
  return jsonDecode(match[1]!) as Map<String, Object?>;
}

void main() {
  late _WebViewPlatform platform;
  setUp(() {
    final previous = WebViewPlatform.instance;
    platform = _WebViewPlatform();
    WebViewPlatform.instance = platform;
    // The platform interface forbids restoring null. Keep an unavailable
    // implementation in that case, rather than a working fake for later tests.
    addTearDown(() => WebViewPlatform.instance = previous ?? _UnavailableWebViewPlatform());
  });

  testWidgets('an old ready story does not load a page before its own floor arrives', (tester) async {
    final stories = _StoryFeed();
    try {
      stories.controller.add(_story());
      await _mount(tester, () => stories.controller.stream);
      expect(find.text(appL10n.tavernIslandStoryWaiting), findsOneWidget);
      expect(platform.controllers, isEmpty);
      await tester.pump(const Duration(milliseconds: 300));
      expect(platform.controllers, isEmpty, reason: 'An older AsyncData is not this message being ready.');

      stories.controller.add(_story(current: true));
      await tester.pumpAndSettle();
      final controller = platform.controllers.single;
      expect(controller.documents, hasLength(1));
      expect(controller.baseUrls, [tavernFrameBaseUrl]);
      final read = _loadedStory(controller.documents.single);
      expect(read['messageId'], 2);
      expect(read['message'], _text);
      expect(read['data'], {
        'stat_data': {'count': 7},
      });
      expect((read['floors'] as Map<String, Object?>)['2'], containsPair('message', _text));
      expect(find.text(appL10n.tavernIslandStoryWaiting), findsNothing);
    } finally {
      await _unmount(tester, [stories]);
    }
  });

  testWidgets('story failure stays visible and retry reads the same chat before loading', (tester) async {
    final first = _StoryFeed();
    final next = _StoryFeed();
    try {
      var reads = 0;
      final old = _story();
      first.controller.add(old);
      await _mount(tester, () => ++reads == 1 ? first.controller.stream : next.controller.stream);
      final container = ProviderScope.containerOf(tester.element(find.byType(TavernHtmlIsland)));
      expect(find.text(appL10n.tavernIslandStoryWaiting), findsOneWidget);
      first.controller.addError(StateError('Synthetic story read failure'));
      // An idle pump delivers the asynchronous stream event after its frame
      // check. Assert the provider transition, then draw the frame it scheduled.
      await tester.pump();
      final failed = container.read(tavernIslandStoryProvider('chat'));
      expect(failed.hasError, isTrue);
      expect(
        failed.error,
        isA<StateError>().having((error) => error.message, 'message', 'Synthetic story read failure'),
      );
      expect(failed.value, same(old), reason: 'A stream error retains its previous AsyncData.');
      await tester.pump();
      expect(find.textContaining('Synthetic story read failure'), findsOneWidget);
      expect(platform.controllers, isEmpty);
      await tester.tap(find.text(appL10n.commonRetry));
      await tester.pump();
      expect(reads, 2);
      expect(platform.controllers, isEmpty);
      next.controller.add(_story(current: true));
      await tester.pumpAndSettle();
      expect(platform.controllers.single.documents, hasLength(1));
      expect(_loadedStory(platform.controllers.single.documents.single)['messageId'], 2);
      expect(find.textContaining('Synthetic story read failure'), findsNothing);
    } finally {
      await _unmount(tester, [first, next]);
    }
  });

  testWidgets('ordinary HTML and the no-scripts choice do not wait for a story', (tester) async {
    for (final noScripts in [false, true]) {
      try {
        var reads = 0;
        await _mount(
          tester,
          () {
            reads++;
            return const Stream.empty();
          },
          html: noScripts ? _html : '<p>Plain page</p>',
          noScripts: noScripts,
        );
        expect(reads, 0);
        expect(platform.controllers.last.documents, hasLength(1));
        expect(platform.controllers.last.documents.single, isNot(contains('var dshStory=')));
      } finally {
        await _unmount(tester, []);
      }
    }
  });
}

Future<void> _unmount(WidgetTester tester, List<_StoryFeed> feeds) async {
  await tester.pumpWidget(const SizedBox());
  // Retain the existing cleanup drain for the island queue's scheduled tick.
  await tester.pump(const Duration(milliseconds: 100));
  for (final feed in feeds) {
    await feed.close();
  }
}

class _StoryFeed {
  final controller = StreamController<TavernIslandStory>();

  Future<void> close() async {
    if (controller.hasListener) throw StateError('Unmount the story provider before closing its test feed.');
    // Not awaited: a single-subscription controller whose listener cancelled
    // never completes close()'s Future (it has no one to send done to).
    unawaited(controller.close());
  }
}

class _Settings extends TavernSettingsController {
  _Settings(this.noScripts);

  final bool noScripts;

  @override
  TavernSettings build() => TavernSettings(islandNoScripts: noScripts, loaded: true);
}

class _UnavailableWebViewPlatform extends WebViewPlatform {}

class _WebViewPlatform extends WebViewPlatform {
  final controllers = <_Controller>[];

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) {
    final controller = _Controller(params);
    controllers.add(controller);
    return controller;
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) =>
      _Navigation(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) => _WebView(params);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();

  final documents = <String>[];
  final baseUrls = <String?>[];

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    documents.add(html);
    baseUrls.add(baseUrl);
  }

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams javaScriptChannelParams) async {}

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {}
}

class _Navigation extends PlatformNavigationDelegate {
  _Navigation(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async {}

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {}
}

class _WebView extends PlatformWebViewWidget {
  _WebView(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox();
}
