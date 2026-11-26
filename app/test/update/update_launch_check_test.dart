import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/state/star_prompt.dart';
import 'package:dsh_app/state/update_state.dart';
import 'package:dsh_app/ui/update/update_launch_check.dart';
import 'package:dsh_app/ui/update/update_sheet.dart';
import 'package:dsh_app/update/privileged_installer.dart';
import 'package:dsh_app/update/update_config.dart';
import 'package:dsh_app/update/update_http.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

const _manifest = 'https://updates.example/update.json';
const _launchDelay = Duration(seconds: 2);

class _NoPendingInstall extends ChannelPrivilegedInstaller {
  const _NoPendingInstall();

  @override
  Future<SelfUpdatePending> reconcile() async => const SelfUpdatePending();
}

// Lifecycle tests control when metadata arrives, not streamed HTTP timing.
class _ReleaseResponse extends UpdateHttpResponse {
  _ReleaseResponse(this.version) : super(status: 200, body: const Stream.empty());

  final String version;

  @override
  Future<String> text({int maxBytes = 2 * 1024 * 1024, Duration timeout = const Duration(seconds: 20)}) async =>
      _release(version);
}

String _release(String version) => jsonEncode({
  'schema': 1,
  'version': version,
  'assets': {
    'arm64': {'size': 10, 'sha256': 'a' * 64},
  },
});

Future<ProviderContainer> _mount(WidgetTester tester, FakeHttp http, DateTime Function() clock) async {
  // Keep a known offer in preferences so startup doesn't need filesystem I/O.
  SharedPreferences.setMockInitialValues({'update_latest': _release('1.2.0')});
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() {
    if (tester.binding.lifecycleState == AppLifecycleState.paused) _foreground(tester);
  });
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: const Scaffold(body: UpdateLaunchCheck(delay: _launchDelay)),
      brightness: Brightness.light,
      overrides: [
        updateHttpProvider.overrideWithValue(http),
        updateInstallerProvider.overrideWithValue(FakeInstaller()),
        privilegedInstallerProvider.overrideWithValue(const _NoPendingInstall()),
        updateFlavorNameProvider.overrideWithValue('arm64'),
        updateSourcesProvider.overrideWithValue(
          UpdateSources(feed: Uri.parse(_manifest), useGithubApi: false, mirrors: const []),
        ),
        updateClockProvider.overrideWithValue(clock),
        starPromptGateProvider.overrideWithValue(false),
      ],
    ),
  );
  final container = ProviderScope.containerOf(tester.element(find.byType(UpdateLaunchCheck)), listen: false);
  final controller = container.read(appUpdateProvider.notifier);
  await tester.pump();
  expect(container.read(appUpdateProvider).loaded, isTrue);
  await controller.ready;
  return container;
}

void _lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
  states.forEach(tester.binding.handleAppLifecycleStateChanged);
}

void _background(WidgetTester tester) =>
    _lifecycle(tester, const [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);

void _foreground(WidgetTester tester) =>
    _lifecycle(tester, const [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);

void main() {
  testWidgets('Later leaves the offer intact; resume checks again only after 24 hours', (tester) async {
    var now = DateTime.utc(2026, 11, 26);
    var version = '1.2.0';
    final http = FakeHttp({_manifest: (_, _) => _ReleaseResponse(version)});
    final container = await _mount(tester, http, () => now);
    final sheet = find.byType(UpdateSheet, skipOffstage: false);

    _background(tester);
    _foreground(tester);
    await tester.pump();
    expect(http.urls, isEmpty, reason: 'a quick resume must not bypass the launch delay');
    await tester.pump(_launchDelay);
    await tester.pumpAndSettle();
    expect(http.urls, [_manifest]);
    expect(container.read(appUpdateProvider).checkFailure, isNull);
    expect(container.read(appUpdateProvider).check, UpdateCheckPhase.available);
    expect(sheet, findsOneWidget);
    expect(find.text('DSH 1.2.0'), findsOneWidget);

    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(sheet, findsNothing);
    expect(container.read(appUpdateProvider).hasUpdate, isTrue);
    expect(container.read(appUpdateProvider).isSkipped, isFalse);

    now = now.add(const Duration(hours: 23, minutes: 59));
    _background(tester);
    _foreground(tester);
    await tester.pumpAndSettle();
    expect(http.urls, [_manifest]);
    expect(sheet, findsNothing);

    _background(tester);
    now = now.add(const Duration(minutes: 1));
    version = '1.3.0';
    await tester.pump();
    expect(http.urls, [_manifest]);
    _foreground(tester);
    await tester.pumpAndSettle();
    expect(http.urls, [_manifest, _manifest]);
    expect(sheet, findsOneWidget);
    expect(find.text('DSH 1.3.0'), findsOneWidget);
  });

  testWidgets('a check finishing in the background keeps the offer without opening a sheet', (tester) async {
    final answer = Completer<UpdateHttpResponse>();
    final http = FakeHttp({_manifest: (_, _) => answer.future});
    final container = await _mount(tester, http, () => DateTime.utc(2026, 11, 26));
    final sheet = find.byType(UpdateSheet, skipOffstage: false);

    _background(tester);
    await tester.pump(_launchDelay);
    expect(http.urls, isEmpty, reason: 'the startup timer must not start a background check');
    _foreground(tester);
    await tester.pump();
    expect(http.urls, [_manifest]);

    _background(tester);
    answer.complete(_ReleaseResponse('1.3.0'));
    await tester.pump();
    expect(container.read(appUpdateProvider).checkFailure, isNull);
    expect(container.read(appUpdateProvider).check, UpdateCheckPhase.available);
    expect(container.read(appUpdateProvider).latest?.version.name, '1.3.0');
    expect(container.read(launchNoticeShownProvider), isFalse);

    _foreground(tester);
    await tester.pumpAndSettle();
    expect(http.urls, [_manifest]);
    expect(sheet, findsNothing);
  });
}
