// The typed wrapper over `dsh/phone`: parsing the contract's maps, and staying
// usable when the native side is missing or throws.

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final channel = PhoneChannel();

  test('status revision distinguishes absent metadata from malformed native snapshots', () {
    expect(PhoneStatus.fromMap({}).statusRevisionPresent, isFalse);
    for (final value in <Object?>[null, true, '1', 1.0, 0, -1]) {
      final parsed = PhoneStatus.fromMap({'statusRevision': value});
      expect(parsed.ready, isTrue);
      expect(parsed.statusRevisionPresent, isTrue);
      expect(parsed.statusRevision, isNull);
    }
    final parsed = PhoneStatus.fromMap({'statusRevision': 42});
    expect(parsed.statusRevision, 42);
    expect(parsed.copyWith(enabled: true).statusRevision, 42);
    final unavailable = parsed.copyWith(ready: false, error: 'offline');
    expect(unavailable.ready, isFalse);
    expect(unavailable.statusRevision, 42);
    expect(unavailable.copyWith(ready: false, error: null).error, isNull);
  });

  test('task protocol parses selected identity and keeps legacy isolated', () async {
    FakePhoneNative(status: {
      ...phoneStatus(taskId: 9, taskActive: true),
      'taskProtocol': 1, 'parallelLimit': 1, 'selectedTaskId': 12,
      'tasks': [
        {'id': 9, 'active': true, 'identity': 'legacy'},
        {'id': 12, 'sessionId': 'A', 'runId': 'epoch:1', 'generation': 4,
          'endedRunId': 'epoch:1', 'endedGeneration': 4, 'completion': 'other', 'pendingCalls': 0},
      ],
    }).install();
    final value = await channel.status();
    expect(value.taskProtocol, 1); expect(value.parallelLimit, 1);
    expect(value.task.id, 12); expect(value.task.sessionId, 'A');
    expect(value.task.endedRunId, 'epoch:1'); expect(value.task.endedGeneration, 4);
    expect(value.task.completion, 'other'); expect(value.tasks.first.sessionId, isNull);
    expect(PhoneTaskStatus.fromMap({'completion': 'success'}).completion, 'unknown');
    expect(PhoneTaskStatus.fromMap({}).completion, 'unknown');
  });

  test('resource waiting parses only its own typed target and nonnegative integer elapsed time', () {
    final known = PhoneTaskStatus.fromMap({
      'waitingForApp': {'kind': 'known', 'packageName': 'example.app', 'uid': 10123, 'holderSession': 'private'},
      'waitingForMs': 1501,
    });
    expect(known.waitingForApp!.packageName, 'example.app');
    expect(known.waitingForMs, 1501); expect(known.waitingForResources, isTrue);
    final unknown = PhoneTaskStatus.fromMap({'waitingForApp': {'kind': 'unknown'}});
    expect(unknown.waitingForApp, isNotNull); expect(unknown.waitingForApp!.packageName, isNull);
    expect(unknown.waitingForMs, 0);
    for (final invalid in [null, 'app', {'kind': 'known'}, {'kind': 'known', 'packageName': ' '},
      {'kind': 'unknown', 'packageName': 'invented'}, {'kind': 'future', 'packageName': 'example.app'}]) {
      expect(PhoneTaskStatus.fromMap({'waitingForApp': invalid}).waitingForApp, isNull);
    }
    for (final invalid in [null, -1, 1000.5, '1000', true]) {
      expect(PhoneTaskStatus.fromMap({'waitingForMs': invalid}).waitingForMs, 0);
    }
    expect(PhoneTaskStatus.fromMap({}).waitingForResources, isFalse);
    expect(PhoneTaskStatus.fromMap({'waitingForScreen': 'main'}).waitingForResources, isTrue);
    expect(PhoneTaskStatus.fromMap({'waitingForScreen': 'other'}).waitingForResources, isFalse);
  });

  test('status parses every field of the contract', () async {
    final native = FakePhoneNative(
      status: phoneStatus(
        a11y: true,
        notifications: false,
        mode: 'shizuku',
        backgroundReady: false,
        backgroundReason: 'Shizuku 没有在运行',
        shizukuInstalled: true,
        wirelessDebugging: null,
        paired: true,
        taskActive: true,
        taskApp: '美团',
        taskPaused: true,
      ),
    )..install();
    final s = await channel.status();
    expect(native.methods, ['status']);
    expect(s.ready, isTrue);
    expect(s.enabled, isTrue);
    expect(s.bridgeListening, isTrue);
    expect(s.a11y.ok, isTrue);
    expect(s.notifications, isFalse);
    expect(s.background.mode, PhoneBackgroundMode.shizuku);
    expect(s.background.reason, 'Shizuku 没有在运行');
    expect(s.background.androidOk, isTrue);
    expect(s.background.shizuku.installed, isTrue);
    expect(s.background.shizuku.running, isFalse);
    expect(s.background.adb.wirelessDebugging, isNull);
    expect(s.background.adb.paired, isTrue);
    expect(s.task.active, isTrue);
    expect(s.task.app, '美团');
    expect(s.task.paused, isTrue);
    expect(s.device.manufacturer, 'vivo');
    expect(s.device.sdkInt, 35);
    expect(s.device.mayNeedRestrictedSettings, isTrue);
  });

  test('a status without the optional device entry still parses', () async {
    FakePhoneNative(status: phoneStatus(device: null)).install();
    final s = await channel.status();
    expect(s.ready, isTrue);
    expect(s.device.manufacturer, isNull);
    // Unknown → the restricted-settings hint may apply.
    expect(s.device.mayNeedRestrictedSettings, isTrue);
    expect(const PhoneDevice(sdkInt: 32, sideloaded: true).mayNeedRestrictedSettings, isFalse);
    expect(const PhoneDevice(sdkInt: 34, sideloaded: false).mayNeedRestrictedSettings, isFalse);
  });

  test('a missing native side reads as 未就绪 and every call degrades', () async {
    removePhoneNative();
    final s = await channel.status();
    expect(s.ready, isFalse);
    expect(await channel.setEnabled(true), isFalse);
    expect(await channel.openAccessibilitySettings(), isFalse);
    final test = await channel.testScreen();
    expect(test.ok, isFalse);
    expect(test.reason, phoneNotReadyReason);
    final pair = await channel.adbPair('123456');
    expect(pair.ok, isFalse);
    expect(pair.reason, phoneNotReadyReason);
    expect(await channel.getPolicies(), isNull);
    expect(await channel.actionLog(), isEmpty);
  });

  test('PlatformException becomes a reason, not a crash', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(phoneMethods, (
      call,
    ) async {
      throw PlatformException(code: 'boom', message: '无障碍服务没有连接');
    });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        phoneMethods,
        null,
      ),
    );
    final s = await channel.status();
    expect(s.ready, isFalse);
    expect(s.error, '无障碍服务没有连接');
    final r = await channel.testScreen();
    expect(r.ok, isFalse);
    expect(r.reason, '无障碍服务没有连接');
    expect((await channel.adbConnect()).reason, '无障碍服务没有连接');
  });

  test('method arguments follow the contract', () async {
    final native = FakePhoneNative()..install();
    await channel.setEnabled(true);
    await channel.setBackgroundMode(PhoneBackgroundMode.adb);
    await channel.adbPair('482913', port: 37123);
    await channel.adbConnect(port: 45269);
    await channel.actionLog(limit: 7);
    await channel.setPolicies(
      const PhonePolicies(
        denyPackages: ['cmb.pb'],
        confirmEveryWritePackages: ['com.tencent.mm'],
        labels: {'cmb.pb': '招商银行'},
      ),
    );
    expect(native.callsOf('setEnabled').single.arguments, {'enabled': true});
    expect(native.callsOf('setBackgroundMode').single.arguments, {'mode': 'adb'});
    expect(native.callsOf('adbPair').single.arguments, {'code': '482913', 'port': 37123});
    expect(native.callsOf('adbConnect').single.arguments, {'port': 45269});
    expect(native.callsOf('actionLog').single.arguments, {'limit': 7});
    // The two lists, 始终允许 and the confirm mode go over the wire.
    expect(native.callsOf('setPolicies').single.arguments, {
      'denyPackages': ['cmb.pb'],
      'confirmEveryWritePackages': ['com.tencent.mm'],
      'alwaysAllowEnabled': false,
      'alwaysAllowPackages': <String>[],
      'confirmMode': 'ask',
    });
  });

  test('policies: rules, labels, defaults and edits', () async {
    FakePhoneNative(
      policies: {
        ...defaultPolicies(),
        'labels': {'com.unionpay': '云闪付 App'},
        'defaults': {
          'denyPackages': ['com.eg.android.AlipayGphone', 'com.unionpay'],
          'confirmEveryWritePackages': ['com.tencent.mm'],
        },
      },
    ).install();
    final p = (await channel.getPolicies())!;
    expect(p.ruleFor('com.eg.android.AlipayGphone'), AppRule.deny);
    expect(p.ruleFor('com.tencent.mm'), AppRule.confirmEachStep);
    expect(p.ruleFor('com.taobao.taobao'), AppRule.normal);
    expect(p.labelFor('com.unionpay'), '云闪付 App'); // native label wins
    expect(p.labelFor('com.tencent.mm'), '微信'); // built-in fallback
    expect(p.labelFor('org.example.x'), 'org.example.x');
    expect(p.defaultRuleFor('com.tencent.mm'), AppRule.confirmEachStep);

    final edited = p.withRule('com.tencent.mm', AppRule.normal).withRule('com.taobao.taobao', AppRule.deny);
    expect(edited.confirmEveryWritePackages, isEmpty);
    expect(edited.denyPackages, contains('com.taobao.taobao'));
    expect(edited.defaultConfirm, ['com.tencent.mm']);
  });

  test('action log entries tolerate time formats and odd decisions', () async {
    FakePhoneNative(
      log: [
        {'time': 1761000000, 'tool': 'tap', 'decision': 'denied'},
        {'time': '2026-10-23T08:00:00Z', 'tool': 'type', 'decision': 'confirmed-app'},
        {'tool': 'scroll', 'decision': 'something-new'},
        {'time': 1761000000000, 'tool': 'handoff', 'decision': 'timeout'},
        {'time': 1761000000000, 'tool': 'tap', 'decision': 'allowed'},
        {'time': 1761000000000, 'tool': 'open', 'decision': 'refused:system-page'},
        {'time': 1761000000000, 'tool': 'tap', 'decision': 'paused'},
      ],
    ).install();
    final log = await channel.actionLog();
    expect(log, hasLength(7));
    expect(log[0].time, DateTime.fromMillisecondsSinceEpoch(1761000000 * 1000));
    expect(log[0].decision, PhoneDecision.denied);
    expect(log[1].time, DateTime.utc(2026, 10, 23, 8).toLocal());
    expect(log[1].decision, PhoneDecision.allowed);
    expect(log[2].time, isNull);
    expect(log[2].decision, PhoneDecision.unknown);
    expect(log[2].rawDecision, 'something-new');
    // Native `timeout` is the tool running out of time, not an unanswered question.
    expect(log[3].decision, PhoneDecision.failed);
    // Native `allowed` means no question was needed.
    expect(log[4].decision, PhoneDecision.done);
    expect(log[5].decision, PhoneDecision.blocked);
    expect(log[6].decision, PhoneDecision.stopped);
  });
}
