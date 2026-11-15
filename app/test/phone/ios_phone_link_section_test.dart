// 手机操控 → 本机连接 (iOS): what each state offers, what each tap asks the native side for, and
// that a failure is said as it came back while saying no stays quiet.

import 'dart:async';

import 'package:dsh_app/phone/ios_phone_link.dart';
import 'package:dsh_app/state/ios_phone_link_state.dart';
import 'package:dsh_app/ui/phone/ios_phone_link_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

class _Link implements PhoneLinkApi {
  _Link(this.current);

  PhoneLinkStatus current;
  final calls = <String>[];
  final _events = StreamController<PhoneLinkStatus>.broadcast();

  /// What the next step comes back with; OK with [current] by default.
  String nextCode = 'OK';
  PhoneLinkStatus? next;

  void emit(PhoneLinkStatus status) => _events.add(current = status);

  Future<PhoneLinkResult> _step(String name) async {
    calls.add(name);
    final code = nextCode;
    nextCode = 'OK';
    if (next case final status?) current = status;
    next = null;
    return PhoneLinkResult(code == 'OK', code, current);
  }

  @override
  Stream<PhoneLinkStatus> get events => _events.stream;
  @override
  Future<PhoneLinkStatus> status() async => current;
  @override
  Future<PhoneLinkResult> importPairing() => _step('importPairing');
  @override
  Future<PhoneLinkResult> migrateLegacyPairing() => _step('migrateLegacyPairing');
  @override
  Future<PhoneLinkResult> clearPairing() => _step('clearPairing');
  @override
  Future<PhoneLinkResult> setEnabled(bool enabled) => _step('setEnabled:$enabled');
  @override
  Future<PhoneLinkResult> setXCTestEnabled(bool enabled) => _step('setXCTestEnabled:$enabled');
  @override
  Future<PhoneLinkResult> checkConnection() => _step('checkConnection');
  @override
  Future<PhoneLinkResult> mountDDI() => _step('mountDDI');
  @override
  Future<PhoneLinkResult> cancelPreparation() => _step('cancelPreparation');
  @override
  Future<PhoneLinkResult> restoreClipboard({bool overwriteChanged = false}) =>
      _step('restoreClipboard:$overwriteChanged');
  @override
  Future<PhoneLinkResult> discardSavedClipboard() => _step('discardSavedClipboard');
}

PhoneLinkStatus _status({
  bool available = true,
  bool paired = false,
  PhoneLinkStorage storage = PhoneLinkStorage.none,
  bool enabled = false,
  bool legacy = false,
  bool pending = false,
  int downloaded = 0,
  int total = 0,
  bool clipboard = false,
  String? lastCheckCode,
  Map<String, bool> capabilities = const {},
  PhoneLinkPhase phase = PhoneLinkPhase.idle,
}) => PhoneLinkStatus(
  buildAvailable: available,
  pairingPresent: paired,
  storage: storage,
  enabled: enabled,
  legacyPairing: legacy,
  operationPending: pending,
  downloaded: downloaded,
  downloadTotal: total,
  clipboardPending: clipboard,
  lastCheck: lastCheckCode == null ? null : DateTime(2026, 11, 8),
  lastCheckCode: lastCheckCode,
  lastCheckCapabilities: capabilities,
  phase: phase,
);

