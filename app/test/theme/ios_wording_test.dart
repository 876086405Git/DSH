// What iOS calls things, and what it doesn't offer. Other platforms keep their wording.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:dsh_app/ui/chat/widgets/image_actions.dart';
import 'package:dsh_app/ui/settings/voice_settings_page.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(Widget home) => ProviderScope(
  child: MaterialApp(
    theme: buildLightTheme(),
    locale: AppLocale.zhCN,
    supportedLocales: AppLocale.supported,
    localizationsDelegates: L10n.localizationsDelegates,
    home: home,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a refused save asks for Photos on iOS', (tester) async {
    expect(gallerySaveErrorText('permission'), appL10n.iosPhotosDenied);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('a refused save asks for storage on Android', (tester) async {
    expect(gallerySaveErrorText('permission'), appL10n.chatImageStorageDenied);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('iOS offers reading and call settings without a local voice model', (tester) async {
    await tester.pumpWidget(_app(const VoiceSettingsPage()));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(appL10n.iosVoiceSystemHint), findsOneWidget);
    expect(find.byKey(const ValueKey('speech-voice')), findsOneWidget);
    expect(find.byKey(const ValueKey('speech-call-pause')), findsOneWidget);
    expect(find.text(appL10n.voiceModelSection), findsNothing);
    expect(find.text(appL10n.voiceModeEngineHint), findsNothing);
    expect(find.text(appL10n.voiceModeAutoHint), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android keeps all of it', (tester) async {
    await tester.pumpWidget(_app(const VoiceSettingsPage()));
    await tester.pump(const Duration(milliseconds: 100));
    for (final mode in VoiceMode.values) {
      expect(find.byKey(ValueKey('voice-mode-${mode.name}')), findsOneWidget);
    }
    expect(find.text(appL10n.voiceModelSection), findsWidgets);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
