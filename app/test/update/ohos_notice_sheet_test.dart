// HarmonyOS only tells: the update sheet offers the release page the feed
// names, never a download, and says the page may not have a package yet.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/update/update_sheet.dart';
import 'package:dsh_app/ui/update/update_tiles.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

ReleaseInfo _release({String? page}) => parseUpdateManifest({
  'schema': 1,
  'version': '1.2.0+7',
  'tag': 'v1.2.0',
  'notes': '- 新东西',
  'page': ?page,
  'assets': {
    'arm64': {'name': 'dsh-go-1.2.0-arm64.apk', 'url': 'https://go.dshtui.com/dsh-go-1.2.0-arm64.apk', 'size': 1},
  },
}, base: Uri.parse('https://go.dshtui.com/'));

class _Notice extends AppUpdateController {
  _Notice(this.release, {this.noticeOnly = true, this.skipped});

  final ReleaseInfo? release;
  final bool noticeOnly;
  final String? skipped;

  @override
  AppUpdateState build() => AppUpdateState(
    loaded: true,
    installable: false,
    noticeOnly: noticeOnly,
    current: AppVersion.tryParse('1.1.0+9')!,
    check: release == null ? UpdateCheckPhase.idle : UpdateCheckPhase.available,
    latest: release,
    skippedVersion: skipped,
  );

  @override
  Future<void> get ready async {}
}

Future<void> _pump(WidgetTester tester, Widget child, _Notice notice) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: Scaffold(body: SingleChildScrollView(child: child)),
      brightness: Brightness.light,
      overrides: [
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
        ),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        appUpdateProvider.overrideWith(() => notice),
      ],
    ),
  );
  await tester.pump();
}

void main() {
  final l10n = lookupL10n(AppLocale.zhCN);
  const page = 'https://updates.example/ohos/releases/1.2.0';

  testWidgets('a page the feed names: open it, later or skip, nothing to download', (tester) async {
    await _pump(tester, const UpdateSheet(), _Notice(_release(page: page)));
    expect(find.text(l10n.harmonyUpdateNoticeTitle), findsOneWidget);
    expect(find.text(l10n.harmonyUpdateNoticeText), findsOneWidget);
    // Whether a phone can install a HAP by hand isn't for this to promise.
    expect(l10n.harmonyUpdateNoticeText, isNot(contains('手动安装')));
    expect(l10n.harmonyUpdateNoticeTitle, contains('获取方式'));
    expect(find.text(l10n.updateOpenReleasePage), findsOneWidget);
    expect(find.text(l10n.commonLater), findsOneWidget);
    expect(find.text(l10n.updateSkipVersion), findsOneWidget);
    expect(find.text(l10n.updateUpdateNow), findsNothing);
    expect(find.text(l10n.updateInstallKeepsData), findsNothing);
    expect(find.text(l10n.updateNoCompatiblePackage), findsNothing);
  });

  testWidgets('no page in the feed: says so and offers no link', (tester) async {
    await _pump(tester, const UpdateSheet(), _Notice(_release()));
    expect(find.text(l10n.harmonyUpdateNoticeNoPage), findsOneWidget);
    expect(find.text(l10n.updateOpenReleasePage), findsNothing);
    expect(find.text(l10n.commonClose), findsOneWidget);
  });

  testWidgets('a skipped version is not offered for skipping again', (tester) async {
    await _pump(tester, const UpdateSheet(), _Notice(_release(page: page), skipped: '1.2.0+7'));
    expect(find.text(l10n.updateSkipVersion), findsNothing);
    expect(find.text(l10n.updateOpenReleasePage), findsOneWidget);
  });

  testWidgets('the settings rows show when it can check', (tester) async {
    await _pump(tester, const AppUpdateTiles(), _Notice(null));
    expect(find.text(l10n.updateCheck), findsOneWidget);
  });

  testWidgets('and not when it can\'t', (tester) async {
    await _pump(tester, const AppUpdateTiles(), _Notice(null, noticeOnly: false));
    expect(find.text(l10n.updateCheck), findsNothing);
  });
}
