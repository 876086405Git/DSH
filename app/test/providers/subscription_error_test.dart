// D5: 订阅详情的模型卡只在目录真的读到、且这个订阅确实没有模型时才说「暂无模型」。
// 读取失败（首读失败、刷新失败、目录里这个渠道报错）是错误态加重试；没连上引擎
// 是离线态。Started from the 023 counterexample.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/ui/providers/subscription_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

const _codex = ProviderGroup('openai-codex', 'ChatGPT', [
  ModelInfo(provider: 'openai-codex', id: 'gpt-5.1-codex', name: 'GPT-5.1 Codex'),
  ModelInfo(provider: 'openai-codex', id: 'gpt-5.1', name: 'GPT-5.1'),
]);

ModelCatalog _catalog({
  List<ProviderGroup> groups = const [_codex],
  List<({String provider, String name, String message})> failures = const [],
}) => ModelCatalog(defaultSelection: null, routableProviders: const [], groups: groups, failures: failures);

void main() {
  /// The ChatGPT page, signed in; each catalog read takes the next answer
  /// from [reads] (a [ModelCatalog], null for "not connected", or an error
  /// to throw). Returns the number of reads so far.
  Future<int Function()> pumpPage(WidgetTester tester, List<Object?> reads) async {
    await tester.runAsync(loadGoldenFonts);
    tester.view.devicePixelRatio = 2;
    tester.view.physicalSize = const Size(780, 1800);
    addTearDown(tester.view.reset);
    var count = 0;
    await tester.pumpWidget(
      goldenApp(
        home: const SubscriptionPage(subscription: Subscription.chatgpt),
        brightness: Brightness.light,
        overrides: [
          ...providerOverrides(
            FakeProviderBackend(),
            subscriptions: FakeSubscriptionBackend(
              statuses: const [
                SubscriptionStatus(subscription: Subscription.chatgpt, signedIn: true, account: 'me@example.com'),
              ],
            ),
          ),
          modelCatalogProvider.overrideWith((ref) async {
            final answer = reads[count < reads.length ? count : reads.length - 1];
            count++;
            if (answer is Exception || answer is Error) throw answer!;
            return answer as ModelCatalog?;
          }),
        ],
      ),
    );
    await settle(tester);
    return () => count;
  }

  final noModels = find.text(appL10n.engineSubscriptionNoModels);
  final failed = find.text(appL10n.engineSubscriptionModelsFailed);
  final retry = find.text(appL10n.commonRetry);

  testWidgets('D5 initial catalog error must not be presented as an empty catalog', (tester) async {
    final reads = await pumpPage(tester, [StateError('review-only unavailable')]);
    final container = ProviderScope.containerOf(tester.element(find.byType(SubscriptionPage)));
    final state = container.read(modelCatalogProvider);
    expect(state.hasError, isTrue, reason: 'the actual provider reached AsyncError');
    expect(state.isLoading, isFalse);
    expect(tester.takeException(), isNull);
    expect(noModels, findsNothing, reason: 'a failed query cannot establish that no models exist');
    expect(failed, findsOneWidget);
    expect(retry, findsOneWidget);
    expect(reads(), 1);
  });

  testWidgets('retry reads the catalog again and shows what it brings', (tester) async {
    final reads = await pumpPage(tester, [StateError('unavailable'), _catalog()]);
    await tester.tap(retry);
    await settle(tester);
    expect(reads(), 2);
    expect(failed, findsNothing);
    expect(find.text('GPT-5.1 Codex'), findsOneWidget);
    expect(find.text('模型 · 2'), findsOneWidget);
  });

  testWidgets('a catalog that read fine but has none for this subscription is truly empty', (tester) async {
    await pumpPage(tester, [
      _catalog(groups: const [], failures: const [(provider: 'anthropic', name: 'Claude', message: 'expired')]),
    ]);
    expect(noModels, findsOneWidget, reason: 'another provider failing says nothing about this one');
    expect(failed, findsNothing);
  });

  testWidgets('this subscription failing inside the catalog is an error, not "no models"', (tester) async {
    await pumpPage(tester, [
      _catalog(
        groups: const [],
        failures: const [(provider: 'openai-codex', name: 'ChatGPT', message: 'token expired')],
      ),
    ]);
    expect(noModels, findsNothing);
    expect(failed, findsOneWidget);
    expect(retry, findsOneWidget);
    expect(find.textContaining('token expired'), findsNothing, reason: 'the engine’s own text stays out');
  });

  testWidgets('a refresh that fails keeps the models it had, marked as not updated', (tester) async {
    await pumpPage(tester, [_catalog(), StateError('unavailable')]);
    expect(find.text('模型 · 2'), findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(SubscriptionPage)));
    container.invalidate(modelCatalogProvider);
    await settle(tester);
    expect(container.read(modelCatalogProvider).hasError, isTrue);
    expect(find.text('GPT-5.1 Codex'), findsOneWidget);
    expect(find.text('模型 · 2 · ${appL10n.readListFailed}'), findsOneWidget);
  });

  testWidgets('a refresh that fails where there were none is an error, not "no models"', (tester) async {
    await pumpPage(tester, [_catalog(groups: const []), StateError('unavailable')]);
    expect(noModels, findsOneWidget);
    final container = ProviderScope.containerOf(tester.element(find.byType(SubscriptionPage)));
    container.invalidate(modelCatalogProvider);
    await settle(tester);
    expect(noModels, findsNothing);
    expect(failed, findsOneWidget);
  });

  testWidgets('not connected is not "no models"', (tester) async {
    await pumpPage(tester, [null]);
    expect(noModels, findsNothing);
    expect(find.text(appL10n.commonEngineUnreachable), findsOneWidget);
  });
}
