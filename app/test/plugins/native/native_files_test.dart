import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/plugins/native/native_capabilities.dart';
import 'package:dsh_app/plugins/native/native_effects.dart';
import 'package:dsh_app/plugins/native/native_file_platform.dart';
import 'package:dsh_app/plugins/native/native_files.dart';
import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_platform.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/ui/plugins/native/native_taps.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _request = '12345678901234567890123456789012';
final _now = DateTime.utc(2026, 1, 1);
const _effect = PickFileEffect(
  request: _request,
  action: 'selected',
  images: false,
  maxFiles: 4,
  maxBytes: 8,
  maxTotalBytes: 16,
);
const _wire = <String, Object?>{
  'type': 'pickFile',
  'request': _request,
  'action': 'selected',
  'maxFiles': 4,
  'maxBytes': 8,
  'maxTotalBytes': 16,
};

class _Platform implements NativeFilePlatform {
  int probes = 0, picks = 0, reads = 0;
  final cancels = <String>[];
  bool available = true;
  List<NativeSelectedFile> files = [];
  Completer<List<NativeSelectedFile>>? delayed;
  @override
  Future<bool> supported() async {
    probes++;
    return available;
  }

  @override
  Future<List<NativeSelectedFile>> pick(PickFileEffect effect) async {
    picks++;
    return delayed?.future ?? files;
  }

  @override
  Future<void> cancel(String owner) async {
    cancels.add(owner);
  }

  NativeSelectedFile file(List<int> bytes, {int? reported, String name = 'file.txt'}) => NativeSelectedFile(
    name: name,
    length: reported,
    openRead: () async* {
      reads++;
      yield bytes;
    },
  );
}

class _Transport implements NativeFileTransport {
  final bytes = <List<int>>[];
  final statuses = <String>[];
  VoidCallback? afterUpload;
  Object? uploadError;

  /// Thrown once, by the next complete.
  Object? completeError;
  DshGoInvokeResult response = const DshGoInvokeResult();
  @override
  Future<void> upload(String request, String stream, NativeSelectedFile file, Uint8List data) async {
    expect(request, _request);
    expect(stream, 'c1');
    if (uploadError != null) throw uploadError!;
    bytes.add(List.of(data));
    afterUpload?.call();
  }

  @override
  Future<DshGoInvokeResult> complete(String request, String stream, String status) async {
    statuses.add(status);
    final error = completeError;
    completeError = null;
    if (error != null) throw error;
    return response;
  }
}

Future<DshGoInvokeResult?> _execute(
  NativeFileCoordinator runtime, {
  bool gesture = true,
  DateTime? now,
  bool Function()? current,
}) => runtime.execute(
  _effect,
  pkg: 'files',
  stream: 'c1',
  userGesture: gesture,
  tappedAt: _now,
  now: () => now ?? _now,
  isCurrent: current ?? () => true,
);

