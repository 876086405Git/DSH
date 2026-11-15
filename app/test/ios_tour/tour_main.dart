// A tour of the main screens, for looking at them on the iOS Simulator: real fonts, real blur, real
// safe areas, the fluid tier on. tooling/ios/ui-tour.mjs takes a screenshot at each stop and records
// the whole run. Not a test: `flutter build ios --simulator --debug -t test/ios_tour/tour_main.dart`.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/common/app_dialog.dart';
import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/side_insets.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:dsh_app/ui/onboarding/welcome_page.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:dsh_app/ui/settings/settings_screen.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/theme/app_theme.dart';
import 'package:dsh_app/ui/theme/motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../chat/support/harness.dart' show ChatHarness;
import '../chat/support/sample_chat.dart' show conversationState;
import '../shell/golden_harness.dart';

const _settle = Duration(milliseconds: 1400);

/// Everything goes through this file, which the driver reads from the app's container.
final _log = File('${Directory.systemTemp.path}/dsh-ui-tour.log');
var _shots = 0;

void _say(String line) => _log.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);

/// The second pass, for the video: real time, no stops for screenshots.
final _recording = File('${Directory.systemTemp.path}/dsh-ui-tour-mode').readAsStringSync().trim() == 'video';

/// Asks the driver for a screenshot and waits until it has it. One can take a good while on a CI
/// machine, and going on without it would put the next screen under this name.
Future<void> _shot(String name) async {
  if (_recording) return;
  final number = ++_shots;
  _say('SHOT $number $name');
  final done = File('${Directory.systemTemp.path}/dsh-ui-tour-ack-$number');
  for (var i = 0; i < 3600 && !done.existsSync(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

typedef _Act = Future<void> Function(BuildContext context, String suffix);

class _Stop {
  const _Stop(this.name, this.home, {this.overrides = _shell, this.act});

  final String name;
  final Widget Function() home;
  final List<Override> Function() overrides;
  final _Act? act;
}

List<Override> _shell() => [
  localConnectionProvider.overrideWith(FakeConnection.new),
  onboardingPrefsProvider.overrideWith(FakeOnboardingPrefs.new),
  accountWalletBalanceProvider.overrideWithValue(null),
  drawerClockProvider.overrideWithValue(() => sampleNow),
  localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus))),
  localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => sampleLogs),
  settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true, apiKey: 'sk-tour'))),
  sessionsProvider.overrideWith(() => FakeSessions(sampleSessions())),
  currentSessionProvider.overrideWith(() => FakeCurrentSession('s2')),
];

List<Override> _emptyChat() => [accountWalletBalanceProvider.overrideWithValue(null), ...ChatHarness().overrides];

List<Override> _conversation() => [
  accountWalletBalanceProvider.overrideWithValue(null),
  ...ChatHarness(session: 's1', states: {'s1': conversationState()}).overrides,
];

Future<void> _sheet(BuildContext context, String suffix) async {
  await _slowly(() {
    unawaited(
      showAppSheet<void>(
        context,
        builder: (context) => SheetGroup(
          title: '添加到对话',
          children: [
            for (final (icon, label) in const [
              (Icons.photo_outlined, '照片'),
              (Icons.camera_alt_outlined, '拍照'),
              (Icons.description_outlined, '文件'),
            ])
              ListTile(leading: Icon(icon), title: Text(label), onTap: () {}),
          ],
        ),
      ),
    );
  }, 'sheet_rising$suffix');
  await Future<void>.delayed(_settle);
  await _shot('sheet$suffix');
}

Future<void> _push(BuildContext context, String suffix) async {
  await _slowly(() {
    unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const EngineScreen())));
  }, 'push_moving$suffix');
  await Future<void>.delayed(_settle);
  await _shot('push$suffix');
  unawaited(Navigator.of(context).maybePop());
  await Future<void>.delayed(_settle);
}

/// Takes a screenshot of a transition partway through, with time slowed enough to catch it.
Future<void> _slowly(VoidCallback start, String name) async {
  if (_recording) {
    start();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return;
  }
  timeDilation = 10;
  start();
  await Future<void>.delayed(const Duration(milliseconds: 1200));
  await _shot(name);
  timeDilation = 1;
}

Future<void> _dialog(BuildContext context, String suffix) async {
  unawaited(
    showAppDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除这个对话?'),
        content: const Text('删除后不能恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(dialog), child: const Text('删除')),
        ],
      ),
    ),
  );
  await Future<void>.delayed(_settle);
  await _shot('dialog$suffix');
}

final _stops = <_Stop>[
  _Stop('welcome', () => WelcomePage(onStart: () {})),
  _Stop('chat_empty', () => const ChatScreen(), overrides: _emptyChat),
  _Stop('conversation', () => const ChatScreen(), overrides: _conversation),
  _Stop('sheet', () => const ChatScreen(), overrides: _conversation, act: _sheet),
  _Stop('dialog', () => const ChatScreen(), overrides: _conversation, act: _dialog),
  _Stop('drawer', () => HomeShell(chatBuilder: (_) => const _Backdrop(), initiallyOpen: true)),
  _Stop('settings', () => const SettingsScreen()),
  _Stop('push', () => const SettingsScreen(), act: _push),
  _Stop('remote', () => const RemoteScreen()),
];

/// Behind the drawer, so its glass has something to blur.
class _Backdrop extends StatelessWidget {
  const _Backdrop();

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 72, 16, 0),
      children: [
        for (var i = 0; i < 16; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            height: 14,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(7),
            ),
          ),
      ],
    ),
  );
}

class _Tour extends StatefulWidget {
  const _Tour();

  @override
  State<_Tour> createState() => _TourState();
}

class _TourState extends State<_Tour> {
  var _at = 0;
  var _brightness = Brightness.light;
  var _navigator = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    for (final brightness in _recording ? const [Brightness.light] : Brightness.values.reversed) {
      for (var i = 0; i < _stops.length; i++) {
        setState(() {
          _at = i;
          _brightness = brightness;
          _navigator = GlobalKey<NavigatorState>();
        });
        await Future<void>.delayed(_settle);
        final stop = _stops[i];
        final suffix = brightness == Brightness.dark ? '_dark' : '_light';
        try {
          final act = stop.act;
          if (act == null) {
            await _shot('${stop.name}$suffix');
          } else {
            await act(_navigator.currentContext!, suffix);
          }
        } on Object catch (error) {
          _say('ERROR ${stop.name}$suffix: $error');
        }
      }
    }
    _say('DONE');
  }

  @override
  Widget build(BuildContext context) {
    final stop = _stops[_at];
    return ProviderScope(
      key: ValueKey((_at, _brightness)),
      overrides: stop.overrides(),
      child: MaterialApp(
        navigatorKey: _navigator,
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(fluid: true),
        darkTheme: buildDarkTheme(fluid: true),
        themeMode: _brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        locale: const Locale('zh', 'CN'),
        supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => AppMotionScope(fluid: true, child: MirroredSideInsets(child: child!)),
        home: stop.home(),
      ),
    );
  }
}

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    if (_log.existsSync()) _log.deleteSync();
    FlutterError.onError = (details) => _say('ERROR ${details.exceptionAsString().split('\n').first}');
    runApp(const _Tour());
  }, (error, stack) => _say('ERROR $error'));
}
