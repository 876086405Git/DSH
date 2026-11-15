import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/phone_state.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/risk_notice.dart';
import 'package:dsh_app/ui/phone/android_shell_page.dart';
import 'package:dsh_app/ui/phone/phone_control_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shell/golden_harness.dart';
import '../harness.dart' show leaveAndResume, openPhoneFold, pumpPhone, settlePhone;
import '../support.dart' show FakePhoneNative, phoneStatus;
import 'support.dart';

class _Phone extends PhoneController {
  _Phone({required this.enabled});

  final bool enabled;

  @override
  PhoneState build() => PhoneState(
    loaded: true,
    status: PhoneStatus.fromMap(phoneStatus(enabled: enabled, a11y: false, androidOk: false)),
    policies: const PhonePolicies(confirmMode: PhoneConfirmMode.always),
  );

  @override
  Future<bool> refreshStatus() async => true;
}

Future<ShellNative> _pump(WidgetTester tester, {ShellNative? native, bool phoneEnabled = true}) async {
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = const Size(390 * 2, 2600 * 2);
  addTearDown(tester.view.reset);
  final fake = native ?? ShellNative();
  fake.install();
  await tester.pumpWidget(
    goldenApp(
      home: const AndroidShellPage(),
      brightness: Brightness.light,
      overrides: [phoneProvider.overrideWith(() => _Phone(enabled: phoneEnabled))],
    ),
  );
  await settlePhone(tester);
  return fake;
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Switch _switch(WidgetTester tester) => tester.widget(find.byKey(const ValueKey('android-shell-enable')));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('default page keeps technical details collapsed on a phone screen', (tester) async {
    final native = await _pump(
      tester,
      native: ShellNative(
        status: shellStatus(enabled: true, ready: true, shizukuGranted: true, uid: 2000, reasonCode: null),
      ),
    );
    tester.view.physicalSize = const Size(390 * 2, 844 * 2);
    await tester.pumpAndSettle();
    expect(find.text(appL10n.androidShellReady), findsOneWidget);
    expect(find.text(appL10n.androidShellSubtitle), findsNothing);
    expect(find.text(appL10n.androidShellEnableHint), findsNothing);
    expect(find.text(appL10n.androidShellShizukuHint), findsNothing);
    expect(find.text(appL10n.androidShellAdbHint), findsNothing);
    expect(find.byKey(const ValueKey('android-shell-uid')), findsNothing);
    expect(find.text(appL10n.androidShellLimits(30, 65536)), findsNothing);
    expect(find.byKey(const ValueKey('android-shell-authorize')), findsNothing);
    expect(find.byKey(const ValueKey('android-shell-connect-shizuku')), findsNothing);
    expect(find.byKey(const ValueKey('android-shell-stop')).hitTestable(), findsOneWidget);
    await openPhoneFold(tester, 'android-shell-details');
    expect(find.text('2000'), findsOneWidget);
    expect(find.text(appL10n.androidShellLimits(30, 65536)), findsOneWidget);
    expect(find.text(appL10n.androidShellShizukuHint), findsOneWidget);
    expect(find.text(appL10n.androidShellAdbHint), findsNothing);
    expect(native.calls.map((call) => call.method), ['androidShellStatus']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only the needed authorization or connection step is shown', (tester) async {
    final native = await _pump(tester);
    expect(find.byKey(const ValueKey('android-shell-authorize')), findsOneWidget);
    expect(find.byKey(const ValueKey('android-shell-connect-shizuku')), findsNothing);
    native.status = shellStatus(enabled: true, shizukuGranted: true, reasonCode: 'notConnected');
    await tester.tap(find.text(appL10n.androidShellRefresh));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('android-shell-authorize')), findsNothing);
    expect(find.byKey(const ValueKey('android-shell-connect-shizuku')), findsOneWidget);
    native.status = shellStatus(enabled: true, backend: 'adb', adbPaired: true, reasonCode: 'notConnected');
    await tester.tap(find.text(appL10n.androidShellRefresh));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('android-shell-pair')), findsNothing);
    expect(find.byKey(const ValueKey('android-shell-connect')), findsOneWidget);
    await openPhoneFold(tester, 'android-shell-details');
    expect(find.byKey(const ValueKey('android-shell-pair')), findsOneWidget);
  });

  testWidgets('stop failure and unknown outcome remain visible with recovery actions', (tester) async {
    final native = ShellNative(status: shellStatus(enabled: false, reasonCode: 'transportLost'))
      ..replies['androidShellStop'] = false;
    await _pump(tester, native: native);
    expect(find.text(appL10n.androidShellErrorTransportLost), findsOneWidget);
    await _tap(tester, 'android-shell-stop');
    expect(find.text(appL10n.androidShellErrorStopFailed), findsOneWidget);
    expect(find.byKey(const ValueKey('android-shell-operation-error')), findsOneWidget);
    expect(tester.widget<ListPageRow>(find.byKey(const ValueKey('android-shell-stop'))).onTap, isNotNull);
    expect(find.text(appL10n.androidShellRefresh), findsOneWidget);
    expect(find.byKey(const ValueKey('android-shell-uid')), findsNothing);
    native.replies['androidShellStop'] = true;
    await _tap(tester, 'android-shell-stop');
    expect(native.callsOf('androidShellStop'), hasLength(2));
    expect(find.byKey(const ValueKey('android-shell-operation-error')), findsNothing);
  });

  testWidgets('opening, refreshing and resuming only read standalone status', (tester) async {
    final native = await _pump(tester);
    expect(_switch(tester).value, isFalse);
    expect(_switch(tester).onChanged, isNotNull); // No Android 14, accessibility or DND prerequisite.
    expect(find.text(appL10n.androidShellConfirmationNote), findsOneWidget);
    expect(find.text('2000'), findsNothing); // A selected backend is not an actual UID.
    await _tap(tester, 'android-shell-authorize');
    expect(native.callsOf('androidShellRequestPermission'), hasLength(1));
    native.calls.clear();
    await tester.tap(find.text(appL10n.androidShellRefresh));
    await tester.pumpAndSettle();
    await leaveAndResume(tester);
    expect(native.calls.map((call) => call.method), everyElement('androidShellStatus'));
    expect(native.calls, isNotEmpty);
  });

  testWidgets('master off blocks enabling, but leaves explicit setup available', (tester) async {
    final native = await _pump(tester, phoneEnabled: false);
    expect(_switch(tester).onChanged, isNull);
    expect(find.text(appL10n.androidShellMasterOff), findsOneWidget);
    expect(tester.widget<ListPageRow>(find.byKey(const ValueKey('android-shell-authorize'))).onTap, isNotNull);
    await _tap(tester, 'android-shell-backend-adb');
    expect(native.callsOf('configureAndroidShell').single.arguments, {'enabled': false, 'backend': 'adb'});
    expect(native.callsOf('androidShellConnect'), isEmpty);
    expect(tester.widget<ListPageRow>(find.byKey(const ValueKey('android-shell-pair'))).onTap, isNotNull);
    expect(_switch(tester).value, isFalse);
  });

  testWidgets('every enable needs high risk notice despite screen always mode', (tester) async {
    final native = await _pump(tester);
    for (var attempt = 0; attempt < 2; attempt++) {
      await _tap(tester, 'android-shell-enable');
      final notice = tester.widget<RiskNoticeSheet>(find.byType(RiskNoticeSheet)).notice;
      expect(notice.id, 'phone.android-shell.enable');
      expect(notice.level, RiskLevel.high);
      expect(notice.title, appL10n.androidShellRiskTitle);
      expect(notice.body, appL10n.androidShellRiskBody);
      expect(notice.action, appL10n.androidShellRiskAction);
      expect(find.byKey(const ValueKey('risk-silence')), findsNothing);
      expect(native.callsOf('configureAndroidShell'), hasLength(attempt == 0 ? 0 : 2));
      await _tap(tester, 'risk-confirm');
      expect(_switch(tester).value, isTrue);
      await _tap(tester, 'android-shell-enable'); // Turning off never needs the risk sheet.
      expect(find.byType(RiskNoticeSheet), findsNothing);
      expect(_switch(tester).value, isFalse);
    }
    expect(native.callsOf('configureAndroidShell'), hasLength(4));
  });

  testWidgets('dismissing enable does not configure or grant permission', (tester) async {
    final native = await _pump(tester);
    await _tap(tester, 'android-shell-enable');
    await tester.tap(find.descendant(of: find.byType(SheetHeader), matching: find.byType(SheetIconButton)));
    await tester.pumpAndSettle();
    expect(native.callsOf('configureAndroidShell'), isEmpty);
    expect(native.callsOf('androidShellRequestPermission'), isEmpty);
    expect(_switch(tester).value, isFalse);
  });

  testWidgets('Shizuku connect is explicit and does not use display methods', (tester) async {
    final native = await _pump(
      tester,
      native: ShellNative(status: shellStatus(enabled: true, shizukuGranted: true, reasonCode: 'notConnected')),
    );
    expect(native.calls.map((call) => call.method), ['androidShellStatus']);
    await _tap(tester, 'android-shell-connect-shizuku');
    expect(native.callsOf('androidShellConnect'), hasLength(1));
    expect(native.callsOf('androidShellConnect').single.arguments, isEmpty);
    expect(native.callsOf('setBackgroundMode'), isEmpty);
    expect(native.callsOf('requestShizukuPermission'), isEmpty);
  });

  testWidgets('pairing and connection forms separate ports and discard the code', (tester) async {
    final native = await _pump(
      tester,
      native: ShellNative(
        status: shellStatus(enabled: true, backend: 'adb', reasonCode: 'notConnected'),
      ),
    );
    await _tap(tester, 'android-shell-pair');
    final codeField = find.byKey(const ValueKey('android-shell-pair-code'));
    final codeWidget = tester.widget<TextField>(codeField);
    expect(codeWidget.obscureText, isTrue);
    expect(codeWidget.enableSuggestions, isFalse);
    expect(codeWidget.enableIMEPersonalizedLearning, isFalse);
    await tester.enterText(codeField, '654321');
    await tester.enterText(find.byKey(const ValueKey('android-shell-pair-port')), '37111');
    await _tap(tester, 'android-shell-adb-submit');
    expect(native.callsOf('androidShellPair').single.arguments, {'code': '654321', 'port': 37111});
    await _tap(tester, 'android-shell-connect');
    final portField = find.byKey(const ValueKey('android-shell-connect-port'));
    expect(tester.widget<TextField>(portField).controller!.text, isEmpty);
    expect(find.byKey(const ValueKey('android-shell-pair-code')), findsNothing);
    await tester.enterText(portField, '42123');
    await _tap(tester, 'android-shell-adb-submit');
    expect(native.callsOf('androidShellConnect').single.arguments, {'port': 42123});
    await openPhoneFold(tester, 'android-shell-details');
    await _tap(tester, 'android-shell-pair');
    expect(tester.widget<TextField>(codeField).controller!.text, isEmpty);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('android-shell-pair-port'))).controller!.text, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), isEmpty);
  });

  testWidgets('forms validate six digits and valid optional ports before dispatch', (tester) async {
    final native = await _pump(
      tester,
      native: ShellNative(
        status: shellStatus(enabled: true, backend: 'adb', reasonCode: 'notConnected'),
      ),
    );
    await _tap(tester, 'android-shell-pair');
    bool canSubmit() =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('android-shell-adb-submit'))).onPressed != null;
    expect(canSubmit(), isFalse);
    await tester.enterText(find.byKey(const ValueKey('android-shell-pair-code')), '12345');
    await tester.pump();
    expect(canSubmit(), isFalse);
    await tester.enterText(find.byKey(const ValueKey('android-shell-pair-code')), '123456');
    await tester.enterText(find.byKey(const ValueKey('android-shell-pair-port')), '65536');
    await tester.pump();
    expect(canSubmit(), isFalse);
    expect(native.callsOf('androidShellPair'), isEmpty);
    await tester.enterText(find.byKey(const ValueKey('android-shell-pair-port')), '');
    await tester.pump();
    expect(canSubmit(), isTrue);
    await _tap(tester, 'android-shell-adb-submit');
    expect(native.callsOf('androidShellPair').single.arguments, {'code': '123456'});
  });

  testWidgets('a queued submit validates current port before dispatch', (tester) async {
    final native = await _pump(
      tester,
      native: ShellNative(
        status: shellStatus(enabled: true, backend: 'adb', reasonCode: 'notConnected'),
      ),
    );
    await _tap(tester, 'android-shell-pair');
    await tester.enterText(find.byKey(const ValueKey('android-shell-pair-code')), '654321');
    await tester.pump();
    final submit = tester.widget<FilledButton>(find.byKey(const ValueKey('android-shell-adb-submit'))).onPressed!;
    await tester.enterText(find.byKey(const ValueKey('android-shell-pair-port')), '65536');
    submit(); // No rebuilt button or disabled-state check may replace submit-time validation.
    await tester.pumpAndSettle();
    expect(native.callsOf('androidShellPair'), isEmpty);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('android-shell-pair-port')), '37111');
    await tester.pump();
    await _tap(tester, 'android-shell-adb-submit');
    expect(native.callsOf('androidShellPair').single.arguments, {'code': '654321', 'port': 37111});
  });

  testWidgets('stop remains usable during connect and ignores its late reply', (tester) async {
    final pending = Completer<Object?>();
    final native = ShellNative(
      status: shellStatus(enabled: true, backend: 'adb', adbPaired: true, reasonCode: 'notConnected'),
    );
    await _pump(tester, native: native);
    native.onCall = (call) {
      if (call.method == 'androidShellConnect') return pending.future;
      if (call.method == 'androidShellStatus') return native.status;
      if (call.method == 'androidShellStop') return true;
      return {'ok': true};
    };
    await _tap(tester, 'android-shell-connect');
    await _tap(tester, 'android-shell-adb-submit');
    expect(_switch(tester).onChanged, isNull);
    await _tap(tester, 'android-shell-stop');
    expect(native.callsOf('androidShellStop'), hasLength(1));
    pending.complete({'ok': false, 'errorCode': 'transportLost'});
    await settlePhone(tester);
    expect(find.byKey(const ValueKey('android-shell-operation-error')), findsNothing);
  });

  testWidgets('failed configure uses native status and localized stable code, not raw reason', (tester) async {
    final native = ShellNative()
      ..replies['configureAndroidShell'] = {
        'ok': false,
        'errorCode': 'identityChanged',
        'reason': 'private input 654321',
      };
    await _pump(tester, native: native);
    await _tap(tester, 'android-shell-backend-adb');
    expect(find.byKey(const ValueKey('android-shell-authorize')), findsOneWidget);
    expect(_switch(tester).value, isFalse);
    expect(find.text(appL10n.androidShellErrorIdentityChanged), findsOneWidget);
    expect(find.textContaining('identityChanged'), findsNothing);
    await openPhoneFold(tester, 'android-shell-details');
    expect(find.textContaining('identityChanged'), findsOneWidget);
    expect(find.textContaining('654321'), findsNothing);
  });

  testWidgets('master off still permits stopping and disabling an active Shell', (tester) async {
    final native = await _pump(
      tester,
      phoneEnabled: false,
      native: ShellNative(status: shellStatus(enabled: true, ready: true, uid: 2000, reasonCode: null)),
    );
    expect(find.text('2000'), findsNothing);
    expect(_switch(tester).onChanged, isNotNull);
    await _tap(tester, 'android-shell-enable');
    expect(native.callsOf('configureAndroidShell').single.arguments, {'enabled': false, 'backend': 'shizuku'});
    await _tap(tester, 'android-shell-stop');
    expect(native.callsOf('androidShellStop'), hasLength(1));
  });

  testWidgets('phone control entry stays reachable while master is off', (tester) async {
    await pumpPhone(
      tester,
      const PhoneControlScreen(),
      native: FakePhoneNative(status: phoneStatus(enabled: false)),
      size: const Size(390, 844),
    );
    await openPhoneFold(tester, 'phone-more-options');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('android-shell-entry')), 400);
    await _tap(tester, 'android-shell-entry');
    expect(find.byType(AndroidShellPage), findsOneWidget);
    expect(_switch(tester).onChanged, isNull);
    expect(find.text(appL10n.androidShellErrorNativeUnavailable), findsWidgets);
  });

  test('stable errors are friendly in both languages and unknown codes fail safely', () {
    for (final locale in [AppLocale.zhCN, AppLocale.en]) {
      final l10n = lookupL10n(locale);
      for (final code in [
        'disabled',
        'stopped',
        'notConnected',
        'shizukuMissing',
        'shizukuStopped',
        'permissionRequired',
        'adbNotPaired',
        'connectFailed',
        'identityChanged',
        'busy',
        'invalidArguments',
        'cancelled',
        'timeout',
        'confirmationDenied',
        'cleanupFailed',
        'locked',
        'confirmationUnavailable',
        'transportLost',
        'protocolMismatch',
        'nativeUnavailable',
        'invalidResponse',
        'stopFailed',
      ]) {
        expect(androidShellErrorText(l10n, code), isNot(l10n.androidShellErrorUnknown));
      }
      expect(androidShellErrorText(l10n, 'futureError'), l10n.androidShellErrorUnknown);
    }
  });
}
