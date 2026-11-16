// Actual automaticDiagnosticsProvider, sender and DshClient HTTP. Dependency
// controllers, local server and SDK channel replies are explicit boundaries.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/diagnostics/automatic_diagnostics.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart'
    show FlagController, appForegroundProvider;
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../../../packages/dsh_client/test/support/fake_dsh.dart';

class _Settings extends SettingsController {
  @override
  AppSettings build() => const AppSettings(loaded: true);
  void enable() =>
      state = const AppSettings(loaded: true, automaticDiagnostics: true);
  void disable() => state = const AppSettings(loaded: true);
}

class _FailureStore extends InMemorySharedPreferencesStore {
  _FailureStore() : super.empty();
  int writes = 0;
  final rows = <Map<String, Object?>>[];
  final errorCheckpointEntered = Completer<void>();
  final releaseErrorCheckpoint = Completer<void>();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (!key.endsWith('automatic_diagnostics_checkpoint')) {
      return super.setValue(valueType, key, value);
    }
    writes++;
    final at = writes;
    rows.add({'write': at, 'checkpoint': jsonDecode(value as String)});
    if (at == 2) {
      rows.add({
        'write': at,
        'accepted': false,
        'stage': 'created-session checkpoint',
      });
      return false;
    }
    if (at == 3) {
      errorCheckpointEntered.complete();
      await releaseErrorCheckpoint.future;
      rows.add({
        'write': at,
        'accepted': false,
        'stage': 'analysis-error checkpoint',
      });
      return false;
    }
    final result = await super.setValue(valueType, key, value);
    rows.add({'write': at, 'accepted': result});
    return result;
  }
}

class _Runtime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => const LocalRuntimeState(
    loaded: true,
    status: RuntimeStatus(phase: RuntimePhase.running),
  );
}

class _Host extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _Local extends LocalConnectionController {
  _Local(this.initial);
  final HostConnection initial;
  @override
  Future<HostConnection?> build() async => initial;
  void emit(HostConnection? value) => state = AsyncData(value);
}

class _LoopbackOnly extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) {
      if (uri.host != '127.0.0.1')
        throw StateError('Only finite loopback fixture requests are allowed');
      return 'DIRECT';
    };
    return client;
  }
}

