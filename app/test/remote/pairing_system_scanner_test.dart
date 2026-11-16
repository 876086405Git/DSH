// 扫码配对电脑 on HarmonyOS: the box opens the system scan page through
// dsh/app.scanQrCode instead of a camera (the native side is
// tooling/ohos/tests/scan-channel.test.mjs). Android keeps its camera.

import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/remote/pairing_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../chat/support/harness.dart';

const _code = 'https://dsh.r2049.cn/pair#v1.AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8';

/// A camera that never opens: the Android box must not reach a real one.
class _NoCamera extends MobileScannerPlatform {
  @override
  Stream<BarcodeCapture?> get barcodesStream => const Stream.empty();
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) => Completer<MobileScannerViewAttributes>().future;
  @override
  Widget buildCameraView() => const SizedBox();
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const appChannel = MethodChannel('dsh/app');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<String> reported;
  late List<String> calls;
  late Future<Object?> Function() answer;

  Widget app(String os) => testApp(
    Scaffold(body: Consumer(builder: (context, ref, _) => ref.watch(pairingScannerProvider)(context, reported.add))),
    overrides: [operatingSystemProvider.overrideWithValue(os)],
  );

  setUp(() {
    reported = [];
    calls = [];
    answer = () async => _code;
    messenger.setMockMethodCallHandler(appChannel, (call) {
      calls.add(call.method);
      return answer();
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(appChannel, null));

  Future<void> leave(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(tester.takeException(), isNull);
  }

  testWidgets('HarmonyOS: the box opens the system scan page and reports its text', (tester) async {
    await tester.pumpWidget(app('ohos'));
    expect(find.byType(MobileScanner), findsNothing);
    expect(find.text('从相册识别'), findsNothing, reason: 'the system scan page has its own album entry');
    expect(find.text('打开系统扫码，里面也能从相册选截图'), findsOneWidget);
    expect(calls, isEmpty, reason: 'nothing opens before the tap');

    await tester.tap(find.text('扫码'));
    await tester.pumpAndSettle();
    expect(calls, ['scanQrCode']);
    expect(reported, [_code]);
    await leave(tester);
  });

  testWidgets('HarmonyOS: closing the scan page does nothing', (tester) async {
    answer = () async => null;
    await tester.pumpWidget(app('ohos'));
    await tester.tap(find.text('扫码'));
    await tester.pumpAndSettle();
    expect(calls, ['scanQrCode']);
    expect(reported, isEmpty);
    expect(find.textContaining('二维码识别器不可用'), findsNothing);
    expect(find.text('打开系统扫码，里面也能从相册选截图'), findsOneWidget);
    // Ready for another try.
    answer = () async => _code;
    await tester.tap(find.text('扫码'));
    await tester.pumpAndSettle();
    expect(reported, [_code]);
    await leave(tester);
  });

  for (final code in ['failed', 'unavailable', 'no_ability']) {
    testWidgets('HarmonyOS: "$code" points to the pairing link, and a retry clears it', (tester) async {
      answer = () async => throw PlatformException(code: code, message: 'native text');
      await tester.pumpWidget(app('ohos'));
      await tester.tap(find.text('扫码'));
      await tester.pumpAndSettle();
      expect(reported, isEmpty);
      expect(find.text('二维码识别器不可用。可以粘贴配对链接继续配对。'), findsOneWidget);
      expect(find.text('native text'), findsNothing);

      answer = () async => _code;
      await tester.tap(find.text('扫码'));
      await tester.pumpAndSettle();
      expect(find.textContaining('二维码识别器不可用'), findsNothing);
      expect(reported, [_code]);
      await leave(tester);
    });
  }

  testWidgets('HarmonyOS: a build without the native method says the reader is unavailable', (tester) async {
    // What the channel answers when no native handler knows the method.
    answer = () async => throw MissingPluginException();
    await tester.pumpWidget(app('ohos'));
    await tester.tap(find.text('扫码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('二维码识别器不可用'), findsOneWidget);
    expect(reported, isEmpty);
    await leave(tester);
  });

  testWidgets('HarmonyOS: an already open scan page ("busy") is not a failure', (tester) async {
    answer = () async => throw PlatformException(code: 'busy');
    await tester.pumpWidget(app('ohos'));
    await tester.tap(find.text('扫码'));
    await tester.pumpAndSettle();
    expect(find.textContaining('二维码识别器不可用'), findsNothing);
    expect(reported, isEmpty);
    await leave(tester);
  });

  testWidgets('HarmonyOS: one scan at a time, and leaving mid-scan reports nothing later', (tester) async {
    final pending = Completer<Object?>();
    answer = () => pending.future;
    await tester.pumpWidget(app('ohos'));
    await tester.tap(find.text('扫码'));
    await tester.pump();
    await tester.tap(find.text('扫码'));
    await tester.pump();
    expect(calls, ['scanQrCode']);

    await tester.pumpWidget(const SizedBox());
    pending.complete(_code);
    await tester.pumpAndSettle();
    expect(reported, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android keeps the camera box with 从相册识别 and never asks for the system scan page', (tester) async {
    final original = MobileScannerPlatform.instance;
    MobileScannerPlatform.instance = _NoCamera();
    addTearDown(() => MobileScannerPlatform.instance = original);
    answer = () => Completer<Object?>().future;
    await tester.pumpWidget(app('android'));
    await tester.pump();
    expect(find.text('从相册识别'), findsOneWidget);
    expect(find.text('扫码'), findsNothing);
    expect(calls, ['initializePairingScanner']);
    await leave(tester);
  });
}
