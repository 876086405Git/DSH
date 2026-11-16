import 'dart:async';

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_plugin_host.dart';

void main() {
  for (final scenario in ['ohos-local', 'ohos-switch', 'ohos-remove-failed', 'android-local', 'ohos-remote']) {
    test('cancel during replacement removal: $scenario', () async {
      final carrier = FakePluginCarrier();
      final client = DshClient.withCarrier(carrier);
      addTearDown(client.close);
      final removal = Completer<Object?>();
      carrier.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
      carrier.handlers['pluginManager/removeBundle'] = (_) => removal.future;
      carrier.handlers['pluginManager/cancelInstall'] = (_) => {'status': 'not-running'};
      carrier.handlers['pluginManager/installBundle'] = (_) => installResult();
      final os = scenario == 'android-local' ? 'android' : 'ohos';
      final kind = scenario == 'ohos-remote' ? HostKind.ssh : HostKind.local;
      final container = ProviderContainer(
        overrides: [
          ...pluginOverrides(fakeHost(client, kind: kind)),
          pluginHostProvider.overrideWithValue(PluginHost.of(fakeHost(client, kind: kind))),
          operatingSystemProvider.overrideWithValue(os),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(pluginInstallsProvider.notifier);
      const request = PluginInstallRequest(
        name: 'novel-writer',
        spec: 'novel-writer@2.0.0',
        title: 'Novel Writer',
        replaceInstalled: true,
      );
      final done = controller.install(request);
      await pumpEventQueue();
      expect(container.read(pluginInstallsProvider)[request.name]!.phase, PluginInstallPhase.removing);
      await controller.cancel(request.name);
      expect(container.read(pluginInstallsProvider)[request.name]!.phase, PluginInstallPhase.cancelling);
      final localOhos = os == 'ohos' && kind == HostKind.local;
      FakePluginCarrier? other;
      Future<PluginInstallJob>? otherDone;
      Completer<Object?>? otherInstall;
      if (scenario == 'ohos-switch') {
        other = FakePluginCarrier();
        final otherClient = DshClient.withCarrier(other);
        addTearDown(otherClient.close);
        other.handlers['pluginManager/listBundles'] = (_) => sampleBundles;
        otherInstall = Completer<Object?>();
        other.handlers['pluginManager/installBundle'] = (_) => otherInstall!.future;
        container.updateOverrides([
          ...pluginOverrides(fakeHost(otherClient, kind: HostKind.ssh)),
          pluginHostProvider.overrideWithValue(PluginHost.of(fakeHost(otherClient, kind: HostKind.ssh))),
          operatingSystemProvider.overrideWithValue(os),
        ]);
        await pumpEventQueue();
        expect(container.read(pluginInstallsProvider), isEmpty);
        expect(container.read(pluginInstallsProvider.notifier), same(controller));
        otherDone = controller.install(const PluginInstallRequest(name: 'novel-writer', spec: 'novel-writer@3.0.0'));
        await pumpEventQueue();
      }
      final failed = scenario == 'ohos-remove-failed';
      removal.complete({
        'stage': 'remove',
        'target': request.name,
        'changed': !failed,
        'application': failed ? 'failed' : 'applied',
        if (failed) 'error': {'code': 'operation-error', 'diagnostic': 'fixture remove failure'},
      });
      final result = await done;
      if (failed) {
        expect(result.phase, PluginInstallPhase.failed);
        expect(result.failure!.detail, contains('fixture remove failure'));
        expect(result.failure!.kind, isNot(PluginFailureKind.cancelled));
      } else if (localOhos) {
        expect(result.phase, PluginInstallPhase.cancelled);
        expect(result.result!.changed, isTrue);
        expect(result.result!.stage, 'remove');
        expect(result.failure!.title, '已取消安装');
        expect(result.failure!.message, '已卸载「Novel Writer」');
        expect(result.failure!.message, isNot(contains('没有改动')));
      } else {
        expect(result.phase, PluginInstallPhase.succeeded, reason: 'Android and remote retain their existing path');
      }
      expect(carrier.argsOf('pluginManager/installBundle'), hasLength(localOhos ? 0 : 1));
      expect(carrier.argsOf('pluginManager/cancelInstall'), hasLength(localOhos ? 0 : 1));
      if (other != null) {
        final current = container.read(pluginInstallsProvider)[request.name]!;
        expect(current.phase, PluginInstallPhase.installing);
        expect(current.requestId, isNot(result.requestId));
        expect(other.argsOf('pluginManager/cancelInstall'), isEmpty);
        otherInstall!.complete(installResult());
        expect((await otherDone!).phase, PluginInstallPhase.succeeded);
        expect(other.argsOf('pluginManager/installBundle'), hasLength(1));
      }
    });
  }
}