Future<void> _until(bool Function() test, String name) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) throw StateError('Timed out: $name');
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const checkpointKey = 'automatic_diagnostics_checkpoint';
  final scenarios = [
    (
      name: 'OH provider ignores old failure after null and new owner',
      os: 'ohos',
      provider: true,
      gap: true,
      newWork: true,
      reject: true,
      failed: false,
    ),
    (
      name: 'OH provider ignores old failure after connection replacement and error revision',
      os: 'ohos',
      provider: true,
      gap: false,
      newWork: true,
      reject: true,
      failed: false,
    ),
    (
      name: 'OH provider keeps cancellation failure visible without a replacement attempt',
      os: 'ohos',
      provider: true,
      gap: true,
      newWork: false,
      reject: true,
      failed: true,
    ),
    (
      name: 'OH provider successful old cancellation leaves replacement analyzing',
      os: 'ohos',
      provider: true,
      gap: true,
      newWork: true,
      reject: false,
      failed: false,
    ),
    (
      name: 'Android provider retains legacy old cancellation failure behavior',
      os: 'android',
      provider: true,
      gap: true,
      newWork: true,
      reject: true,
      failed: true,
    ),
    (
      name: 'default coordinator retains legacy behavior even with OH evidence',
      os: 'ohos',
      provider: false,
      gap: true,
      newWork: true,
      reject: true,
      failed: true,
    ),
  ];

  for (final scenario in scenarios) {
    test(
      scenario.name,
      () => HttpOverrides.runWithHttpOverrides(() async {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        // This actual Flutter test is required to live outside app/test.
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        final wirePath = Platform.environment['OHOS_CANCEL_OWNER_WIRE'];
        if (wirePath == null)
          throw StateError(
            'OHOS_CANCEL_OWNER_WIRE must name actual ETS snapshots',
          );
        final snapshots =
            (jsonDecode(await File(wirePath).readAsString())
                    as Map)['snapshots']
                as List;
        expect(snapshots, hasLength(2));
        var snapshotIndex = 0;
        final platformMethods = <String>[];
        const channel = MethodChannel('dsh/diagnostics');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              platformMethods.add(call.method);
              if (call.method == 'info') return snapshots[snapshotIndex];
              if (call.method == 'recordAppError') return null;
              throw StateError('Unexpected diagnostics method ${call.method}');
            });
        final oldHost = await FakeDsh.start(), nextHost = await FakeDsh.start();
        final oldProjectionEntered = Completer<void>(),
            releaseOldProjection = Completer<void>();
        final oldCancelEntered = Completer<void>(),
            releaseOldCancel = Completer<void>();
        final nextProjectionEntered = Completer<void>(),
            releaseNextProjection = Completer<void>();
        final oldCancelReply = Completer<void>(),
            nextCancelReply = Completer<void>();
        final trace = <Map<String, Object?>>[],
            phases = <Map<String, Object?>>[];

        void configureHost(FakeDsh host, String id) {
          host.handlers['session/create'] = (_) => {
            'ok': true,
            'value': {'sessionId': id, 'agentPreset': 'dsh-go-diagnostics'},
          };
          host.handlers['session/projections'] = (_) => {
            'ok': true,
            'value': {
              'asOfSeq': 0,
              'values': {'agentPreset': 'dsh-go-diagnostics'},
            },
          };
          host.handlers['session/cancel'] = (_) => {
            'ok': true,
            'value': {'accepted': true},
          };
        }

        configureHost(oldHost, 'old-analysis');
        configureHost(nextHost, 'next-analysis');
        oldHost.beforeRpc = (method, _) async {
          if (method == 'session/projections') {
            oldProjectionEntered.complete();
            await releaseOldProjection.future;
          }
          if (method == 'session/cancel') {
            oldCancelEntered.complete();
            await releaseOldCancel.future;
          }
        };
        if (scenario.reject) {
          oldHost.handlers['session/cancel'] = (_) => {
            'ok': false,
            'error': {
              'code': 'session/not-found',
              'message': 'Old session unavailable',
              'details': <String, Object?>{},
            },
          };
        }
        nextHost.beforeRpc = (method, _) async {
          if (method == 'session/projections') {
            nextProjectionEntered.complete();
            await releaseNextProjection.future;
          }
        };
        void observe(String owner, DshTraceEntry entry) {
          trace.add({'owner': owner, ...entry.toJson()});
          final data = entry.data;
          if (entry.direction == 'in' &&
              entry.channel == 'rpc' &&
              data is Map &&
              data['endpoint'] == 'session/cancel') {
            final response = owner == 'old' ? oldCancelReply : nextCancelReply;
            if (!response.isCompleted) response.complete();
          }
        }

        final oldClient = await DshClient.connect(
          baseUri: oldHost.baseUri,
          token: FakeDsh.token,
          startMux: false,
          tracer: (entry) => observe('old', entry),
        );
        final nextClient = await DshClient.connect(
          baseUri: nextHost.baseUri,
          token: FakeDsh.token,
          startMux: false,
          tracer: (entry) => observe('next', entry),
        );
        final oldConnection = HostConnection(client: oldClient, isLocal: true);
        final nextConnection = HostConnection(
          client: nextClient,
          isLocal: true,
        );
        final container = ProviderContainer(
          overrides: [
            operatingSystemProvider.overrideWithValue(scenario.os),
            settingsProvider.overrideWith(_Settings.new),
            localRuntimeProvider.overrideWith(_Runtime.new),
            activeHostProvider.overrideWith(_Host.new),
            appForegroundProvider.overrideWith(() => FlagController(true)),
            localConnectionProvider.overrideWith(() => _Local(oldConnection)),
            // The production active-host local branch reads this same provider.
            // ConnectionDiagnostics observation is outside this cancellation test.
            activeConnectionProvider.overrideWith(
              (ref) => ref.watch(localConnectionProvider),
            ),
          ],
        );
        final prefs = await SharedPreferences.getInstance();
        // Keep the actual provider live for the same lifetime as RootGate.watch.
        // ChangeNotifier listeners alone do not keep a Riverpod subscription active.
        final subscription = scenario.provider
            ? container.listen(automaticDiagnosticsProvider, (_, __) {})
            : null;
        final automatic = scenario.provider
            ? subscription!.read()
            : AutomaticDiagnostics(
                collect: () async => DiagnosticsSnapshot(
                  at: DateTime.now(),
                  status: const RuntimeStatus(phase: RuntimePhase.running),
                  settings: const AppSettings(),
                  native: await container
                      .read(diagnosticsChannelProvider)
                      .info(),
                ),
                load: () async => prefs.getString(checkpointKey) == null
                    ? {}
                    : Map<String, Object?>.from(
                        jsonDecode(prefs.getString(checkpointKey)!) as Map,
                      ),
                store: (value) async {
                  if (!await prefs.setString(checkpointKey, jsonEncode(value)))
                    throw StateError('store failed');
                },
              );
        automatic.addListener(
          () => phases.add({
            'phase': automatic.phase.name,
            'eligible': automatic.eligible,
            'busy': automatic.busy,
            'sessionId': automatic.reportSessionId,
            'failureCode': automatic.failureCode,
          }),
        );
        final local = scenario.provider
            ? container.read(localConnectionProvider.notifier) as _Local
            : null;
        Future<void>? directFirst, directSecond;
        var stage = 'initial-provider-settlement';
        try {
          if (scenario.provider) {
            (container.read(settingsProvider.notifier) as _Settings).enable();
            await container.read(localConnectionProvider.future);
            await container.pump();
          }
          stage = 'old-projections';
          if (!scenario.provider) {
            automatic.configure(
              oldClient,
              (prompt, current, created) =>
                  sendDiagnosticAnalysis(oldClient, prompt, current, created),
            );
            directFirst = automatic.check();
          }
          await oldProjectionEntered.future.timeout(const Duration(seconds: 5));
          expect(automatic.reportSessionId, 'old-analysis');
          expect(automatic.busy, isTrue);
          if (scenario.provider) {
            local!.emit(scenario.gap ? null : nextConnection);
            await container.pump();
          } else {
            automatic.configure(null, null);
          }
          stage = 'old-cancel-admitted';
          await oldCancelEntered.future.timeout(const Duration(seconds: 5));
          expect(
            nextHost.rpcCalls,
            isEmpty,
            reason: 'The first check scheduled while old work is busy cannot start new work',
          );
          releaseOldProjection.complete();
          await _until(() => !automatic.busy, 'old sender guard exits');
          if (scenario.newWork) {
            snapshotIndex = 1;
            if (!scenario.provider) {
              automatic.configure(
                nextClient,
                (prompt, current, created) => sendDiagnosticAnalysis(
                  nextClient,
                  prompt,
                  current,
                  created,
                ),
              );
              directSecond = automatic.check();
            } else if (scenario.gap) {
              local!.emit(nextConnection);
              await container.pump();
            } else {
              expect(automatic.eligible, isTrue);
              // This is the actual global producer's revision notification, not
              // a direct check() call or a manually incremented ValueNotifier.
              appErrorLog.record(
                AppErrorSource.platform,
                StateError('finite owner-state probe'),
                StackTrace.fromString(
                  '#0 probe (package:dsh_app/diagnostics/automatic_diagnostics.dart:1:1)',
                ),
              );
            }
            stage = 'replacement-projections';
            await nextProjectionEntered.future.timeout(
              const Duration(seconds: 5),
            );
            expect(automatic.phase, AutomaticDiagnosticsPhase.analyzing);
            expect(automatic.reportSessionId, 'next-analysis');
          } else {
            expect(automatic.eligible, isFalse);
            expect(automatic.phase, AutomaticDiagnosticsPhase.cancelled);
          }
          if (scenario.provider)
            expect(
              container.read(automaticDiagnosticsProvider),
              same(automatic),
            );
          stage = 'old-cancel-reply';
          releaseOldCancel.complete();
          await oldCancelReply.future.timeout(const Duration(seconds: 5));
          await Future<void>.delayed(Duration.zero);
          final checkpoint = jsonDecode(prefs.getString(checkpointKey)!);
          debugPrint(
            jsonEncode({
              'probe': scenario.name,
              'selectedPlatform': scenario.os,
              'actualProvider': scenario.provider,
              'newWork': scenario.newWork,
              'nullGap': scenario.gap,
              'cancelRejected': scenario.reject,
              'phase': automatic.phase.name,
              'sessionId': automatic.reportSessionId,
              'failureCode': automatic.failureCode,
              'busy': automatic.busy,
              'checkpoint': checkpoint,
              'phases': phases,
              'trace': trace,
              'platformMethods': platformMethods,
              'oldRpcMethods': oldHost.rpcCalls
                  .map((row) => row['method'])
                  .toList(),
              'newRpcMethods': nextHost.rpcCalls
                  .map((row) => row['method'])
                  .toList(),
            }),
          );
          expect(
            automatic.phase,
            scenario.failed
                ? AutomaticDiagnosticsPhase.failed
                : AutomaticDiagnosticsPhase.analyzing,
            reason:
                scenario.provider && scenario.os == 'ohos' && scenario.newWork
                ? 'A previous cancellation must not overwrite the current OH attempt state'
                : 'Compatibility and current cancellation failure contract',
          );
          expect(
            automatic.failureCode,
            scenario.failed ? 'cancel_failed' : null,
          );
          expect(
            automatic.reportSessionId,
            scenario.newWork ? 'next-analysis' : 'old-analysis',
          );
          expect(automatic.busy, scenario.newWork);
        } catch (error) {
          debugPrint(
            jsonEncode({
              'probeErrorStage': stage,
              'case': scenario.name,
              'error': error.toString(),
              'phase': automatic.phase.name,
              'eligible': automatic.eligible,
              'busy': automatic.busy,
              'sessionId': automatic.reportSessionId,
              'failureCode': automatic.failureCode,
              'lifecycle': binding.lifecycleState?.name,
              'platformMethods': platformMethods,
              'gates': {
                'settingsLoaded': container.read(settingsProvider).loaded,
                'enabled': container
                    .read(settingsProvider)
                    .automaticDiagnostics,
                'foreground': container.read(appForegroundProvider),
                'hostLocal': container.read(activeHostProvider).isLocal,
                'runtimeLoaded': container.read(localRuntimeProvider).loaded,
                'runtimePhase': container
                    .read(localRuntimeProvider)
                    .status
                    .phase
                    .name,
                'localLoading': container
                    .read(localConnectionProvider)
                    .isLoading,
                'localHasError': container
                    .read(localConnectionProvider)
                    .hasError,
                'localPresent':
                    container.read(localConnectionProvider).value != null,
                'activeLoading': container
                    .read(activeConnectionProvider)
                    .isLoading,
                'activeHasError': container
                    .read(activeConnectionProvider)
                    .hasError,
                'activePresent':
                    container.read(activeConnectionProvider).value != null,
              },
              'oldRpcMethods': oldHost.rpcCalls
                  .map((row) => row['method'])
                  .toList(),
              'newRpcMethods': nextHost.rpcCalls
                  .map((row) => row['method'])
                  .toList(),
            }),
          );
          rethrow;
        } finally {
          if (!releaseOldProjection.isCompleted)
            releaseOldProjection.complete();
          if (!releaseOldCancel.isCompleted) releaseOldCancel.complete();
          if (scenario.provider) {
            local!.emit(null);
            await container.pump();
          } else {
            automatic.configure(null, null);
          }
          await _until(
            () => !automatic.eligible,
            'cleanup revokes current owner',
          );
          if (!releaseNextProjection.isCompleted)
            releaseNextProjection.complete();
          if (directFirst != null) await directFirst;
          if (directSecond != null) await directSecond;
          await _until(() => !automatic.busy, 'cleanup waits for sender guard');
          if (nextProjectionEntered.isCompleted) {
            await nextCancelReply.future.timeout(const Duration(seconds: 5));
            await Future<void>.delayed(Duration.zero);
          }
          if (!scenario.provider) automatic.dispose();
          subscription?.close();
          container.dispose();
          await oldClient.close();
          await nextClient.close();
          await oldHost.close();
          await nextHost.close();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
          final modelPrompts = [
            ...oldHost.rpcCalls,
            ...nextHost.rpcCalls,
          ].where((row) => row['method'] == 'session/prompt').length;
          debugPrint(
            jsonEncode({
              'cleanup': scenario.name,
              'modelPromptRequests': modelPrompts,
              'clientsClosed': true,
              'localServersClosed': true,
            }),
          );
          expect(modelPrompts, 0);
        }
      }, _LoopbackOnly()),
      timeout: const Timeout(Duration(seconds: 20)),
    );
  }

  test(
    'OH provider ignores old cancellation after same-null-epoch storage recovery',
    () => HttpOverrides.runWithHttpOverrides(() async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // This actual Flutter test is required to live outside app/test.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final storage = _FailureStore();
      SharedPreferencesStorePlatform.instance = storage;
      final wirePath = Platform.environment['OHOS_CANCEL_OWNER_WIRE'];
      if (wirePath == null) throw StateError('actual ETS snapshots required');
      final snapshots =
          (jsonDecode(await File(wirePath).readAsString()) as Map)['snapshots']
              as List;
      var snapshotIndex = 0;
      const channel = MethodChannel('dsh/diagnostics');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'info') return snapshots[snapshotIndex];
            if (call.method == 'recordAppError') return null;
            throw StateError('Unexpected diagnostics method ${call.method}');
          });
      final host = await FakeDsh.start();
      final cancelEntered = Completer<void>(),
          releaseCancel = Completer<void>(),
          cancelReply = Completer<void>();
      final trace = <Map<String, Object?>>[];
      host.handlers['session/create'] = (_) => {
        'ok': true,
        'value': {
          'sessionId': 'recovery-old-analysis',
          'agentPreset': 'dsh-go-diagnostics',
        },
      };
      host.handlers['session/cancel'] = (_) => {
        'ok': false,
        'error': {
          'code': 'session/not-found',
          'message': 'Old session unavailable',
          'details': <String, Object?>{},
        },
      };
      host.beforeRpc = (method, _) async {
        if (method == 'session/cancel') {
          cancelEntered.complete();
          await releaseCancel.future;
        }
      };
      final client = await DshClient.connect(
        baseUri: host.baseUri,
        token: FakeDsh.token,
        startMux: false,
        tracer: (entry) {
          trace.add(entry.toJson());
          final data = entry.data;
          if (entry.direction == 'in' &&
              entry.channel == 'rpc' &&
              data is Map &&
              data['endpoint'] == 'session/cancel' &&
              !cancelReply.isCompleted)
            cancelReply.complete();
        },
      );
      final container = ProviderContainer(
        overrides: [
          operatingSystemProvider.overrideWithValue('ohos'),
          settingsProvider.overrideWith(_Settings.new),
          localRuntimeProvider.overrideWith(_Runtime.new),
          activeHostProvider.overrideWith(_Host.new),
          appForegroundProvider.overrideWith(() => FlagController(true)),
          localConnectionProvider.overrideWith(
            () => _Local(HostConnection(client: client, isLocal: true)),
          ),
        ],
      );
      final subscription = container.listen(
        automaticDiagnosticsProvider,
        (_, __) {},
      );
      final automatic = subscription.read();
      final phases = <Map<String, Object?>>[];
      automatic.addListener(
        () => phases.add({
          'phase': automatic.phase.name,
          'eligible': automatic.eligible,
          'busy': automatic.busy,
          'failureCode': automatic.failureCode,
        }),
      );
      final settings = container.read(settingsProvider.notifier) as _Settings;
      try {
        settings.enable();
        await container.read(localConnectionProvider.future);
        await container.pump();
        await storage.errorCheckpointEntered.future.timeout(
          const Duration(seconds: 5),
        );
        expect(automatic.reportSessionId, 'recovery-old-analysis');
        expect(automatic.busy, isTrue);
        settings.disable();
        await container.pump();
        await cancelEntered.future.timeout(const Duration(seconds: 5));
        expect(automatic.eligible, isFalse);
        storage.releaseErrorCheckpoint.complete();
        await _until(
          () => !automatic.busy,
          'failed error checkpoint exits original check',
        );
        expect(automatic.failureCode, 'store_failed');
        expect(container.read(activeHostProvider).isLocal, isTrue);
        expect(container.read(settingsProvider).automaticDiagnostics, isFalse);
        snapshotIndex = 1;
        // Actual public data entry used by DiagnosticsPage._recover: local host,
        // not busy, current page. No UI pump or manual configure/check is claimed.
        await automatic.recoverStorage(
          isCurrent: () => container.read(activeHostProvider).isLocal,
        );
        expect(automatic.phase, AutomaticDiagnosticsPhase.waiting);
        expect(automatic.failureCode, isNull);
        expect(automatic.busy, isFalse);
        expect(storage.writes, 4);
        final stored =
            (await storage.getAll())['flutter.automatic_diagnostics_checkpoint']
                as String;
        final recovered = jsonDecode(stored);
        expect(recovered['phase'], 'waiting');
        expect(recovered['failureCode'], isNull);
        releaseCancel.complete();
        await cancelReply.future.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(Duration.zero);
        debugPrint(
          jsonEncode({
            'probe':
                'OH same-null-epoch recovery then old cancellation failure',
            'actualProvider': true,
            'selectedPlatform': 'ohos',
            'phase': automatic.phase.name,
            'failureCode': automatic.failureCode,
            'busy': automatic.busy,
            'eligible': automatic.eligible,
            'storeWrites': storage.rows,
            'recoveredCheckpoint': recovered,
            'phases': phases,
            'trace': trace,
            'rpcMethods': host.rpcCalls.map((r) => r['method']).toList(),
          }),
        );
        expect(
          automatic.phase,
          AutomaticDiagnosticsPhase.waiting,
          reason: 'A completed deliberate local recovery owns its state even while owner remains null',
        );
        expect(automatic.failureCode, isNull);
        expect(automatic.eligible, isFalse);
      } finally {
        if (!storage.releaseErrorCheckpoint.isCompleted)
          storage.releaseErrorCheckpoint.complete();
        if (!releaseCancel.isCompleted) releaseCancel.complete();
        settings.disable();
        await container.pump();
        await _until(() => !automatic.busy, 'recovery cleanup');
        subscription.close();
        container.dispose();
        await client.close();
        await host.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        final methods = host.rpcCalls.map((r) => r['method']).toList();
        debugPrint(
          jsonEncode({
            'cleanup': 'same-null-epoch recovery',
            'modelPromptRequests': methods
                .where((m) => m == 'session/prompt')
                .length,
            'projectionRequests': methods
                .where((m) => m == 'session/projections')
                .length,
            'clientClosed': true,
            'serverClosed': true,
          }),
        );
        expect(
          methods.where(
            (m) => m == 'session/prompt' || m == 'session/projections',
          ),
          isEmpty,
        );
        // This actual Flutter test is required to live outside app/test.
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
      }
    }, _LoopbackOnly()),
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
