import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/streaming_asr_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/state/voice_state.dart';
import 'package:dsh_app/ui/chat/voice/voice_bridge.dart';
import 'package:dsh_app/ui/settings/voice_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/composer_fakes.dart' show FakeVoiceBridge;
import '../chat/support/harness.dart';
import '../phone/support.dart' show FixedActiveHost, FixedHosts;

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('saved route is ready before first use and persists across provider recreation', () async {
    SharedPreferences.setMockInitialValues({VoiceSettingsController.preferenceKey: 'engine'});
    final first = ProviderContainer();
    expect(await first.read(voiceSettingsProvider.notifier).ready(), VoiceMode.engine);
    await first.read(voiceSettingsProvider.notifier).setMode(VoiceMode.system);
    first.dispose();
    final next = ProviderContainer();
    addTearDown(next.dispose);
    expect(await next.read(voiceSettingsProvider.notifier).ready(), VoiceMode.system);
    expect((await SharedPreferences.getInstance()).getString(VoiceSettingsController.preferenceKey), 'system');
  });

  test('an unknown stored route safely resolves to automatic', () async {
    SharedPreferences.setMockInitialValues({VoiceSettingsController.preferenceKey: 'future-mode'});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(await container.read(voiceSettingsProvider.notifier).ready(), VoiceMode.auto);
  });

  group('语音模型 on HarmonyOS', () {
    final zh = lookupL10n(AppLocale.zhCN);
    Future<void> page(
      WidgetTester tester,
      String os, {
      HostRef host = HostRef.local,
      List<String> languages = const [],
      double height = 1400,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(390, height);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        testApp(
          const VoiceSettingsPage(),
          overrides: [
            operatingSystemProvider.overrideWithValue(os),
            activeHostProvider.overrideWith(() => FixedActiveHost(host)),
            hostsProvider.overrideWith(FixedHosts.new),
            voiceBridgeProvider.overrideWithValue(
              FakeVoiceBridge(caps: VoiceCapabilities(recognizer: true, recorder: true, languages: languages)),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
    }

    const engine = ValueKey('voice-mode-engine');

    testWidgets('系统 says it is the system\'s, and Chinese only when that is all it takes', (tester) async {
      await page(tester, 'ohos', languages: const ['zh-CN']);
      expect(find.text(zh.harmonyVoiceSystemHintChinese), findsOneWidget);
      expect(find.text(zh.voiceModeSystemHint), findsNothing);
      expect(find.text(zh.harmonyVoiceAutoHint), findsOneWidget);
    });

    testWidgets('with no word on languages it doesn\'t guess', (tester) async {
      await page(tester, 'ohos');
      expect(find.text(zh.harmonyVoiceSystemHint), findsOneWidget);
      expect(find.text(zh.harmonyVoiceSystemHintChinese), findsNothing);
    });

    testWidgets('on Android its hints stay', (tester) async {
      await page(tester, 'android', languages: const ['zh-CN']);
      expect(find.text(zh.voiceModeSystemHint), findsOneWidget);
      expect(find.text(zh.voiceModeAutoHint), findsOneWidget);
    });

    test('the bridge reads what the native side says it takes', () async {
      const methods = MethodChannel('dsh/voice');
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        methods,
        (call) async => {
          'recognizer': true,
          'recorder': true,
          'languages': ['zh-CN', 7],
        },
      );
      addTearDown(() => messenger.setMockMethodCallHandler(methods, null));
      expect((await MethodChannelVoiceBridge().capabilities()).languages, ['zh-CN']);
    });

    testWidgets('on its own engine: a plain line instead of a mode that can only loop', (tester) async {
      await page(tester, 'ohos');
      expect(find.byKey(engine), findsNothing);
      expect(find.byType(VoiceModelCard), findsNothing);
      expect(find.text(zh.harmonyVoiceLocalLine), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-mode-system')), findsOneWidget);
    });

    testWidgets('a remote host keeps it: its recognizer is that host\'s', (tester) async {
      await page(tester, 'ohos', host: const HostRef.ssh('pc'));
      expect(find.byKey(engine), findsOneWidget);
      expect(find.text(zh.harmonyVoiceLocalLine), findsNothing);
    });

    testWidgets('on Android: as ever', (tester) async {
      await page(tester, 'android');
      expect(find.byKey(engine), findsOneWidget);
      expect(find.byType(VoiceModelCard), findsOneWidget);
      expect(find.text(zh.harmonyVoiceLocalLine), findsNothing);
    });

    testWidgets('朗读, 实时字幕 on the system recognizer and 通话 are there; DeepSeek and a cloud service still listen', (tester) async {
      await page(tester, 'ohos', height: 4000);
      expect(find.byKey(const ValueKey('speech-voice')), findsOneWidget);
      expect(find.text(zh.speechLiveSection), findsOneWidget);
      expect(find.byKey(const ValueKey('live-system-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('live-model-card')), findsNothing);
      expect(find.text(zh.speechLiveSystemFooter), findsOneWidget);
      expect(find.byKey(const ValueKey('speech-call-barge-in')), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-mode-deepseek')), findsOneWidget);
      expect(find.byKey(const ValueKey('voice-mode-cloud')), findsOneWidget);
    });

    testWidgets('on Android 朗读 and 通话 stay', (tester) async {
      await page(tester, 'android', height: 4000);
      expect(find.byKey(const ValueKey('speech-voice')), findsOneWidget);
      expect(find.text(zh.speechLiveSection), findsOneWidget);
      expect(find.byKey(const ValueKey('speech-call-barge-in')), findsOneWidget);
    });

    test('a mode saved for a remote host is automatic on its own engine', () {
      expect(voiceModeOnHarmonyLocal(VoiceMode.engine), VoiceMode.auto);
      expect(voiceModeOnHarmonyLocal(VoiceMode.system), VoiceMode.system);
      expect(voiceModeOnHarmonyLocal(VoiceMode.auto), VoiceMode.auto);
    });
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('voice choices at 320dp, scale $scale, ${brightness.name} remain selectable', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 800);
        addTearDown(tester.view.reset);
        if (scale == 2) AppLocale.use(AppLocale.en);
        await tester.pumpWidget(
          testApp(
            Builder(
              builder: (context) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
                child: const VoiceSettingsPage(),
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final rows = [for (final mode in VoiceMode.values) find.byKey(ValueKey('voice-mode-${mode.name}'))];
        for (final row in rows) {
          await tester.ensureVisible(row);
          await tester.pumpAndSettle();
          expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
          expect(tester.getRect(row).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(row).right, lessThanOrEqualTo(320));
        }
        // Mid-screen: at the top it would sit under the page's floating header.
        unawaited(
          Scrollable.ensureVisible(tester.element(find.byKey(const ValueKey('voice-mode-engine'))), alignment: 0.5),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('voice-mode-engine')));
        await tester.pumpAndSettle();
        final container = ProviderScope.containerOf(tester.element(find.byType(VoiceSettingsPage)));
        expect(container.read(voiceSettingsProvider), VoiceMode.engine);
        expect((await SharedPreferences.getInstance()).getString(VoiceSettingsController.preferenceKey), 'engine');
        expect(tester.takeException(), isNull);
      });
    }
  }

  group('the HarmonyOS captions card', () {
    final zh = lookupL10n(AppLocale.zhCN);

    Future<void> card(WidgetTester tester, Future<SystemAsrReadiness> Function() probe) => tester.pumpWidget(
      ProviderScope(
        overrides: [ohosStreamingAsrReadyProvider.overrideWith((ref) => probe())],
        child: MaterialApp(
          locale: const Locale('zh'),
          supportedLocales: L10n.supportedLocales,
          localizationsDelegates: L10n.localizationsDelegates,
          theme: testTheme(Brightness.light),
          home: const Scaffold(body: SystemAsrCard()),
        ),
      ),
    );

    testWidgets('ready says so and offers nothing to download', (tester) async {
      await card(tester, () async => SystemAsrReadiness.ready);
      await tester.pumpAndSettle();
      expect(find.text(zh.voiceModelReady), findsOneWidget);
      expect(find.text(zh.speechLiveSystemReadyNote), findsOneWidget);
      expect(find.byKey(const ValueKey('live-system-retry')), findsNothing);
      expect(find.text(zh.voiceModelDownload), findsNothing);
    });

    testWidgets('busy yields and asks again only when told', (tester) async {
      var asked = 0;
      await card(tester, () async {
        asked++;
        return SystemAsrReadiness.busy;
      });
      await tester.pumpAndSettle();
      expect(find.text(zh.speechLiveSystemBusy), findsOneWidget);
      expect(asked, 1);
      await tester.tap(find.byKey(const ValueKey('live-system-retry')));
      await tester.pumpAndSettle();
      expect(asked, 2);
    });

    testWidgets('a failed probe shows its reason, not a missing download', (tester) async {
      await card(tester, () async => throw StateError('offline resources missing'));
      await tester.pumpAndSettle();
      expect(find.text(zh.voiceModelFailed), findsOneWidget);
      expect(find.textContaining('offline resources missing'), findsOneWidget);
      expect(find.byKey(const ValueKey('live-system-retry')), findsOneWidget);
    });
  });
}
