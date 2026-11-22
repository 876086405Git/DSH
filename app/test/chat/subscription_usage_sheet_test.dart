import 'dart:async';

import 'package:dsh_app/state/balance_state.dart';
import 'package:dsh_app/state/subscriptions_state.dart';
import 'package:dsh_app/state/usage_state.dart';
import 'package:dsh_app/ui/chat/balance_widgets.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _subscription = Subscription.chatgpt;
const _model = ModelSelection(provider: 'openai-codex', model: 'test-model');
const _profile = ProviderProfile(route: 'openai-codex', displayName: 'ChatGPT');
const _usage = SubscriptionUsage(
  status: SubscriptionUsageStatus.ok,
  windows: [
    SubscriptionUsageWindow(id: 'primary', usedPercent: 25, windowSeconds: 18000),
    SubscriptionUsageWindow(id: 'secondary', usedPercent: 75, windowSeconds: 604800),
  ],
);

class _FakeBalanceController extends BalanceController {
  @override
  BalanceState build() => const BalanceState(status: BalanceStatus.noKey);

  @override
  Future<void> refresh() async {}
}

void main() {
  testWidgets('OAuth usage replaces DeepSeek balance and labels reported windows', (tester) async {
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: UsageSheet(sessionId: 's', model: _model),
        ),
        overrides: [
          sessionUsageProvider.overrideWith2((id) => FakeUsage(id, SessionUsage.empty)),
          balanceProvider.overrideWith(_FakeBalanceController.new),
          subscriptionProfileProvider(_subscription).overrideWith((ref) async => _profile),
          subscriptionUsageProvider(_subscription).overrideWith((ref) async => _usage),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BalanceCard), findsNothing);
    expect(find.text('Codex · 订阅额度'), findsOneWidget);
    expect(find.text('5 小时'), findsOneWidget);
    expect(find.text('7 天'), findsOneWidget);
    expect(find.text('已使用 25%'), findsOneWidget);
    expect(find.text('已使用 75%'), findsOneWidget);
  });

  testWidgets('official OpenAI does not request Codex or official quota, or show DeepSeek balance', (tester) async {
    var profileReads = 0;
    var quotaReads = 0;
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: UsageSheet(sessionId: 's', model: ModelSelection(provider: 'openai-siwc', model: 'test-model')),
        ),
        overrides: [
          sessionUsageProvider.overrideWith2((id) => FakeUsage(id, SessionUsage.empty)),
          balanceProvider.overrideWith(_FakeBalanceController.new),
          for (final subscription in [Subscription.chatgptOfficial, Subscription.chatgpt]) ...[
            subscriptionProfileProvider(subscription).overrideWith((ref) async {
              profileReads++;
              return ProviderProfile(route: subscription.wire);
            }),
            subscriptionUsageProvider(subscription).overrideWith((ref) async {
              quotaReads++;
              return _usage;
            }),
          ],
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BalanceCard), findsNothing);
    expect(find.textContaining('订阅额度'), findsNothing);
    expect(profileReads, 0);
    expect(quotaReads, 0);
  });

  testWidgets('same-named API key route uses DeepSeek balance, not OAuth quota', (tester) async {
    var requests = 0;
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: UsageSheet(sessionId: 's', model: _model),
        ),
        overrides: [
          sessionUsageProvider.overrideWith2((id) => FakeUsage(id, SessionUsage.empty)),
          balanceProvider.overrideWith(_FakeBalanceController.new),
          subscriptionProfileProvider(_subscription).overrideWith(
            (ref) async => const ProviderProfile(route: 'openai-codex', displayName: 'Key', apiKeyEnv: 'TEST_KEY'),
          ),
          subscriptionUsageProvider(_subscription).overrideWith((ref) async {
            requests++;
            return _usage;
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BalanceCard), findsOneWidget);
    expect(find.text('Codex · 订阅额度'), findsNothing);
    expect(requests, 0);
  });

  testWidgets('refresh disables button and discards stale values on failure', (tester) async {
    final pending = Completer<SubscriptionUsage?>();
    var requests = 0;
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: UsageSheet(sessionId: 's', model: _model),
        ),
        overrides: [
          sessionUsageProvider.overrideWith2((id) => FakeUsage(id, SessionUsage.empty)),
          balanceProvider.overrideWith(_FakeBalanceController.new),
          subscriptionProfileProvider(_subscription).overrideWith((ref) async => _profile),
          subscriptionUsageProvider(_subscription).overrideWith((ref) {
            requests++;
            return requests == 1 ? Future.value(_usage) : pending.future;
          }),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已使用 25%'), findsOneWidget);
    await tester.ensureVisible(find.text('刷新额度'));
    await tester.tap(find.text('刷新额度'));
    await tester.pump();
    expect(find.text('正在查询订阅额度…'), findsOneWidget);
    expect(find.text('已使用 25%'), findsNothing);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '刷新额度')).onPressed, isNull);
    pending.complete(const SubscriptionUsage(status: SubscriptionUsageStatus.unavailable, reason: 'permission_denied'));
    await tester.pumpAndSettle();
    expect(find.text('订阅没有权限查询额度'), findsOneWidget);
    expect(find.text('已使用 0%'), findsNothing);
    expect(find.text('已使用 25%'), findsNothing);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '刷新额度')).onPressed, isNotNull);
  });
}
