import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_plugin_host.dart';

void main() {
  for (final scenario in [
    'ohos-old-version',
    'ohos-target-version',
    'ohos-wait-unsupported',
    'ohos-authoritative-success',
    'ohos-authoritative-failure',
    'ohos-received-success',
    'android-local',
    'ohos-remote',
  ]) {
    test('install result recovery: $scenario', () async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      carrier.handlers['pluginManager/listBundles'] = (_) => [
        bundleJson('novel-writer', version: scenario == 'ohos-target-version' ? '2.0.0' : '1.0.0'),
      ];
      final success = {
        'stage': 'enable',
        'target': 'novel-writer',
        'bundle': 'novel-writer',
        'version': '2.0.0',
        'changed': true,
        'application': 'restart-required',
        'restartReason': 'package-moved',
        'packageResult': {'exitCode': 0, 'output': 'authoritative install result'},
      };
      carrier.handlers['pluginManager/installBundle'] = (_) {
        if (scenario == 'ohos-received-success') return success;
        throw const DshTransportException('fixture response lost');
      };
      carrier.handlers['pluginManager/waitForInstall'] = (_) {
        if (scenario == 'ohos-authoritative-success') return success;
        if (scenario == 'ohos-authoritative-failure') {
          return installResult(application: 'failed', error: {'code': 'already-installed'});
        }
        if (scenario == 'ohos-wait-unsupported') {
          throw const DshRemoteException('METHOD_NOT_FOUND', 'waitForInstall unavailable');
        }
        return null;
      };
      final container = ProviderContainer(
        overrides: [
          ...pluginOverrides(fakeHost(client, kind: scenario == 'ohos-remote' ? HostKind.ssh : HostKind.local)),
          operatingSystemProvider.overrideWithValue(scenario == 'android-local' ? 'android' : 'ohos'),
        ],
      );
      addTearDown(container.dispose);
      final result = await container
          .read(pluginInstallsProvider.notifier)
          .install(const PluginInstallRequest(name: 'novel-writer', spec: 'novel-writer@2.0.0'));
      if (scenario == 'ohos-authoritative-success' || scenario == 'ohos-received-success') {
        expect(result.phase, PluginInstallPhase.succeeded);
        expect(result.result!.application, PluginApplication.restartRequired);
        expect(result.result!.restartReason, 'package-moved');
        expect(result.result!.changed, true);
        expect(result.result!.version, '2.0.0');
        expect(result.result!.packageResult!.output, 'authoritative install result');
      } else if (scenario == 'ohos-authoritative-failure') {
        expect(result.phase, PluginInstallPhase.failed);
        expect(result.result!.error!.code, 'already-installed');
        expect(result.failure!.kind, PluginFailureKind.alreadyInstalled);
      } else if (scenario == 'android-local' || scenario == 'ohos-remote') {
        expect(result.phase, PluginInstallPhase.succeeded, reason: 'retain the existing host contract');
        expect(result.result!.application, PluginApplication.applied);
      } else {
        expect(result.phase, PluginInstallPhase.failed);
        expect(result.failure!.kind, PluginFailureKind.resultUnknown);
        expect(result.result, isNull, reason: 'no invented applied result from inventory');
      }
      final waits = carrier.argsOf('pluginManager/waitForInstall');
      expect(waits, hasLength(scenario == 'ohos-received-success' ? 0 : 1));
      if (waits.isNotEmpty) expect(waits.single['requestId'], result.requestId);
    });
  }
}
