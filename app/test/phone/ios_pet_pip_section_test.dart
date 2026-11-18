// Optional iOS pet window: enabling or recovering it asks the native side.

import 'package:dsh_app/pets/overlay_channel.dart';
import 'package:dsh_app/ui/phone/ios_pet_pip_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

const _channel = MethodChannel('dsh/pet_overlay');

Map<String, Object?> _ios({
  bool enabled = false,
  bool usable = false,
  bool keepingAlive = false,
  bool snoozed = false,
  bool always = false,
  bool task = false,
  bool active = false,
  bool paused = false,
  String? error,
}) => {
  'platform': 'ios',
  'backend': 'pictureInPicture',
  'enabled': enabled,
  'alwaysShow': always,
  'snoozed': snoozed,
  'showing': active,
  'permission': 'granted',
  'supported': true,
  'usable': usable,
  'keepingAlive': keepingAlive,
  'active': active,
  'phoneTaskActive': task,
  'paused': paused,
  'needsStopConfirmation': false,
  'errorCode': error,
  'sdk': 26,
  'manufacturer': 'Apple',
};

void main() {
  late Map<String, Object?> current;
  late List<String> calls;
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.arguments == null ? call.method : '${call.method} ${call.arguments}');
      switch (call.method) {
        case 'setEnabled':
          current = _ios(enabled: (call.arguments as Map)['enabled'] == true, usable: true);
        case 'unsnooze':
          current = _ios(enabled: true, usable: true);
        case 'startPictureInPicture':
          return true;
      }
      return current;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null);
  });

  Future<void> show(WidgetTester tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: const Scaffold(body: SingleChildScrollView(child: IosPetPipSection())),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the Android overlay shows nothing here', (tester) async {
    current = {'enabled': true, 'permission': 'granted', 'sdk': 34, 'manufacturer': 'Xiaomi'};
    await show(tester);
    expect(find.text('宠物画中画'), findsNothing);
  }, variant: ios);

  testWidgets('off: the optional window stays off, and enabling asks the native side', (tester) async {
    current = _ios();
    await show(tester);
    expect(find.text('宠物画中画'), findsOneWidget);
    expect(find.text('可选，默认关闭'), findsOneWidget);
    expect(find.text('任务结束后也留着'), findsNothing);
    await tapAndSettle(tester, find.byType(Switch));
    expect(calls.last, 'setEnabled {enabled: true}');
    expect(find.text('已就绪，手机任务开始时出现'), findsOneWidget);
    expect(find.text('任务结束后也留着'), findsOneWidget);
  }, variant: ios);

  testWidgets('a refused confirmation reads the status again instead of hiding the card', (tester) async {
    current = _ios();
    await show(tester);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      if (call.method == 'setEnabled') throw PlatformException(code: 'overlay_foreground_required');
      return current;
    });
    await tapAndSettle(tester, find.byType(Switch));
    expect(calls, containsAllInOrder(['setEnabled', 'status']));
    expect(find.text('可选，默认关闭'), findsOneWidget);
  }, variant: ios);

  testWidgets('stopped when the phone locked: it says so, and 恢复 brings it back', (tester) async {
    current = _ios(enabled: true, error: 'overlay_device_locked');
    await show(tester);
    expect(find.text('锁屏时画中画停了'), findsOneWidget);
    expect(find.text('重新准备画中画'), findsOneWidget);
    await tapAndSettle(tester, find.text('恢复'));
    expect(calls.last, 'unsnooze');
    expect(find.text('已就绪，手机任务开始时出现'), findsOneWidget);
    expect(find.text('重新准备画中画'), findsNothing);
  }, variant: ios);

  testWidgets('no visible source between tasks is waiting, not a failure', (tester) async {
    current = _ios(enabled: true, usable: true, always: true, error: 'overlay_source_missing');
    await show(tester);
    expect(find.text('已就绪，手机任务开始时出现'), findsOneWidget);
    expect(find.text('恢复'), findsNothing);
  }, variant: ios);

  testWidgets('no visible source during a task is a failure to start', (tester) async {
    current = _ios(enabled: true, usable: true, always: true, task: true, error: 'overlay_source_missing');
    await show(tester);
    expect(find.text('已就绪，手机任务开始时出现'), findsNothing);
    expect(find.text('恢复'), findsOneWidget);
  }, variant: ios);

  testWidgets('no pet chosen: it points to pet settings', (tester) async {
    current = _ios(enabled: true, error: 'overlay_pet_not_selected');
    await show(tester);
    expect(find.text('先选一只宠物'), findsOneWidget);
    expect(find.text('选宠物'), findsOneWidget);
    expect(find.text('恢复'), findsNothing);
  }, variant: ios);

  testWidgets('a task paused from picture-in-picture is resumed or stopped in the app', (tester) async {
    current = _ios(enabled: true, usable: true, task: true, active: true, paused: true);
    await show(tester);
    expect(find.text('手机任务在画中画里暂停了'), findsOneWidget);
    await tapAndSettle(tester, find.text('继续或停止'));
    expect(calls.last, 'reviewPausedTask');
  }, variant: ios);

  testWidgets('a task without picture-in-picture offers to start it', (tester) async {
    current = _ios(enabled: true, usable: true, task: true);
    await show(tester);
    await tapAndSettle(tester, find.text('开始画中画'));
    expect(calls, contains('startPictureInPicture'));
  }, variant: ios);

  testWidgets('picture-in-picture up during a task: it says it keeps the app running', (tester) async {
    current = _ios(enabled: true, usable: true, task: true, active: true, keepingAlive: true);
    await show(tester);
    expect(find.text('正在让 App 在后台继续运行'), findsOneWidget);
    expect(find.text('开始画中画'), findsNothing);
  }, variant: ios);

  test('the status map from Android carries none of the iOS fields', () {
    final android = PetOverlayStatus.fromMap({'enabled': true, 'permission': 'granted'});
    expect(android.ios, isFalse);
    expect(android.errorCode, isNull);
    final apple = PetOverlayStatus.fromMap(_ios(enabled: true, usable: true, error: 'overlay_audio_busy'));
    expect(apple.ios, isTrue);
    expect(apple.usable, isTrue);
    expect(apple.errorCode, 'overlay_audio_busy');
    expect(apple, isNot(PetOverlayStatus.fromMap(_ios(enabled: true, usable: true))));
  });
}
