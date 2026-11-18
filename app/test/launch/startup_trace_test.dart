// On iOS nothing before the first frame can keep the app from starting.

import 'dart:async';

import 'package:dsh_app/launch/launch_state.dart';
import 'package:dsh_app/launch/startup_trace.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<String> said;

  setUp(() {
    said = [];
    StartupTrace.reset();
    StartupTrace.limit = const Duration(milliseconds: 20);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dsh/startup'),
      (call) async {
        said.add('${call.method}:${call.arguments}');
        return null;
      },
    );
  });

  testWidgets('a step that hangs is noted and the app goes on', (tester) async {
    await tester.runAsync(() => StartupTrace.step('launch', () => Completer<void>().future));
    expect(said, ['mark:launch…', 'mark:launch timed out']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a step that throws is noted and the app goes on', (tester) async {
    await tester.runAsync(() => StartupTrace.step('paths', () async => throw StateError('no')));
    expect(said.last, 'mark:paths failed: Bad state: no');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a step that works just passes', (tester) async {
    await tester.runAsync(() => StartupTrace.step('language', () async => null));
    expect(said, ['mark:language…', 'mark:language ok']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a step that hangs says so to whoever may still finish it', (tester) async {
    var late = 0;
    await tester.runAsync(() => StartupTrace.step('launch', () => Completer<void>().future, onLate: () => late++));
    expect(late, 1);
    await tester.runAsync(() => StartupTrace.step('paths', () async => null, onLate: () => late++));
    expect(late, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('an error is one short line, a repeat is not noted, and nothing comes after the end', (tester) async {
    StartupTrace.error('Bad state: no\n#0 main');
    StartupTrace.error('Bad state: no\n#1 other');
    StartupTrace.error('x' * 400);
    StartupTrace.finished();
    StartupTrace.finished();
    StartupTrace.mark('later');
    await tester.pump();
    expect(said, hasLength(3));
    expect(said.first, 'mark:error: Bad state: no');
    expect(said[1].length, lessThan(180));
    expect(said.last, 'finished:null');
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  group('a launch screen that answers late', () {
    const channel = MethodChannel('dsh/launch-late');
    late Completer<Map<String, Object?>> answer;
    const page = <String, Object?>{'active': true, 'sdk': 26, 'iconPx': 4, 'background': 0xFFFFFFFF};

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      answer = Completer();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'begin' ? answer.future : null,
      );
    });

    tearDown(() {
      LaunchController.resetGaveUp();
      LaunchController.active.value = null;
    });

    testWidgets('doesn\'t come over an app that went on without it', (tester) async {
      await tester.runAsync(() async {
        final begun = LaunchController.begin(channel: const LaunchChannel(channel));
        LaunchController.giveUp();
        answer.complete(page);
        expect(await begun, isNull);
      });
      expect(LaunchController.active.value, isNull);
    });

    testWidgets('in time, it comes as always', (tester) async {
      await tester.runAsync(() async {
        final begun = LaunchController.begin(channel: const LaunchChannel(channel));
        answer.complete(page);
        expect(await begun, isNotNull);
      });
      expect(LaunchController.active.value, isNotNull);
    });
  });

  testWidgets('no native side is no problem', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dsh/startup'),
      null,
    );
    await tester.runAsync(() => StartupTrace.step('language', () async => null));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('other platforms run the step as they always did, and say nothing', (tester) async {
    await tester.runAsync(() async {
      var ran = false;
      await StartupTrace.step('language', () async => ran = true);
      expect(ran, isTrue);
      await expectLater(StartupTrace.step('launch', () async => throw StateError('no')), throwsStateError);
    });
    StartupTrace.mark('x');
    StartupTrace.finished();
    expect(said, isEmpty);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
