import 'package:dsh_app/l10n/gen/app_localizations_zh.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/runtime_capabilities_state.dart';
import 'package:dsh_app/ui/engine/engine_capabilities.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';

final _zh = L10nZh();

Future<void> _pump(WidgetTester tester, RuntimeCapabilities? caps) async {
  await tester.pumpWidget(
    goldenApp(
      home: Scaffold(
        body: Builder(builder: (context) => Column(children: engineCapabilityRows(context.l10n, caps))),
      ),
      brightness: Brightness.light,
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('an engine that says nothing has no rows', (tester) async {
    await _pump(tester, null);
    expect(find.text(_zh.engineCapShell), findsNothing);
    expect(find.text(_zh.engineCapNodeScripts), findsNothing);
  });

  testWidgets('what the engine reports, in words', (tester) async {
    await _pump(
      tester,
      const RuntimeCapabilities(
        shell: RuntimeShellCapabilities(kind: RuntimeShellKind.virtual, commands: ['ls', 'cat', 'rg']),
        nodeScripts: RuntimeNodeScripts.none,
        plugins: RuntimePluginCapabilities(marketInstall: RuntimeSupport.unsupported),
        background: RuntimeBackgroundCapabilities(policy: RuntimeBackgroundPolicy.mayFreeze),
      ),
    );
    expect(find.text(_zh.engineCapShellBuiltin(3)), findsOneWidget);
    expect(find.text(_zh.engineCapNone), findsNWidgets(2));
    expect(find.text(_zh.engineCapMayFreeze), findsOneWidget);
  });

  testWidgets('a fact it does not know has no row', (tester) async {
    await _pump(tester, const RuntimeCapabilities(nodeScripts: RuntimeNodeScripts.worker));
    expect(find.text(_zh.engineCapNodeScripts), findsOneWidget);
    expect(find.text(_zh.engineCapYes), findsOneWidget);
    expect(find.text(_zh.engineCapShell), findsNothing);
    expect(find.text(_zh.engineCapBackground), findsNothing);
  });

  test('only a clear no refuses market installs', () async {
    for (final (support, refused) in const [
      (RuntimeSupport.unsupported, true),
      (RuntimeSupport.supported, false),
      (RuntimeSupport.unknown, false),
    ]) {
      final container = ProviderContainer(
        overrides: [
          runtimeCapabilitiesProvider.overrideWith(
            (ref) async => RuntimeCapabilities(plugins: RuntimePluginCapabilities(marketInstall: support)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(marketInstallRefusedProvider, (_, _) {});
      await container.read(runtimeCapabilitiesProvider.future);
      expect(sub.read(), refused);
      sub.close();
    }
  });
}
