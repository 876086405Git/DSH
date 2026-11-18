import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/live_activity_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _activity = LiveActivity(
  kind: LiveKind.waiting,
  title: 'Private conversation',
  text: 'Private request',
  chip: '待确认',
  publicText: 'DSH 等你确认',
  mood: PetStateName.notification,
  target: PetTarget(HostRef.ssh('lab'), 'root'),
  eventId: 'e1',
);
const _push = LivePush(enabled: true, packId: 'pet', activity: _activity);

class _Push extends Notifier<LivePush> {
  @override
  LivePush build() => _push;
  void set(LivePush value) => state = value;
}

final _pushProvider = NotifierProvider<_Push, LivePush>(_Push.new);

class _Channel extends NotifyChannel {
  final pushes = <LivePush>[];
  @override
  Future<void> live(LivePush push) async => pushes.add(push);
}

ProviderContainer _container(String os, _Channel channel) => ProviderContainer(
  overrides: [
    operatingSystemProvider.overrideWithValue(os),
    notifyChannelProvider.overrideWithValue(channel),
    livePushProvider.overrideWith((ref) => ref.watch(_pushProvider)),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('old Android status retains its fields and has no ordinary fallback', () {
    final status = LiveSystemStatus.fromMap({
      'supported': true,
      'allowed': true,
      'settings': true,
      'xiaomiFocus': true,
    });
    expect(status, const LiveSystemStatus(supported: true, allowed: true, settings: true, xiaomiFocus: true));
    expect(status.native, isTrue);
    expect(status.ordinaryFallback, isFalse);
    expect(status.ordinaryAllowed, isFalse);
    expect(status.backend, 'none');
  });

  test('ordinary capability and permission do not imply system live activity or display', () {
    final status = LiveSystemStatus.fromMap({
      'supported': false,
      'allowed': false,
      'settings': true,
      'ordinaryFallback': true,
      'ordinaryAllowed': true,
      'backend': 'ordinary',
    });
    expect(status.supported, isFalse);
    expect(status.allowed, isFalse);
    expect(status.settings, isTrue);
    expect(status.ordinaryFallback, isTrue);
    expect(status.ordinaryAllowed, isTrue);
    expect(status.backend, 'ordinary');
    final denied = LiveSystemStatus.fromMap({
      'ordinaryFallback': true,
      'ordinaryAllowed': false,
      'backend': 'ordinary',
    });
    expect(denied.ordinaryFallback, isTrue);
    expect(denied.ordinaryAllowed, isFalse);
    expect(denied.backend, 'ordinary');
  });

  test('unknown ordinary values default safely and new fields participate in equality', () {
    expect(
      LiveSystemStatus.fromMap({'ordinaryFallback': 'true', 'ordinaryAllowed': 1, 'backend': 'unknown'}),
      const LiveSystemStatus(),
    );
    expect(LiveSystemStatus.fromMap({'backend': 1}).backend, 'none');
    const values = [
      LiveSystemStatus(),
      LiveSystemStatus(ordinaryFallback: true),
      LiveSystemStatus(ordinaryAllowed: true),
      LiveSystemStatus(backend: 'ordinary'),
    ];
    expect(values.toSet(), hasLength(4));
    final parsed = LiveSystemStatus.fromMap({'ordinaryFallback': true});
    expect(parsed, values[1]);
    expect(parsed.hashCode, values[1].hashCode);
  });

  test('actual MethodChannel keeps the original nested LivePush wire and parses fallback status', () async {
    const methods = MethodChannel('test/live-441');
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      calls.add(call);
      if (call.method == 'liveStatus') {
        return {
          'supported': false,
          'allowed': false,
          'ordinaryFallback': true,
          'ordinaryAllowed': true,
          'backend': 'ordinary',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
    final channel = NotifyChannel(methods: methods);
    await channel.live(_push);
    await channel.live(const LivePush(enabled: false));
    expect(calls.map((c) => c.method), ['live', 'live']);
    expect(calls[0].arguments, {
      'enabled': true,
      'packId': 'pet',
      'activity': {
        'kind': 'waiting',
        'title': 'Private conversation',
        'text': 'Private request',
        'chip': '待确认',
        'publicText': 'DSH 等你确认',
        'mood': 'notification',
        'host': '{"kind":"ssh","id":"lab"}',
        'sessionId': 'root',
        'eventId': 'e1',
      },
    });
    expect((calls[0].arguments as Map).keys.toList(), ['enabled', 'packId', 'activity']);
    expect(((calls[0].arguments as Map)['activity'] as Map).keys.toList(), [
      'kind',
      'title',
      'text',
      'chip',
      'publicText',
      'mood',
      'host',
      'sessionId',
      'eventId',
    ]);
    expect(calls[1].arguments, {'enabled': false});
    final status = await channel.liveStatus();
    expect(status, const LiveSystemStatus(ordinaryFallback: true, ordinaryAllowed: true, backend: 'ordinary'));
    expect(calls.last.arguments, isNull);
  });

  test('a native liveStatus that throws is a failed read, not a phone without the feature', () async {
    const methods = MethodChannel('test/live-read-failed');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(code: 'ohos_notify_failed');
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(methods, null),
    );
    final status = await NotifyChannel(methods: methods).liveStatus();
    expect(status.readFailed, isTrue);
    expect(status.native, isTrue);
    expect(status, isNot(const LiveSystemStatus()));
  });

  test('missing native liveStatus remains unavailable with no ordinary backend', () async {
    const methods = MethodChannel('test/live-441-missing');
    final status = await NotifyChannel(methods: methods).liveStatus();
    expect(status, const LiveSystemStatus.unavailable());
    expect(status.native, isFalse);
    expect(status.backend, 'none');
  });

  for (final os in ['ohos', 'android']) {
    test('$os bridge keeps deduplication and only OH sends disabled on disposal', () async {
      final channel = _Channel();
      final container = _container(os, channel);
      try {
        container.listen<void>(liveActivityBridgeProvider, (_, _) {});
        expect(channel.pushes, [_push]);
        container.read(_pushProvider.notifier).set(const LivePush(enabled: true, packId: 'pet', activity: _activity));
        await container.pump();
        expect(channel.pushes, [_push]);
        container.read(_pushProvider.notifier).set(const LivePush(enabled: true));
        await container.pump();
        expect(channel.pushes, [_push, const LivePush(enabled: true)]);
      } finally {
        container.dispose();
      }
      expect(channel.pushes, [_push, const LivePush(enabled: true), if (os == 'ohos') const LivePush(enabled: false)]);
    });
  }

  test('OH bridge replacement sends old disabled before the new initial push', () {
    final channel = _Channel();
    final container = _container('ohos', channel);
    try {
      container.read(liveActivityBridgeProvider);
      container.invalidate(liveActivityBridgeProvider);
      container.read(liveActivityBridgeProvider);
      expect(channel.pushes, [_push, const LivePush(enabled: false), _push]);
    } finally {
      container.dispose();
    }
    expect(channel.pushes, [_push, const LivePush(enabled: false), _push, const LivePush(enabled: false)]);
  });
}
