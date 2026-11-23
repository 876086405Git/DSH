import 'package:dsh_app/companion/companion_notice_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const wire = MethodChannel('dsh/companion');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const status = {
    'enabled': true,
    'granted': true,
    'unlocked': true,
    'levels': {'com.example': 'remember'},
    'received': 4,
    'judged': 2,
    'said': 1,
    'epoch': 8,
    'consentEpoch': 6,
  };
  tearDown(() => messenger.setMockMethodCallHandler(wire, null));

  test(
    'typed settings, metadata-only pending, destructive take and confirmed counters share the named channel',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(wire, (call) async {
        calls.add(call);
        return switch (call.method) {
          'notices.status' || 'notices.setEnabled' || 'notices.setLevel' => status,
          'notices.recentApps' => [
            {
              'pkg': 'com.example',
              'name': '示例',
              'count': 4,
              'icon': Uint8List.fromList([1]),
            },
          ],
          'notices.pending' => [
            {'pkg': 'com.example', 'key': 'digest', 'atMs': 10},
          ],
          'notices.takeBatch' => {
            'pkg': 'com.example',
            'appName': '示例',
            'level': 'remember',
            'epoch': 8,
            'consentEpoch': 6,
            'items': [
              {
                'key': 'digest',
                'segments': [
                  {'text': '原生预览', 'atMs': 12, 'personId': 'title-digest'},
                ],
              },
            ],
          },
          'notices.record' => true,
          _ => throw MissingPluginException(),
        };
      });
      final channel = CompanionNoticeChannel(wire);
      final current = await channel.status();
      expect(
        [current.readable, current.level('com.example'), current.level('other'), current.said],
        [true, CompanionNoticeLevel.remember, CompanionNoticeLevel.off, 1],
      );
      await channel.setEnabled(true);
      expect(calls.last.arguments, {'enabled': true});
      await channel.setLevel('com.example', CompanionNoticeLevel.glance);
      expect(calls.last.arguments, {'pkg': 'com.example', 'level': 'glance'});
      expect((await channel.recentApps()).single.icon, [1]);
      expect((await channel.pending()).single.atMs, 10);
      final batch = await channel.takeBatch('com.example', ['digest'], current.epoch);
      expect(batch!.consentEpoch, 6);
      expect(batch.items.single.segments.single, (text: '原生预览', atMs: 12, personId: 'title-digest'));
      expect(await channel.record(8, judged: 1), isTrue);
      expect(calls.last.arguments, {'epoch': 8, 'judged': 1, 'said': 0});
    },
  );

  test('native wake contains epoch only and an expired destructive take returns no batch', () async {
    final channel = CompanionNoticeChannel(wire);
    final first = channel.signals.first;
    await messenger.handlePlatformMessage(
      wire.name,
      wire.codec.encodeMethodCall(const MethodCall('noticeSignal', {'epoch': 9})),
      null,
    );
    expect(await first, 9);
    messenger.setMockMethodCallHandler(wire, (_) async => null);
    expect(await channel.takeBatch('com.example', ['digest'], 8), isNull);
  });
}
