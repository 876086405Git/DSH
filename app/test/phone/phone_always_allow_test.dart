// 始终允许: the two wire fields, the copies that must carry them, the
// controller write, and the page (danger notice first, list and removal).

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/ui/phone/always_allow_page.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PhonePolicies', () {
    test('missing fields read as off and empty; only an explicit true turns it on', () {
      final unset = PhonePolicies.fromMap({});
      expect(unset.alwaysAllowEnabled, isFalse);
      expect(unset.alwaysAllowPackages, isEmpty);
      expect(PhonePolicies.fromMap({'alwaysAllowEnabled': true}).alwaysAllowEnabled, isTrue);
      for (final value in <Object?>[false, 'true', 1, 0, null]) {
        expect(PhonePolicies.fromMap({'alwaysAllowEnabled': value}).alwaysAllowEnabled, isFalse);
      }
      expect(
        PhonePolicies.fromMap({
          'alwaysAllowPackages': ['com.taobao.taobao', '', 3, null],
        }).alwaysAllowPackages,
        ['com.taobao.taobao'],
      );
    });

    test('toWire carries both fields and round-trips', () {
      const p = PhonePolicies(alwaysAllowEnabled: true, alwaysAllowPackages: ['com.taobao.taobao']);
      expect(p.toWire()['alwaysAllowEnabled'], isTrue);
      expect(p.toWire()['alwaysAllowPackages'], ['com.taobao.taobao']);
      final back = PhonePolicies.fromMap(p.toWire());
      expect(back.alwaysAllowEnabled, isTrue);
      expect(back.alwaysAllowPackages, ['com.taobao.taobao']);
    });

    test('withAlwaysAllow keeps every other field', () {
      const p = PhonePolicies(
        denyPackages: ['cmb.pb'],
        confirmEveryWritePackages: ['com.tencent.mm'],
        labels: {'cmb.pb': '招商银行'},
        defaultDeny: ['com.icbc'],
        defaultConfirm: ['com.tencent.mm'],
        confirmMode: PhoneConfirmMode.always,
        unlocks: {PhoneUnlock.secretFields},
        localOcrEnabled: false,
      );
      final next = p.withAlwaysAllow(enabled: true, packages: ['com.taobao.taobao']);
      expect(next.alwaysAllowEnabled, isTrue);
      expect(next.alwaysAllowPackages, ['com.taobao.taobao']);
      expect(next.denyPackages, p.denyPackages);
      expect(next.confirmEveryWritePackages, p.confirmEveryWritePackages);
      expect(next.labels, p.labels);
      expect(next.defaultDeny, p.defaultDeny);
      expect(next.defaultConfirm, p.defaultConfirm);
      expect(next.confirmMode, p.confirmMode);
      expect(next.unlocks, p.unlocks);
      expect(next.localOcrEnabled, p.localOcrEnabled);
    });

    test('the existing with* keep both 始终允许 fields', () {
      const p = PhonePolicies(alwaysAllowEnabled: true, alwaysAllowPackages: ['com.taobao.taobao']);
      for (final next in [
        p.withRule('com.taobao.taobao', AppRule.deny),
        p.withConfirmMode(PhoneConfirmMode.task),
        p.withUnlock(PhoneUnlock.ownApp, true),
        p.withLocalOcrEnabled(false),
      ]) {
        expect(next.alwaysAllowEnabled, isTrue);
        expect(next.alwaysAllowPackages, ['com.taobao.taobao']);
      }
    });
  });

  group('setAlwaysAllow', () {
    late PhoneTestRuntime runtime;

    ProviderContainer make() {
      runtime = PhoneTestRuntime(LocalRuntimeState(loaded: true, status: runningRuntime));
      final c = ProviderContainer(
        overrides: [
          localRuntimeProvider.overrideWith(() => runtime),
          activeHostProvider.overrideWith(() => FixedActiveHost(HostRef.local)),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<void> settle() async {
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('writes both fields and updates the state', () async {
      final native = FakePhoneNative()..install();
      final c = make();
      c.read(phoneProvider);
      await settle();
      final ok = await c.read(phoneProvider.notifier).setAlwaysAllow(enabled: true, packages: ['com.taobao.taobao']);
      expect(ok, isTrue);
      final args = native.callsOf('setPolicies').single.arguments as Map;
      expect(args['alwaysAllowEnabled'], isTrue);
      expect(args['alwaysAllowPackages'], ['com.taobao.taobao']);
      // The other policy fields still go along, as before.
      expect(args['denyPackages'], defaultPolicies()['denyPackages']);
      expect(args['confirmMode'], 'ask');
      final s = c.read(phoneProvider);
      expect(s.policies!.alwaysAllowEnabled, isTrue);
      expect(s.policies!.alwaysAllowPackages, ['com.taobao.taobao']);
    });

    test('a refused write changes nothing', () async {
      final native = FakePhoneNative()..accept = false;
      native.install();
      final c = make();
      c.read(phoneProvider);
      await settle();
      final ok = await c.read(phoneProvider.notifier).setAlwaysAllow(enabled: true, packages: ['com.taobao.taobao']);
      expect(ok, isFalse);
      expect(c.read(phoneProvider).policies!.alwaysAllowEnabled, isFalse);
      expect(c.read(phoneProvider).policies!.alwaysAllowPackages, isEmpty);
    });
  });

  group('page', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('turning it on warns first; 取消 changes nothing', (tester) async {
      final h = await pumpPhone(tester, const PhoneAlwaysAllowPage());
      await tester.tap(find.byKey(const ValueKey('always-allow-switch')));
      await tester.pumpAndSettle();
      expect(find.text('开启后 DSH 可不再询问就把内容发到这些应用，发出后无法撤回。'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(h.native!.callsOf('setPolicies'), isEmpty);

      await tester.tap(find.byKey(const ValueKey('always-allow-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认开启'));
      await tester.pumpAndSettle();
      final args = h.native!.callsOf('setPolicies').single.arguments as Map;
      expect(args['alwaysAllowEnabled'], isTrue);
      expect(args['alwaysAllowPackages'], isEmpty);
      expect(find.text('还没有允许的应用'), findsOneWidget);
    });

    testWidgets('an allowed app can be removed', (tester) async {
      final native = FakePhoneNative(
        policies: {
          ...defaultPolicies(),
          'alwaysAllowEnabled': true,
          'alwaysAllowPackages': ['com.taobao.taobao'],
        },
      );
      final h = await pumpPhone(tester, const PhoneAlwaysAllowPage(), native: native);
      expect(find.text('淘宝'), findsOneWidget);
      await tester.tap(find.text('移除'));
      await tester.pumpAndSettle();
      final args = h.native!.callsOf('setPolicies').single.arguments as Map;
      expect(args['alwaysAllowEnabled'], isTrue);
      expect(args['alwaysAllowPackages'], isEmpty);
      expect(find.text('还没有允许的应用'), findsOneWidget);
    });

    testWidgets('the settings row says 未开启 when off', (tester) async {
      await pumpPhone(tester, const PhoneControlScreen(), native: FakePhoneNative());
      expect(find.text('始终允许'), findsOneWidget);
      expect(find.text('未开启'), findsOneWidget);
    });

    testWidgets('the settings row counts the allowed apps', (tester) async {
      await pumpPhone(
        tester,
        const PhoneControlScreen(),
        native: FakePhoneNative(
          policies: {
            ...defaultPolicies(),
            'alwaysAllowEnabled': true,
            'alwaysAllowPackages': ['com.taobao.taobao', 'com.tencent.mm'],
          },
        ),
      );
      expect(find.text('已允许 2 个应用'), findsOneWidget);
    });
  });
}
