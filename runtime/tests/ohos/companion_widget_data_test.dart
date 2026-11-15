import 'package:dsh_app/companion/companion_widget.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/companion_widget');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> received;

  setUp(() {
    received = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      received.add(call);
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('unchanged consumer sends exactly the Android channel and nine fields', () async {
    const values = <String, Object?>{
      'name': '鲸鱼娘 🐋', 'status': '吃点心', 'activity': 'snack',
      'untilMs': 1794744000001, 'statusAsleep': '睡着了', 'statusWaiting': '在小屋里等你',
      'bond': 2, 'line': '今天过得怎么样？', 'saidAt': 1794744000000,
    };
    await CompanionWidget().update(values);
    expect(received, hasLength(1));
    expect(received.single.method, 'update');
    expect(received.single.arguments, values);
  });

  test('partial delta preserves omission and explicit null clear on the wire', () async {
    await CompanionWidget().update({'line': null, 'untilMs': null, 'name': ''});
    final values = received.single.arguments as Map<Object?, Object?>;
    expect(values, {'line': null, 'untilMs': null, 'name': ''});
    expect(values.containsKey('saidAt'), isFalse);
  });

  test('native busy or write failure keeps Android quiet consumer contract', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(code: 'ohos_widget_update', message: 'busy or write failed');
    });
    await expectLater(CompanionWidget().update({'name': 'one'}), completes);
  });

  test('unregistered platform stays harmless and does not require an Android gate', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw MissingPluginException());
    await expectLater(CompanionWidget().update({'name': 'one'}), completes);
  });

  test('a later update retries after a native error instead of caching failure', () async {
    var attempts = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      received.add(call);
      if (++attempts == 1) throw PlatformException(code: 'ohos_widget_update');
      return null;
    });
    final widget = CompanionWidget();
    await widget.update({'name': 'first'});
    await widget.update({'name': 'retry'});
    expect(attempts, 2);
    expect(received.last.arguments, {'name': 'retry'});
  });
}
