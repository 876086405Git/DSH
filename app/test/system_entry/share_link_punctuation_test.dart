// ignore_for_file: depend_on_referenced_packages
import 'package:dsh_app/links/app_links.dart';
import 'package:dsh_app/links/share_intake.dart';
import 'package:dsh_app/ui/web/web_home.dart';
import 'package:dsh_app/ui/web/dsh_web_launcher.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import '../web/support/fake_webview.dart';

import 'package:dsh_app/share_code/share_codec.dart';
import 'package:dsh_app/share_code/share_link.dart';
import 'package:dsh_app/share_code/share_models.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/share_code/import_sheet.dart';
import 'package:dsh_app/ui/share_code/share_code_host.dart';
import 'package:dsh_app/ui/shell/system_entry_host.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

void main() {
  codecCases();
  for (final entry in ['native', 'web']) {
    for (final punctuation in ['bare', 'period', 'parenthesis', 'damaged']) {
      testWidgets('iOS original share channel opens valid import sheet entry=$entry punctuation=$punctuation', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        for (final name in ['dsh/share', 'dsh/shortcuts']) {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(name), (_) async => true);
        }
        try {
          final harness = ChatHarness();
          WebViewPlatform.instance = FakeWebViewPlatform();
          await tester.pumpWidget(
            testApp(
              Scaffold(
                body: Stack(
                  fit: StackFit.expand,
                  children: [
                    const LinkHost(),
                    const ShareCodeHost(),
                    if (entry == 'native') const SystemEntryHost() else const WebHome(),
                  ],
                ),
              ),
              overrides: [
                ...harness.overrides,
                operatingSystemProvider.overrideWithValue('ios'),
                dshWebAccessProvider.overrideWithValue(SshDshWeb(Uri.parse('http://127.0.0.1:41234/'), 'fixture')),
              ],
            ),
          );
          await pumpFrames(tester);
          const payload = PluginShare(
            SharedPlugin(
              name: '@deepseek-ai/dsh-experimental-session-titles-bundle',
              source: PluginSourceKind.official,
              title: '普通分享标点案例',
            ),
          );
          var code = encodeShareCode(payload);
          if (punctuation == 'damaged') code = '${code.substring(0, code.length - 1)}${code.endsWith('A') ? 'B' : 'A'}';
          final url = ShareLink.inline(ShareKind.plugin, code).webLink;
          await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            'dsh/share',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('share', {
                'text': switch (punctuation) {
                  'period' => '试试这个：$url。',
                  'parenthesis' => '（$url）',
                  _ => url,
                },
                'files': <Object>[],
              }),
            ),
            (_) {},
          );
          for (var i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 50));
          }
          if (punctuation == 'damaged') {
            expect(find.byType(ShareImportSheet), findsNothing);
            expect(find.byType(SnackBar), findsOneWidget);
          } else {
            expect(find.byType(ShareImportSheet), findsOneWidget);
            expect(tester.widget<ShareImportSheet>(find.byType(ShareImportSheet)).payload.toJson(), payload.toJson());
          }
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(milliseconds: 500));
          debugDefaultTargetPlatformOverride = null;
          for (final name in ['dsh/share', 'dsh/shortcuts']) {
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(name), null);
          }
        }
      });
    }
  }
}

void codecCases() {
  const payload = PluginShare(
    SharedPlugin(name: '@deepseek-ai/dsh-experimental-session-titles-bundle', source: PluginSourceKind.official),
  );
  for (final os in ['ios', 'android', 'ohos']) {
    test('$os incoming text keeps its original content and platform extraction policy', () {
      debugDefaultTargetPlatformOverride = os == 'ios' ? TargetPlatform.iOS : TargetPlatform.android;
      try {
        final code = encodeShareCode(payload);
        final url = ShareLink.inline(ShareKind.plugin, code).webLink;
        final text = '试试这个：$url。';
        final share = IncomingShare(text: text);
        expect(share.text, text);
        expect(share.composedText, text);
        if (os == 'ios') {
          expect(decodeShareCode(share.shareLink!.code!).toJson(), payload.toJson());
        } else {
          expect(share.shareLink!.code, '$code。');
          expect(() => decodeShareCode(share.shareLink!.code!), throwsA(isA<ShareDecodeException>()));
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
  test('iOS current and legacy gist links preserve the exact id and checksum', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      const gist = ShareLink.gist('0123456789abcdef01234567', 'Ab_cd-12');
      for (final url in [
        gist.appLink.toString(),
        gist.webLink,
        '${legacyShareLandingUrls.single}#gist=${gist.gistId}&c=${gist.gistSum}',
      ]) {
        final link = IncomingShare(text: '（$url）').shareLink!;
        expect(link.gistId, gist.gistId);
        expect(link.gistSum, gist.gistSum);
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
  test('iOS leaves code punctuation and encoded parameters intact and still rejects damaged checksums', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      const code = 'ab_cd-ef.Gh_iJ-kL';
      final encoded = '$shareLandingUrl#p=ab%5Fcd-ef.Gh%5FiJ-kL';
      expect(IncomingShare(text: '（$encoded）').shareLink!.code, code);
      expect(
        () => decodeShareCode(IncomingShare(text: '$encoded。').shareLink!.code!),
        throwsA(isA<ShareDecodeException>()),
      );
      final valid = ShareLink.inline(ShareKind.plugin, encodeShareCode(payload)).webLink;
      expect(
        IncomingShare(
          text: valid,
          files: const [SharedFile(path: '/unused', name: 'notes.txt')],
        ).shareLink,
        isNull,
      );
      expect(IncomingShare(text: valid, skipped: const [SkippedShare(ShareSkipReason.unreadable)]).shareLink, isNull);
      // The general parser deliberately keeps its previous contract.
      expect(ShareLink.find('（$valid）')!.code, endsWith('）'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
