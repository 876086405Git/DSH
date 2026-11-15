// 本机引擎 → Linux 环境 (iOS): what the section offers in each state, and what it asks the
// installer to do.

import 'dart:async';

import 'package:dsh_app/runtime/ios_guest.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/ios_guest_state.dart';
import 'package:dsh_app/ui/engine/linux_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../safe_mode/support.dart';
import '../shell/golden_harness.dart';

IosGuestStatus _status(
  String phase, {
  bool available = true,
  bool installed = false,
  bool busy = false,
  bool suspended = false,
}) => IosGuestStatus(
  phase: phase,
  available: available,
  installed: installed,
  usable: installed && available && !busy && !suspended,
  busy: busy,
  suspended: suspended,
  suspendedReason: suspended ? 'crashed' : null,
  version: installed ? '3.24.4' : null,
);

class _Installer implements GuestInstaller {
  _Installer(this.current);

  IosGuestStatus current;
  final calls = <String>[];
  final _events = StreamController<Map<Object?, Object?>>.broadcast();
  Completer<IosGuestStatus>? installing;
  PlatformException? failure;

  void emit(Map<Object?, Object?> event) => _events.add(event);

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;
  @override
  Future<IosGuestStatus> status() async => current;
  @override
  Future<IosGuestStatus> install() async {
    calls.add('install');
    if (failure case final error?) throw error;
    installing = Completer();
    return installing!.future;
  }

  @override
  Future<IosGuestStatus> uninstall() async {
    calls.add('uninstall');
    return current = _status('notInstalled');
  }

  @override
  Future<IosGuestStatus> resume() async {
    calls.add('resume');
    if (failure case final error?) throw error;
    return current = _status('installed', installed: true);
  }

  @override
  Future<bool> cancel() async {
    calls.add('cancel');
    return true;
  }

  @override
  Future<Map<String, int>> usage() async => {'totalBytes': 9 * 1024 * 1024};
}

void main() {
  late _Installer installer;
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  Future<void> show(WidgetTester tester, {RuntimePhase engine = RuntimePhase.installed}) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: const Scaffold(body: SingleChildScrollView(child: LinuxSection())),
        overrides: [
          guestInstallerProvider.overrideWithValue(installer),
          localRuntimeProvider.overrideWith(
            () => RecordingRuntime(LocalRuntimeState(loaded: true, status: RuntimeStatus(phase: engine))),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('an app built without Linux offers nothing', (tester) async {
    installer = _Installer(_status('notInstalled', available: false));
    await show(tester);
    expect(find.text('Linux 环境'), findsNothing);
  }, variant: ios);

  testWidgets('not installed: one tap starts it, the steps show, and it can be stopped', (tester) async {
    installer = _Installer(_status('notInstalled'));
    await show(tester);
    expect(find.text('Linux 环境'), findsOneWidget);
    await tester.tap(find.text('安装 Linux 环境'));
    await tester.pump();
    expect(installer.calls, ['install']);

    installer.emit({
      'type': 'status',
      'status': {'phase': 'downloading', 'available': true, 'busy': true},
    });
    installer.emit({'type': 'progress', 'step': 'download', 'done': 1, 'total': 2});
    await tester.pump();
    await tester.pump();
    expect(find.text('正在下载 · 50%'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(installer.calls, ['install', 'cancel']);

    // Past the point of no return there's nothing to cancel.
    installer.emit({'type': 'progress', 'step': 'publish', 'done': 0, 'total': 1});
    await tester.pump();
    await tester.pump();
    expect(find.text('即将完成 · 0%'), findsOneWidget);
    expect(find.text('取消'), findsNothing);
  }, variant: ios);

  testWidgets('installed: what it is, its size, and a confirmed uninstall', (tester) async {
    installer = _Installer(_status('installed', installed: true));
    await show(tester);
    expect(find.text('Alpine 3.24.4'), findsOneWidget);
    expect(find.text('9.0 MB'), findsOneWidget);
    await tester.tap(find.text('卸载 Linux 环境'));
    await tester.pumpAndSettle();
    expect(installer.calls, isEmpty);
    await tester.tap(find.text('卸载').last);
    await tester.pumpAndSettle();
    expect(installer.calls, ['uninstall']);
    expect(find.text('安装 Linux 环境'), findsOneWidget);
  }, variant: ios);

  testWidgets('installed while the engine runs: it says the engine has to restart', (tester) async {
    installer = _Installer(_status('notInstalled'));
    await show(tester, engine: RuntimePhase.running);
    await tester.tap(find.text('安装 Linux 环境'));
    await tester.pump();
    installer.installing!.complete(installer.current = _status('installed', installed: true));
    await tester.pump();
    await tester.pump();
    expect(find.text('已装好。重启本机引擎后，命令才会用上它。'), findsOneWidget);
  }, variant: ios);

  testWidgets('a failed download says why; a cancelled one says nothing', (tester) async {
    installer = _Installer(_status('notInstalled'))..failure = PlatformException(code: 'ios_guest_network');
    await show(tester);
    await tester.tap(find.text('安装 Linux 环境'));
    await tester.pump();
    await tester.pump();
    expect(find.text('下载没成功。检查网络后再试一次。'), findsOneWidget);

    installer.failure = PlatformException(code: 'ios_guest_cancelled');
    await tester.tap(find.text('安装 Linux 环境'));
    await tester.pump();
    await tester.pump();
    expect(find.text('下载没成功。检查网络后再试一次。'), findsNothing);
  }, variant: ios);

  testWidgets('paused after a run that did not finish: it says why, and one tap turns it back on', (tester) async {
    installer = _Installer(_status('installed', installed: true, suspended: true));
    await show(tester, engine: RuntimePhase.running);
    expect(find.text('已暂停'), findsOneWidget);
    expect(find.textContaining('Linux 环境先暂停'), findsOneWidget);
    await tester.tap(find.text('重新启用 Linux 环境'));
    await tester.pump();
    await tester.pump();
    expect(installer.calls, ['resume']);
    expect(find.text('已暂停'), findsNothing);
    expect(find.text('重新启用 Linux 环境'), findsNothing);
    expect(find.text('已重新启用。重启本机引擎后，命令才会用上它。'), findsOneWidget);
  }, variant: ios);

  testWidgets('turning it back on while Linux is still busy says to wait', (tester) async {
    installer = _Installer(_status('installed', installed: true, suspended: true))
      ..failure = PlatformException(code: 'ios_guest_busy');
    await show(tester);
    await tester.tap(find.text('重新启用 Linux 环境'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Linux 环境还在使用。等命令停下再试，不行就重新打开 App。'), findsOneWidget);
    expect(find.text('重新启用 Linux 环境'), findsOneWidget);
  }, variant: ios);
}
