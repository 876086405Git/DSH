import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/account_state.dart' show accountBrowserProvider;
import 'package:dsh_app/state/subscriptions_state.dart';
import 'package:dsh_app/ui/providers/subscription_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../account/support.dart' show FakeBrowser;
import '../shell/golden_harness.dart' show goldenApp;
import 'support.dart';

const _a = 'https://auth.example.com/authorize?state=first';
const _b = 'https://auth.example.com/authorize?state=second';

class _Backend extends FakeSubscriptionBackend {
  _Backend(this.now)
    : super(
        steps: const [
          LoginStep(phase: LoginPhase.open, url: _a),
          LoginStep(phase: LoginPhase.failed),
        ],
      );

  final DateTime Function() now;
  final starts = <Future<String>>[];
  final reads = <Future<LoginStep>>[];
  final cancellations = <Future<void>>[];
  final pollTimes = <DateTime>[];

  @override
  Future<String> begin(Subscription subscription, {bool newAccount = false}) {
    final operation = super.begin(subscription, newAccount: newAccount);
    starts.add(operation);
    return operation;
  }

  @override
  Future<LoginStep> poll(String attemptId) {
    pollTimes.add(now());
    final operation = super.poll(attemptId);
    reads.add(operation);
    return operation;
  }

  @override
  Future<void> cancel(String attemptId) {
    final operation = super.cancel(attemptId);
    cancellations.add(operation);
    return operation;
  }

  Future<void> joinStarted() async {
    for (final operation in starts) {
      await operation;
    }
    for (final operation in reads) {
      await operation;
    }
    for (final operation in cancellations) {
      await operation;
    }
  }
}

class _Opener extends StatefulWidget {
  const _Opener();

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  String result = 'none';

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Text('result: $result'),
        TextButton(
          onPressed: () async {
            final result = await showSubscriptionLogin(context, Subscription.chatgpt);
            setState(() => this.result = '$result');
          },
          child: const Text('open'),
        ),
      ],
    ),
  );
}

void main() {
  for (final expireFirst in [false, true]) {
    testWidgets('copied feedback belongs to the retried URL; expire first: $expireFirst', (tester) async {
      final backend = _Backend(tester.binding.clock.now);
      final browser = FakeBrowser();
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(780, 1800);
      tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
      var routeOpened = false;
      try {
        await tester.pumpWidget(
          goldenApp(
            home: const _Opener(),
            brightness: Brightness.light,
            overrides: [
              ...providerOverrides(FakeProviderBackend(), subscriptions: backend),
              accountBrowserProvider.overrideWithValue(browser),
            ],
          ),
        );
        await settle(tester);
        await tester.tap(find.text('open'));
        routeOpened = true;
        await settle(tester);
        expect(backend.calls.where((c) => c.startsWith('begin:')), ['begin:openai-codex']);
        expect(backend.calls.where((c) => c.startsWith('poll:')), ['poll:att-1']);
        expect(browser.opened, [Uri.parse(_a)]);
        expect(
          tester.widget<SubscriptionLoginSheet>(find.byType(SubscriptionLoginSheet)).interval,
          const Duration(seconds: 1),
        );

        final beforeCopy = tester.binding.clock.now();
        await tester.tap(find.text(appL10n.commonCopyLink).hitTestable());
        await tester.pump();
        expect(tester.binding.clock.now(), beforeCopy, reason: 'copy completion did not advance virtual time');
        expect(copied, [_a]);
        expect(find.text(appL10n.commonCopied), findsOneWidget);
        final copiedAt = tester.binding.clock.now();
        final untilPoll = backend.pollTimes.single.add(const Duration(seconds: 1)).difference(copiedAt);
        expect(untilPoll, greaterThan(Duration.zero), reason: 'the normal next poll has not happened yet');
        expect(untilPoll, lessThan(const Duration(milliseconds: 1500)));
        await tester.pump(untilPoll);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(backend.calls.where((c) => c.startsWith('poll:')), ['poll:att-1', 'poll:att-1']);
        expect(find.byKey(const ValueKey('open')), findsNothing, reason: 'the old open body has left the switcher');
        expect(find.byKey(const ValueKey('failed')), findsOneWidget);
        final retry = find.text(appL10n.engineSubscriptionTryAgain).hitTestable();
        expect(retry, findsOneWidget);
        if (expireFirst) {
          final remaining = copiedAt.add(const Duration(milliseconds: 1500)).difference(tester.binding.clock.now());
          expect(remaining, greaterThan(Duration.zero));
          await tester.pump(remaining);
        }
        backend.steps = const [LoginStep(phase: LoginPhase.open, url: _b)];
        await tester.tap(retry);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(backend.calls.where((c) => c.startsWith('begin:')), ['begin:openai-codex', 'begin:openai-codex']);
        expect(backend.calls.where((c) => c.startsWith('poll:')), ['poll:att-1', 'poll:att-1', 'poll:att-2']);
        expect(browser.opened, [Uri.parse(_a), Uri.parse(_b)]);
        expect(find.byKey(const ValueKey('failed')), findsNothing);
        final current = find.byKey(const ValueKey('open'));
        expect(current, findsOneWidget);
        final elapsed = tester.binding.clock.now().difference(copiedAt);
        if (expireFirst) {
          expect(elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 1500)));
        } else {
          expect(
            elapsed,
            lessThan(const Duration(milliseconds: 1500)),
            reason: 'the original feedback timer is still pending',
          );
        }
        expect(copied, [_a], reason: 'only the actual platform setData(A) call has happened');
        final buttons = find.descendant(of: current, matching: find.byType(OutlinedButton));
        expect(buttons, findsNWidgets(2));
        final copyButton = buttons.last;
        expect(copyButton.hitTestable(), findsOneWidget, reason: 'the current B button is available');
        expect(find.descendant(of: copyButton, matching: find.text(appL10n.commonCopyLink)), findsOneWidget);
        expect(find.descendant(of: copyButton, matching: find.text(appL10n.commonCopied)), findsNothing);
      } finally {
        try {
          if (routeOpened && find.byType(SubscriptionLoginSheet).evaluate().isNotEmpty) {
            await tester.tap(find.byTooltip(appL10n.commonClose).hitTestable());
            await settle(tester);
            expect(find.byType(SubscriptionLoginSheet), findsNothing);
            expect(
              find.text('result: false'),
              findsOneWidget,
              reason: 'the mounted opener has completed its continuation',
            );
          }
        } finally {
          try {
            await backend.joinStarted();
            if (backend.starts.length == 2) {
              expect(backend.calls.where((c) => c.startsWith('cancel:')), ['cancel:att-2']);
            }
          } finally {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            tester.view.reset();
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
          }
        }
      }
    });
  }
}
