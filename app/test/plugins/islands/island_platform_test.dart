// `dsh/islands` over a real channel: every call reaches the platform side on
// Android, HarmonyOS and iOS, and nothing does anywhere else.

import 'package:dsh_app/ui/plugins/islands/island_budget.dart';
import 'package:dsh_app/ui/plugins/islands/island_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('dsh/islands');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  void answer(Object? Function(MethodCall call) reply) {
    calls = [];
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  Future<void> everyCall(IslandPlatform platform) async {
    await platform.device();
    await platform.appPss();
    await platform.attach(7, dark: true, textZoom: 130);
    await platform.setDark(7, false);
    await platform.setTextZoom(7, 150);
    await platform.pause(7);
    await platform.resume(7);
    await platform.destroy(7);
  }

  final expected = <List<Object?>>[
    ['device', null],
    ['appPss', null],
    ['attach', {'id': 7, 'dark': true, 'textZoom': 130}],
    ['setDark', {'id': 7, 'dark': false}],
    ['setTextZoom', {'id': 7, 'zoom': 150}],
    ['pause', {'id': 7}],
    ['resume', {'id': 7}],
    ['destroy', {'id': 7}],
  ];

  List<List<Object?>> seen() => [for (final call in calls) [call.method, call.arguments]];

  void fromNative(String method, Object? arguments) => messenger.handlePlatformMessage(
    _channel.name,
    _channel.codec.encodeMethodCall(MethodCall(method, arguments)),
    (_) {},
  );

  setUp(() => answer((_) => null));

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_channel, null);
  });

  // oh-flutter's own TargetPlatform isn't Android; stock Flutter has no value
  // for it, so any other one stands in.
  group('HarmonyOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.linux);

    test('every call reaches the channel, named and shaped as on Android', () async {
      await everyCall(MethodChannelIslandPlatform(_channel, 'ohos'));
      expect(seen(), expected);
    });

    test('an attach the platform side accepts is true, one it refuses is false', () async {
      final platform = MethodChannelIslandPlatform(_channel, 'ohos');
      answer((_) => true);
      expect(await platform.attach(7, dark: false, textZoom: 100), isTrue);
      answer((_) => false);
      expect(await platform.attach(8, dark: false, textZoom: 100), isFalse);
    });

    test('a plugin that does not answer is no answer, not an exception', () async {
      messenger.setMockMethodCallHandler(_channel, null);
      final platform = MethodChannelIslandPlatform(_channel, 'ohos');
      expect(await platform.device(), isA<IslandDevice>().having((d) => d.totalMem, 'totalMem', 0));
      expect(await platform.attach(7, dark: false, textZoom: 100), isFalse);
      expect(await platform.appPss(), isNull);
      await platform.pause(7);
    });

    test('an error from the platform side is no answer either', () async {
      answer((_) => throw PlatformException(code: 'ohos_islands_memory'));
      expect(await MethodChannelIslandPlatform(_channel, 'ohos').appPss(), isNull);
    });

    test('rendererGone and trimMemory arrive as events', () async {
      final platform = MethodChannelIslandPlatform(_channel, 'ohos');
      final events = <IslandPlatformEvent>[];
      final subscription = platform.events.listen(events.add);
      addTearDown(subscription.cancel);
      fromNative('rendererGone', {'id': 7, 'crashed': true});
      fromNative('trimMemory', {'level': 15});
      await pumpEventQueue();
      expect(events, hasLength(2));
      expect(
        events[0],
        isA<IslandRendererGone>()
            .having((e) => e.webViewId, 'webViewId', 7)
            .having((e) => e.crashed, 'crashed', true),
      );
      expect(events[1], isA<IslandTrimMemory>().having((e) => e.low, 'low', true));
    });

    test('the device it reports picks the tier the phone is', () async {
      Future<int> tier(int totalMem, {bool lowRam = false}) async {
        answer((_) => {'totalMem': totalMem, 'availMem': totalMem ~/ 2, 'lowRam': lowRam});
        return maxLiveIslands(await MethodChannelIslandPlatform(_channel, 'ohos').device());
      }

      expect(await tier(4 << 30), 1);
      expect(await tier(6 << 30), 2);
      expect(await tier(12 << 30), 3);
      expect(await tier(12 << 30, lowRam: true), 1);
    });
  });

  test('Android goes through as before', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await everyCall(MethodChannelIslandPlatform(_channel, 'android'));
    expect(seen(), expected);
  });

  test('iOS goes through the same way, and its events arrive', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final platform = MethodChannelIslandPlatform(_channel, 'ios');
    await everyCall(platform);
    expect(seen(), expected);
    answer((_) => {'totalMem': 6 << 30, 'lowRam': false, 'webView': 'WebKit (iOS 18.0)'});
    expect(maxLiveIslands(await platform.device()), 2);
    final events = <IslandPlatformEvent>[];
    final subscription = platform.events.listen(events.add);
    addTearDown(subscription.cancel);
    fromNative('rendererGone', {'id': 7, 'crashed': false});
    fromNative('trimMemory', {'level': 15});
    await pumpEventQueue();
    expect(events[0], isA<IslandRendererGone>().having((e) => e.crashed, 'crashed', false));
    expect(events[1], isA<IslandTrimMemory>().having((e) => e.low, 'low', true));
  });

  test('anywhere else nothing reaches the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final platform = MethodChannelIslandPlatform(_channel, 'macos');
    await everyCall(platform);
    expect(await platform.attach(7, dark: false, textZoom: 100), isFalse);
    final events = <IslandPlatformEvent>[];
    final subscription = platform.events.listen(events.add);
    addTearDown(subscription.cancel);
    fromNative('rendererGone', {'id': 7, 'crashed': true});
    await pumpEventQueue();
    expect(seen(), isEmpty);
    expect(events, isEmpty);
  });
}
