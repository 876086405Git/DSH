// Goldens for in-app updates: the 关于 rows with the new-version mark, and the
// update sheet in its main states (offer, downloading, signature mismatch).
// Plus widget checks of the sheet's buttons, the manual check entry and the
// launch check. The goldens use a page holding only the 关于 group, so other
// settings rows changing doesn't move them.

import 'dart:convert';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/star_prompt.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/settings/about_page.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:dsh_app/ui/shell/page_frame.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/update/update_launch_check.dart';
import 'package:dsh_app/ui/update/update_tiles.dart';
import 'package:dsh_app/update/release.dart';
import 'package:dsh_app/update/version.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

/// Fixed state; records what the sheet asked for.
class FakeUpdate extends AppUpdateController {
  FakeUpdate(this.initial, {UpdateCheckPhase? checkResult, this.checkedRelease})
    : checkResult = checkResult ?? (initial.hasUpdate ? UpdateCheckPhase.available : UpdateCheckPhase.upToDate);

  final AppUpdateState initial;
  final UpdateCheckPhase checkResult;
  final ReleaseInfo? checkedRelease;
  final calls = <String>[];

  @override
  AppUpdateState build() => initial;

  @override
  Future<void> get ready async {}

  @override
  Future<UpdateCheckPhase> check() async {
    calls.add('check');
    state = state.copyWith(check: checkResult, latest: checkedRelease == null ? null : () => checkedRelease);
    return checkResult;
  }

  @override
  Future<void> startDownload() async {
    calls.add('startDownload');
    state = state.copyWith(task: UpdateTaskPhase.downloading, received: 0, total: () => state.asset?.size);
  }

  @override
  void cancelDownload() {
    calls.add('cancelDownload');
    state = state.copyWith(task: UpdateTaskPhase.idle);
  }

  @override
  Future<void> skipLatest() async {
    calls.add('skipLatest');
    state = state.copyWith(skippedVersion: () => state.latest?.version.toString());
  }

  /// What [autoCheckIfDue] answers.
  bool offer = false;

  @override
  Future<bool> autoCheckIfDue() async {
    calls.add('autoCheckIfDue');
    return offer;
  }

  @override
  Future<void> onAppResumed({Duration confirmGrace = Duration.zero}) async => calls.add('resumed');

  /// What [installWithSystem] answers.
  bool systemInstallerOpens = true;

  @override
  Future<bool> installWithSystem() async {
    calls.add('installWithSystem');
    return systemInstallerOpens;
  }

  /// What [exportApk] answers; null = the copy failed. Counts the calls.
  String? exportResult = 'Download/DSH-Go/dsh-go-1.2.0-arm64.apk';
  int exports = 0;

  @override
  Future<String?> exportApk() async {
    exports++;
    return exportResult;
  }

  @override
  Future<void> setAutoCheck(bool value) async {
    calls.add('autoCheck:$value');
    state = state.copyWith(autoCheck: value);
  }
}

final _release = parseGithubRelease(jsonDecode(fixture('github_release.json')));

AppUpdateState _offer({
  UpdateTaskPhase task = UpdateTaskPhase.idle,
  int received = 0,
  String? source,
  UpdateProblem? problem,
  bool apkHere = false,
}) => AppUpdateState(
  loaded: true,
  current: AppVersion.tryParse('1.0.0+1')!,
  flavor: ApkFlavor.arm64,
  check: UpdateCheckPhase.available,
  latest: _release,
  task: task,
  received: received,
  total: _release.apkFor(ApkFlavor.arm64)!.size,
  source: source,
  problem: problem,
  apkHere: apkHere,
);

List<Override> _overrides(FakeUpdate update) => [
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
  appUpdateProvider.overrideWith(() => update),
];

/// The 关于 group as 设置 lays it out.
class _AboutPage extends StatelessWidget {
  const _AboutPage();

