import 'package:dsh_app/runtime/continued_run.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'read_list_refresh_test.dart' show ListHost, listOverrides, switchConnectionProvider, switchIdentityProvider;

Future<void> _flush(ProviderContainer container) async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
    await container.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dsh/runtime');

  for (final previousLocal in [false, true]) {
    for (final scenario in ['idle', 'running', 'error']) {
      if (previousLocal && scenario == 'idle') continue;
      test('previous ${previousLocal ? 'local client' : 'remote host'} cannot lend a running row: $scenario', () async {
        SharedPreferences.setMockInitialValues({});
        final previous = ListHost(previousLocal ? 'old-local' : 'remote');
        final local = ListHost('new-local')..paused.add('sessions');
        final rows = ListHost.sessions(previous.label);
        ((rows['items'] as List).single as Map)['running'] = scenario != 'idle';
        previous.carrier.handlers['session/list'] = (_) => rows;
        final calls = <bool>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          if (call.method == 'turnRunning') calls.add((call.arguments as Map)['running'] as bool);
          return null;
        });
        final container = ProviderContainer(
          overrides: [...listOverrides(previous), operatingSystemProvider.overrideWithValue('ios')],
        );
        addTearDown(() async {
          container.dispose();
          await previous.client.close();
          await local.client.close();
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
        });
        if (!previousLocal) {
          container.read(activeHostProvider.notifier).select(const HostRef.ssh('remote'));
          container
              .read(switchConnectionProvider.notifier)
              .set(HostConnection(client: previous.client, isLocal: false, kind: HostKind.ssh, hostId: 'remote'));
        }
        container.listen(sessionsProvider, (_, _) {});
        await container.read(sessionsProvider.future);
        container.listen(continuedRunProvider, (_, _) {});
        await _flush(container);
        expect(container.read(localTurnRunningProvider), previousLocal);
        expect(calls, [previousLocal]);

        container.read(activeHostProvider.notifier).select(HostRef.local);
        container.read(switchConnectionProvider.notifier).set(local.connection);
        // The local-client replacement deliberately keeps the same display identity:
        // the response must also belong to the currently live client.
        if (!previousLocal) {
          container.read(switchIdentityProvider.notifier).set(ReadListIdentity.of(['local-source']));
        }
        await _flush(container);
        final pending = container.read(sessionsProvider);
        expect(pending.isLoading, true);
        expect(pending.value!.single.sessionId, '${previous.label}-0');
        final pendingTurn = container.read(localTurnRunningProvider);
        final pendingCalls = List<bool>.of(calls);
        final done = container.read(sessionsProvider.future);
        if (scenario == 'error') {
          local.requests['sessions']!.single.completeError(StateError('fixture local list failed'));
          try {
            await done;
          } catch (_) {
            // The list error is deliberately retained by AsyncValue.
          }
        } else {
          local.requests['sessions']!.single.complete(ListHost.sessions('new-local', count: 0));
          await done;
        }
        await _flush(container);
        expect(container.read(sessionsProvider).hasError, scenario == 'error');
        final expectedCalls = previousLocal ? [true, false] : [false];
        expect(
          {
            'pendingTurn': pendingTurn,
            'pendingCalls': pendingCalls,
            'afterTurn': container.read(localTurnRunningProvider),
            'afterCalls': List<bool>.of(calls),
          },
          {'pendingTurn': false, 'pendingCalls': expectedCalls, 'afterTurn': false, 'afterCalls': expectedCalls},
        );
      });
    }
  }

  for (final fails in [false, true]) {
    test('same local source keeps its running observation through refresh, failure=$fails', () async {
      SharedPreferences.setMockInitialValues({});
      final local = ListHost('local');
      final rows = ListHost.sessions('local');
      ((rows['items'] as List).single as Map)['running'] = true;
      local.carrier.handlers['session/list'] = (_) => local.request('sessions', rows);
      final calls = <bool>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'turnRunning') calls.add((call.arguments as Map)['running'] as bool);
        return null;
      });
      final container = ProviderContainer(
        overrides: [...listOverrides(local), operatingSystemProvider.overrideWithValue('ios')],
      );
      addTearDown(() async {
        container.dispose();
        await local.client.close();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });
      container.listen(sessionsProvider, (_, _) {});
      await container.read(sessionsProvider.future);
      container.listen(continuedRunProvider, (_, _) {});
      await _flush(container);
      expect(calls, [true]);
      local.paused.add('sessions');
      container.invalidate(sessionsProvider);
      await _flush(container);
      final pending = container.read(sessionsProvider);
      expect(pending.isRefreshing, true);
      expect(container.read(localTurnRunningProvider), true);
      expect(calls, [true]);
      final done = container.read(sessionsProvider.future);
      if (fails) {
        local.requests['sessions']!.single.completeError(StateError('fixture same-source refresh failed'));
        try {
          await done;
        } catch (_) {}
      } else {
        local.requests['sessions']!.single.complete(rows);
        await done;
      }
      await _flush(container);
      expect(container.read(sessionsProvider).hasError, fails);
      expect(container.read(localTurnRunningProvider), true);
      expect(calls, [true]);
    });
  }
}