class _FileSocket extends FakeSocket {
  @override
  void send(String text) {
    final message = jsonDecode(text) as Map<String, Object?>;
    sent.add(message);
    if (message['t'] == 'hello') {
      push({
        't': 'welcome',
        'v': 1,
        'conn': 'c1',
        'features': ['files'],
      });
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('files-only discovery probes its actual adapter without starting media', () async {
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
    final platform = _Platform();
    var mediaProbes = 0;
    final container = ProviderContainer(
      overrides: [
        nativeBridgeProvider.overrideWithValue(ClientNativeBridge(client)),
        nativeContributionsProvider.overrideWithValue(
          nativeContributionsFrom(
            contributions([
              {
                ...plugin('files'),
                'capabilities': ['files'],
              },
            ]),
          ),
        ),
        nativeFilePlatformProvider.overrideWithValue(platform),
        nativePlatformFeaturesProvider.overrideWith((ref) async {
          mediaProbes++;
          return {};
        }),
      ],
    );
    addTearDown(container.dispose);
    final listener = container.listen(nativeCapabilityDiscoveryProvider, (_, _) {});
    await container.read(nativeCapabilityDiscoveryProvider.future);
    expect(container.read(nativeFeatureStateProvider), ['files']);
    expect(platform.probes, 1);
    expect(mediaProbes, 0);
    listener.close();
  });

  test('disposed capability discovery cannot publish a late file probe', () async {
    final pending = Completer<bool>();
    final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
    final container = ProviderContainer(
      overrides: [
        nativeBridgeProvider.overrideWithValue(ClientNativeBridge(client)),
        nativeContributionsProvider.overrideWithValue(
          nativeContributionsFrom(
            contributions([
              {
                ...plugin('files'),
                'capabilities': ['files'],
              },
            ]),
          ),
        ),
        nativeFileSupportedProvider.overrideWith((ref) => pending.future),
      ],
    );
    container.listen(nativeCapabilityDiscoveryProvider, (_, _) {});
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    pending.complete(true);
    await Future<void>.delayed(Duration.zero);
  });

  test('parser requires bridge-issued authority and finite budgets', () {
    for (final raw in [
      {..._wire, 'request': '../path'},
      {..._wire, 'maxFiles': 5},
      {..._wire, 'maxBytes': 8388609},
      {..._wire, 'maxTotalBytes': 16777217},
      {..._wire, 'maxFiles': 1.0},
    ]) {
      final issues = <NativeIssue>[];
      expect(parseNativeEffects([raw], issues), isEmpty);
      expect(issues, isNotEmpty);
    }
    expect(parseNativeEffects([_wire], []), hasLength(1));
    expect(
      parseNativeEffects([
        {..._wire, 'type': 'pickImage'},
      ], []).single,
      isA<PickFileEffect>().having((e) => e.images, 'image', true),
    );
  });

  test('no native calls for onChange, late arrival, or a stale host', () async {
    final platform = _Platform(), transport = _Transport();
    final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
    expect(await _execute(runtime, gesture: false), isNull);
    expect(await _execute(runtime, now: _now.add(const Duration(seconds: 4))), isNull);
    expect(await _execute(runtime, now: _now.subtract(const Duration(microseconds: 1))), isNull);
    expect(await _execute(runtime, current: () => false), isNull);
    expect(platform.probes, 0);
    expect(platform.picks, 0);
    expect(transport.bytes, isEmpty);
    expect(transport.statuses, ['cancelled', 'cancelled', 'cancelled', 'cancelled']);
  });

  test('metadata preflight rejects the whole selection before any byte read or upload', () async {
    final platform = _Platform(), transport = _Transport();
    final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
    for (final files in [
      [
        platform.file([1], reported: 9),
      ],
      List.generate(5, (_) => platform.file([1], reported: 1)),
      List.generate(3, (_) => platform.file([1], reported: 8)),
    ]) {
      platform.files = files;
      await expectLater(
        _execute(runtime),
        throwsA(isA<NativeFileException>().having((e) => e.problem, 'budget', NativeFileProblem.limit)),
      );
    }
    expect(platform.reads, 0);
    expect(transport.bytes, isEmpty);
    expect(transport.statuses, ['error', 'error', 'error']);
  });

  test('unknown and incorrect lengths are counted again on actual chunks', () async {
    final platform = _Platform(), transport = _Transport();
    final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
    platform.files = [platform.file(List.filled(9, 1), reported: 1)];
    await expectLater(_execute(runtime), throwsA(isA<NativeFileException>()));
    expect(transport.bytes, isEmpty);
    platform.files = [
      platform.file(List.filled(8, 1)),
      platform.file(List.filled(8, 2)),
      platform.file([3]),
    ];
    await expectLater(_execute(runtime), throwsA(isA<NativeFileException>()));
    expect(transport.bytes.map((b) => b.length), [8, 8]);
    expect(transport.statuses, ['error', 'error']);
    expect(platform.cancels, hasLength(2));
  });

  test('cancelled, successful and failed transfers all release native ownership', () async {
    final platform = _Platform(), transport = _Transport();
    final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
    await _execute(runtime);
    expect(transport.statuses, ['cancelled']);
    platform.files = [
      platform.file([1, 2], reported: 2),
    ];
    await _execute(runtime);
    expect(transport.bytes.single, [1, 2]);
    expect(transport.statuses.last, 'selected');
    transport.uploadError = StateError('offline');
    await expectLater(
      _execute(runtime),
      throwsA(isA<NativeFileException>().having((e) => e.problem, 'transport', NativeFileProblem.failed)),
    );
    expect(transport.statuses.last, 'error');
    expect(platform.cancels, hasLength(3));
  });

  test('a selected complete lost on the way is closed with error, so the next pick is not refused', () async {
    final platform = _Platform(), transport = _Transport();
    final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
    platform.files = [
      platform.file([1, 2], reported: 2),
    ];
    transport.completeError = StateError('connection reset');
    await expectLater(
      _execute(runtime),
      throwsA(isA<NativeFileException>().having((e) => e.problem, 'transport', NativeFileProblem.failed)),
    );
    expect(transport.statuses, ['selected', 'error']);
    platform.files = [
      platform.file([3], reported: 1),
    ];
    await _execute(runtime);
    expect(transport.statuses.last, 'selected');
  });

  test('app-wide gate and host cancellation do not wait for a never-returning chooser', () async {
    final gate = NativeFileGate(), platform = _Platform()..delayed = Completer(), other = _Platform();
    final transport = _Transport();
    final a = NativeFileCoordinator(platform: platform, transport: transport, gate: gate);
    final b = NativeFileCoordinator(platform: other, transport: transport, gate: gate);
    final pending = _execute(a);
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      _execute(b),
      throwsA(isA<NativeFileException>().having((e) => e.problem, 'busy', NativeFileProblem.busy)),
    );
    expect(other.picks, 0);
    await a.cancel();
    expect(await pending, isNull);
    await _execute(b);
    expect(other.picks, 1);
    expect(platform.cancels, isNotEmpty);
    // A system reply arriving after cancellation cannot read or upload anything.
    platform.delayed!.complete([
      platform.file([1]),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(platform.reads, 0);
    expect(transport.bytes, isEmpty);
  });

  test('host switch after an upload prevents selected completion and drops the partial batch', () async {
    var current = true;
    final platform = _Platform(), transport = _Transport()..afterUpload = () => current = false;
    platform.files = [
      platform.file([1]),
      platform.file([2]),
    ];
    final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
    expect(await _execute(runtime, current: () => current), isNull);
    expect(transport.bytes, hasLength(1));
    expect(transport.statuses, ['cancelled']);
  });

  test('method adapter streams bounded chunks and never sends a path to the bridge', () async {
    final calls = <MethodCall>[];
    var reads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodNativeFilePlatform.channel,
      (call) async {
        calls.add(call);
        return switch (call.method) {
          'capabilities' => {'files': true},
          'pick' => [
            {'handle': 'local-handle', 'name': 'a.txt', 'bytes': 3},
          ],
          'read' => reads++ == 0 ? Uint8List.fromList([1, 2, 3]) : null,
          _ => null,
        };
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodNativeFilePlatform.channel,
        null,
      ),
    );
    final platform = MethodNativeFilePlatform(), transport = _Transport();
    final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
    await _execute(runtime);
    expect(calls.map((c) => c.method), ['capabilities', 'pick', 'read', 'read', 'cancel']);
    expect((calls[1].arguments as Map)['userGesture'], true);
    expect(transport.bytes.single, [1, 2, 3]);
    expect(transport.statuses, ['selected']);
  });

  testWidgets('actual tap runner gates selection and rejects callback side effects', (tester) async {
    final clipboardCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method.startsWith('Clipboard.')) clipboardCalls.add(call);
        return null;
      },
    );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final platform = _Platform(), transport = _Transport();
    platform.files = [
      platform.file([1, 2, 3]),
    ];
    transport.response = const DshGoInvokeResult(
      effects: [
        {'type': 'copy', 'text': 'must not copy'},
        _wire,
      ],
    );
    final bridge = FakeBridge(
      contributions([
        {
          ...plugin(
            'files',
            panels: [
              {'id': 'panel', 'title': 'Files'},
            ],
          ),
          'capabilities': ['files'],
        },
      ]),
    )..answer = (_) => const DshGoInvokeResult(effects: [_wire]);
    final stream = DshGoStream(() async => _FileSocket(), features: const ['files']);
    final runtime = NativeFileCoordinator(platform: platform, transport: transport, gate: NativeFileGate());
    var gesture = false;
    var current = true;
    Future<bool>? tapped;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...nativeOverrides(bridge, clock: () => _now),
          nativeStreamProvider.overrideWithValue(stream),
          nativeFileCoordinatorProvider.overrideWithValue(runtime),
        ],
        child: MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Consumer(
            builder: (context, ref, _) {
              ref.watch(nativeContributionsProvider);
              return Scaffold(
                body: TextButton(
                  onPressed: () => tapped = runNativeTap(
                    context,
                    ref,
                    package: 'files',
                    surface: NativeSurface.panel,
                    id: 'panel',
                    action: 'choose',
                    userGesture: gesture,
                    stillCurrent: () => current,
                  ),
                  child: const Text('Choose'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Choose'));
      await tapped;
    });
    await tester.pumpAndSettle();
    expect(bridge.invocations.last.userGesture, false);
    expect(platform.picks, 0);
    gesture = true;
    await tester.runAsync(() async {
      await tester.tap(find.text('Choose'));
      await tapped;
    });
    await tester.pumpAndSettle();
    expect(bridge.invocations.last.userGesture, true);
    expect(platform.picks, 1);
    expect(transport.statuses, ['cancelled', 'selected']);
    expect(clipboardCalls, isEmpty);
    platform.delayed = Completer<List<NativeSelectedFile>>();
    await tester.runAsync(() async {
      await tester.tap(find.text('Choose'));
      await Future<void>.delayed(Duration.zero);
    });
    expect(platform.picks, 2);
    current = false;
    await tester.runAsync(() async {
      platform.delayed!.complete([
        platform.file([4, 5, 6]),
      ]);
      expect(await tapped, isFalse);
    });
    expect(transport.bytes, [
      [1, 2, 3],
    ], reason: 'A picker result belonging to an obsolete surface is never uploaded');
    expect(transport.statuses, ['cancelled', 'selected', 'cancelled']);
    expect(clipboardCalls, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await stream.close();
  });
}