void main() {
  late _Link link;
  final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

  Future<void> show(WidgetTester tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: Column(children: [PhoneLinkClipboardCard(), PhoneLinkSection(), PhoneLinkExtrasSection()]),
          ),
        ),
        overrides: [phoneLinkApiProvider.overrideWithValue(link)],
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> tapAndSettle(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a limited connection does not promise tapping or typing', (tester) async {
    link = _Link(
      _status(paired: true, enabled: true, lastCheckCode: 'OK', capabilities: {'screenshot': true, 'touch': false}),
    );
    await show(tester);
    expect(find.text('连接正常，可读屏和打开应用；点按、滚动和输入需使用 XCTest 增强'), findsOneWidget);
  }, variant: ios);

  testWidgets('an older iOS says what it needs and offers nothing else', (tester) async {
    link = _Link(_status(available: false));
    await show(tester);
    expect(find.text('需要 iOS 17 或更高版本。'), findsOneWidget);
    expect(find.text('导入配对凭据'), findsNothing);
    expect(find.text('XCTest 增强'), findsNothing);
  }, variant: ios);

  testWidgets('nothing set up: import is the one step to take, the switch waits for a record', (tester) async {
    link = _Link(_status());
    await show(tester);
    expect(find.text('导入配对凭据'), findsOneWidget);
    expect(find.text('用 Mac 或 Windows 电脑生成的远程配对文件（.plist）'), findsOneWidget);
    expect(find.text('先导入配对凭据。'), findsOneWidget);
    expect(tester.widget<Switch>(find.byType(Switch).first).onChanged, isNull);
    expect(find.text('开发者镜像'), findsNothing);
    expect(find.text('清除配对凭据'), findsNothing);

    link.next = _status(paired: true, storage: PhoneLinkStorage.session);
    await tapAndSettle(tester, find.text('导入'));
    expect(link.calls, ['importPairing']);
    expect(find.text('只用这一次，退出 App 后清除'), findsOneWidget);
    expect(find.text('更换'), findsOneWidget);
  }, variant: ios);

  testWidgets('saying no to a native question shows nothing; a real failure says why', (tester) async {
    link = _Link(_status());
    await show(tester);
    link.nextCode = 'ERR_PHONE_CANCELLED';
    await tapAndSettle(tester, find.text('导入'));
    expect(find.text('用 Mac 或 Windows 电脑生成的远程配对文件（.plist）'), findsOneWidget);

    link.nextCode = 'ERR_PHONE_PAIRING_INVALID';
    await tapAndSettle(tester, find.text('导入'));
    expect(find.text('这个文件不是可用的远程配对凭据。'), findsOneWidget);
  }, variant: ios);

  testWidgets('paired: the switch asks the native side, then check and the disk image open up', (tester) async {
    link = _Link(_status(paired: true, storage: PhoneLinkStorage.device));
    await show(tester);
    expect(find.text('已记住在这台手机上'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '检查')).onPressed, isNull);

    link.next = _status(paired: true, storage: PhoneLinkStorage.device, enabled: true);
    await tapAndSettle(tester, find.byType(Switch).first);
    expect(link.calls, ['setEnabled:true']);
    expect(find.text('开发者镜像'), findsOneWidget);

    link.nextCode = 'ERR_PHONE_TUNNEL';
    await tapAndSettle(tester, find.text('检查'));
    expect(link.calls.last, 'checkConnection');
    expect(find.textContaining('LocalDevVPN 已接通'), findsOneWidget);

    await tapAndSettle(tester, find.text('检查'));
    expect(find.text('连接正常'), findsOneWidget);

    await tapAndSettle(tester, find.text('准备'));
    expect(link.calls.last, 'mountDDI');
  }, variant: ios);

  testWidgets('a connection that never confirmed it closed: check waits, and restarting is the way back', (
    tester,
  ) async {
    link = _Link(_status(paired: true, enabled: true, lastCheckCode: 'OK', phase: PhoneLinkPhase.faulted));
    await show(tester);
    expect(find.text('上一次连接没能确认已经关掉'), findsOneWidget);
    expect(find.textContaining('在后台彻底关掉 App'), findsOneWidget);
    expect(find.text('连接正常'), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '检查')).onPressed, isNull);
    expect(tester.widget<Switch>(find.byType(Switch).first).onChanged, isNotNull, reason: 'turning it off still works');
  }, variant: ios);

  testWidgets('a step under way: buttons wait, the download shows, and it can be cancelled', (tester) async {
    link = _Link(_status(paired: true, enabled: true));
    await show(tester);
    link.emit(
      _status(paired: true, enabled: true, pending: true, downloaded: 4 * 1024 * 1024, total: 16 * 1024 * 1024),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('正在下载 4.0 MB / 16.0 MB'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '更换')).onPressed, isNull);
    await tapAndSettle(tester, find.text('取消'));
    expect(link.calls, ['cancelPreparation']);
  }, variant: ios);

  testWidgets('an old plain-text record is offered for moving, never used silently', (tester) async {
    link = _Link(_status(legacy: true));
    await show(tester);
    expect(find.text('发现旧版本留下的配对文件'), findsOneWidget);
    await tapAndSettle(tester, find.text('迁移'));
    expect(link.calls, ['migrateLegacyPairing']);
  }, variant: ios);

  testWidgets('clearing the record asks first', (tester) async {
    link = _Link(_status(paired: true, enabled: true, storage: PhoneLinkStorage.device));
    await show(tester);
    await tester.ensureVisible(find.text('清除配对凭据'));
    await tester.tap(find.text('清除配对凭据'));
    await tester.pumpAndSettle();
    expect(find.text('清除配对凭据？'), findsOneWidget);
    expect(link.calls, isEmpty);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(link.calls, isEmpty);

    await tester.tap(find.text('清除配对凭据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(link.calls, ['clearPairing']);
  }, variant: ios);

  testWidgets('a borrowed clipboard waits on top; restoring over a later copy is a separate choice', (tester) async {
    link = _Link(_status(paired: true, enabled: true, clipboard: true));
    await show(tester);
    expect(find.text('回到 App 恢复原剪贴板'), findsOneWidget);
    expect(find.text('仍要恢复，覆盖现在的剪贴板'), findsNothing);

    link.nextCode = 'ERR_PHONE_CLIPBOARD_CHANGED';
    await tapAndSettle(tester, find.text('恢复'));
    expect(link.calls, ['restoreClipboard:false']);
    expect(find.text('之后又复制过别的内容，所以没有恢复。'), findsOneWidget);

    await tapAndSettle(tester, find.text('仍要恢复，覆盖现在的剪贴板'));
    expect(link.calls.last, 'restoreClipboard:true');

    await tapAndSettle(tester, find.text('丢弃保存的旧剪贴板'));
    expect(link.calls.last, 'discardSavedClipboard');
  }, variant: ios);

  testWidgets('XCTest is its own switch, off unless chosen', (tester) async {
    link = _Link(_status(paired: true, enabled: true));
    await show(tester);
    expect(find.text('XCTest 增强'), findsOneWidget);
    expect(find.text('iOS 自动化服务'), findsNothing);
    link.next = const PhoneLinkStatus(buildAvailable: true, pairingPresent: true, enabled: true, xctestEnabled: true);
    await tester.ensureVisible(find.text('XCTest 增强'));
    await tapAndSettle(tester, find.byType(Switch).last);
    expect(link.calls, ['setXCTestEnabled:true']);
    expect(find.text('iOS 自动化服务'), findsOneWidget);
  }, variant: ios);

  test('the status map reads what the native side sends', () {
    final status = PhoneLinkStatus.fromMap({
      'schema': 1,
      'enabled': true,
      'buildAvailable': true,
      'xctestEnabled': false,
      'pairing': {'present': true, 'storage': 'session', 'code': 'OK'},
      'legacyPairingNeedsMigration': false,
      'connection': {
        'phase': 'ready',
        'stage': 'services',
        'code': 'OK',
        'checks': {'vpnReachable': true, 'pairingVerified': true, 'junk': 'x'},
      },
      'lastCheck': {
        'time': 1794000000,
        'connection': {
          'phase': 'failed',
          'code': 'ERR_PHONE_TUNNEL',
          'checks': {'vpnReachable': false},
          'capabilities': {'screenshot': true, 'touch': false, 'junk': 'x'},
        },
      },
      'ddiCache': {'catalogId': 'x', 'downloading': false, 'verifiedThisProcess': true},
      'operationPending': false,
      'progress': {'stage': 'downloading', 'completedBytes': 10, 'totalBytes': 20},
      'clipboard': {'pendingRestore': true, 'pasteMayHaveBeenDispatched': true},
    });
    expect(status.storage, PhoneLinkStorage.session);
    expect(status.phase, PhoneLinkPhase.ready);
    expect(status.checks, {'vpnReachable': true, 'pairingVerified': true});
    expect(status.lastCheckPhase, PhoneLinkPhase.failed);
    expect(status.lastCheckCode, 'ERR_PHONE_TUNNEL');
    expect(status.lastCheckChecks, {'vpnReachable': false});
    expect(status.lastCheckCapabilities, {'screenshot': true, 'touch': false});
    expect(status.lastCheck, DateTime.fromMillisecondsSinceEpoch(1794000000 * 1000));
    expect(status.ddiVerified, isTrue);
    expect(status.downloading, isTrue);
    expect(status.clipboardPending, isTrue);
    expect(status.pasteMayHaveHappened, isTrue);
    expect(PhoneLinkStatus.fromMap(const {}).storage, PhoneLinkStorage.unknown);
  });
}