  @override
  Widget build(BuildContext context) => AppPage.list(
    title: '设置',
    children: [
      SettingsSection(
        title: '关于',
        children: [
          const SettingsTile(icon: AppIcons.info, tint: 7, title: '版本', value: Text('1.0.0 (1)')),
          const AppUpdateTiles(tint: 7),
          SettingsTile(icon: AppIcons.document, tint: 7, title: '开源许可', onTap: () {}),
        ],
      ),
    ],
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('检查更新'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  // 设置 → 关于 with a new version waiting.
  goldenBoth('settings_about_update', () => const _AboutPage(), overrides: () => _overrides(FakeUpdate(_offer())));

  goldenBoth(
    'update_sheet',
    () => const _AboutPage(),
    overrides: () => _overrides(FakeUpdate(_offer())),
    before: (tester) async {
      await _openSheet(tester);
    },
  );

  // Public builds: 稍后 / 去 Star / 立即更新.
  goldenBoth(
    'update_sheet_star',
    () => const _AboutPage(),
    overrides: () => [
      ..._overrides(FakeUpdate(_offer())),
      starPromptGateProvider.overrideWithValue(true),
      starPromptStoreProvider.overrideWithValue(_StarStore()),
    ],
    before: (tester) async {
      await _openSheet(tester);
    },
  );

  goldenBoth(
    'update_sheet_downloading',
    () => const _AboutPage(),
    overrides: () => _overrides(
      FakeUpdate(_offer(task: UpdateTaskPhase.downloading, received: 81 * 1024 * 1024 + 300000, source: 'ghfast.top')),
    ),
    before: (tester) async {
      await _openSheet(tester);
    },
  );

  goldenBoth(
    'update_sheet_signature',
    () => const _AboutPage(),
    overrides: () => _overrides(FakeUpdate(_offer(task: UpdateTaskPhase.failed, problem: UpdateProblem.signature))),
    before: (tester) async {
      await _openSheet(tester);
    },
  );

  group('behaviour', () {
    Future<FakeUpdate> pump(WidgetTester tester, FakeUpdate update) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(home: const _AboutPage(), brightness: Brightness.light, overrides: _overrides(update)),
      );
      await tester.pump();
      return update;
    }

    testWidgets('the mark shows the version; a skipped one is quiet', (tester) async {
      await pump(tester, FakeUpdate(_offer()));
      expect(find.widgetWithText(UpdateBadge, '新版本 1.2.0'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, FakeUpdate(_offer().copyWith(skippedVersion: () => '1.2.0')));
      expect(find.byType(UpdateBadge), findsNothing);
      expect(find.text('已跳过 1.2.0'), findsOneWidget);
    });

    testWidgets('立即更新 starts the download; 取消下载 stops it', (tester) async {
      final update = await pump(tester, FakeUpdate(_offer()));
      await _openSheet(tester);
      expect(find.text('发现新版本'), findsOneWidget);
      expect(find.text('DSH 1.2.0'), findsOneWidget);
      expect(find.textContaining('171.8 MB'), findsOneWidget);
      expect(find.byKey(const ValueKey('update-star')), findsNothing);
      await tester.tap(find.text('立即更新'));
      await tester.pump();
      expect(update.calls, ['check', 'startDownload']);
      expect(find.text('正在下载 0%'), findsOneWidget);
      await tester.tap(find.text('取消下载'));
      await tester.pump();
      expect(update.calls, ['check', 'startDownload', 'cancelDownload']);
      expect(find.text('立即更新'), findsOneWidget);
    });

    testWidgets('public builds ask for a star too: 去 Star opens the project, then the button goes', (tester) async {
      final opened = <Uri>[];
      final update = FakeUpdate(_offer());
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const _AboutPage(),
          brightness: Brightness.light,
          overrides: [
            ..._overrides(update),
            starPromptGateProvider.overrideWithValue(true),
            starPromptStoreProvider.overrideWithValue(_StarStore()),
            starLinkOpenerProvider.overrideWithValue((uri) async {
              opened.add(uri);
              return true;
            }),
          ],
        ),
      );
      await tester.pump();
      await _openSheet(tester);
      expect(find.text('去 Star'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('update-star')));
      await tester.pump();
      expect(opened, [starProjectPage]);
      expect(find.byKey(const ValueKey('update-star')), findsNothing);
      await tester.tap(find.text('立即更新'));
      await tester.pump();
      expect(update.calls, ['check', 'startDownload']);
    });

    testWidgets('跳过这个版本 records the skip and closes the sheet', (tester) async {
      final update = await pump(tester, FakeUpdate(_offer()));
      await _openSheet(tester);
      await tester.tap(find.text('跳过这个版本'));
      await tester.pumpAndSettle();
      expect(update.calls, ['check', 'skipLatest']);
      expect(find.text('发现新版本'), findsNothing);
      expect(find.text('已跳过 1.2.0'), findsOneWidget);
    });

    testWidgets('an unconfirmed install keeps neutral wording and the system installer', (tester) async {
      final update = await pump(
        tester,
        FakeUpdate(_offer(task: UpdateTaskPhase.ready, problem: UpdateProblem.installUnconfirmed)),
      );
      await _openSheet(tester);
      expect(find.text('尚未确认安装结果'), findsOneWidget);
      expect(find.text('已取消安装'), findsNothing);
      await tester.tap(find.text('用系统安装器安装'));
      await tester.pump();
      expect(update.calls, ['check', 'installWithSystem']);
    });

    testWidgets('a stopped or failed install offers the system installer', (tester) async {
      final update = await pump(
        tester,
        FakeUpdate(_offer(task: UpdateTaskPhase.ready, problem: UpdateProblem.installCancelled)),
      );
      await _openSheet(tester);
      expect(find.text('已取消安装'), findsOneWidget);
      await tester.tap(find.text('用系统安装器安装'));
      await tester.pump();
      expect(update.calls, ['check', 'installWithSystem']);
      update.systemInstallerOpens = false;
      await tester.tap(find.text('用系统安装器安装'));
      await tester.pump();
      expect(find.text('没能打开系统安装器'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, FakeUpdate(_offer(task: UpdateTaskPhase.failed, problem: UpdateProblem.installFailed)));
      await _openSheet(tester);
      expect(find.text('用系统安装器安装'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, FakeUpdate(_offer(task: UpdateTaskPhase.ready)));
      await _openSheet(tester);
      expect(find.text('用系统安装器安装'), findsNothing);
    });

    testWidgets('signature mismatch offers the release page, not a retry', (tester) async {
      await pump(tester, FakeUpdate(_offer(task: UpdateTaskPhase.failed, problem: UpdateProblem.signature)));
      await _openSheet(tester);
      expect(find.text('签名不一致，不能直接覆盖'), findsOneWidget);
      expect(find.text('打开发布页'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
    });

    testWidgets('the downloaded package can be saved to sign by hand', (tester) async {
      final update = await pump(
        tester,
        FakeUpdate(_offer(task: UpdateTaskPhase.failed, problem: UpdateProblem.signature, apkHere: true)),
      );
      await _openSheet(tester);
      await tester.tap(find.text('导出安装包'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('导出安装包')));
      await tester.pumpAndSettle();
      expect(update.exports, 1);
      expect(find.text('已存到 下载/DSH-Go/dsh-go-1.2.0-arm64.apk'), findsOneWidget);
    });

    testWidgets('nothing was downloaded, so nothing is offered for signing', (tester) async {
      await pump(tester, FakeUpdate(_offer(task: UpdateTaskPhase.failed, problem: UpdateProblem.signature)));
      await _openSheet(tester);
      expect(find.text('签名不一致，不能直接覆盖'), findsOneWidget);
      expect(find.text('导出安装包'), findsNothing);
    });

    testWidgets('manual check replaces a cached offer with the newly checked release', (tester) async {
      final newer = parseGithubRelease(jsonDecode(fixture('github_release.json').replaceAll('1.2.0', '1.4.0')));
      final update = await pump(tester, FakeUpdate(_offer(), checkedRelease: newer));
      await _openSheet(tester);
      expect(update.calls, ['check']);
      expect(find.text('DSH 1.4.0'), findsOneWidget);
      expect(find.text('DSH 1.2.0'), findsNothing);
    });

    testWidgets('manual check: up to date / unavailable say so in a snack bar, no dialog', (tester) async {
      final idle = AppUpdateState(loaded: true, current: AppVersion.tryParse('1.2.0+7')!, flavor: ApkFlavor.arm64);
      final update = await pump(tester, FakeUpdate(idle));
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      expect(update.calls, ['check']);
      expect(find.text('已是最新版本'), findsOneWidget);
      expect(find.text('已是最新'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await pump(tester, FakeUpdate(idle, checkResult: UpdateCheckPhase.unavailable));
      await tester.tap(find.text('检查更新'));
      await tester.pump();
      expect(find.text('暂时检查不了更新，稍后再试'), findsOneWidget);
      expect(find.text('暂时检查不了'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('the automatic check switch', (tester) async {
      final update = await pump(tester, FakeUpdate(_offer()));
      await tester.tap(find.text('自动检查更新'));
      await tester.pump();
      expect(update.calls, ['autoCheck:false']);
    });
  });

  testWidgets('设置 marks 关于 DSH Go; the rows are on that page', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const SettingsScreen(),
        brightness: Brightness.light,
        overrides: _overrides(FakeUpdate(_offer())),
      ),
    );
    await tester.pump();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -5000));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.widgetWithText(UpdateBadge, '有新版本'), findsOneWidget);
    await tester.ensureVisible(find.text('关于 DSH Go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于 DSH Go'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutPage), findsOneWidget);
    expect(find.byType(AppUpdateTiles), findsOneWidget);
    expect(find.widgetWithText(UpdateBadge, '新版本 1.2.0'), findsOneWidget);
  });

  group('launch check', () {
    Future<FakeUpdate> mount(WidgetTester tester, {bool keyboard = false}) async {
      final update = FakeUpdate(_offer())..offer = true;
      usePhoneSurface(tester);
      if (keyboard) tester.view.viewInsets = const FakeViewPadding(bottom: 300 * 2);
      await tester.pumpWidget(
        goldenApp(
          home: const Scaffold(body: UpdateLaunchCheck(delay: Duration(seconds: 2))),
          brightness: Brightness.light,
          overrides: _overrides(update),
        ),
      );
      return update;
    }

    testWidgets('offers the sheet once the delay has passed', (tester) async {
      final update = await mount(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(update.calls, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 600));
      expect(update.calls, ['autoCheckIfDue']);
      expect(find.text('发现新版本'), findsOneWidget);
    });

    testWidgets('does not interrupt typing', (tester) async {
      final update = await mount(tester, keyboard: true);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 600));
      expect(update.calls, ['autoCheckIfDue']);
      expect(find.text('发现新版本'), findsNothing);
    });

    testWidgets('coming back to the app tells the controller', (tester) async {
      final update = await mount(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(update.calls, contains('resumed'));
    });
  });
}

class _StarStore implements StarPromptStore {
  StarPromptRecord? record;

  @override
  Future<StarPromptRecord?> read() async => record;

  @override
  Future<void> write(StarPromptRecord r) async => record = r;
}
