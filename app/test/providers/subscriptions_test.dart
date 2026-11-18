// ChatGPT / Claude sign-in: the 「订阅」 rows (hidden without the bridge), each
// step of the sign-in sheet against a fake bridge, polling that stops with
// the sheet, and the signed-in page's sign-out.

import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/account_state.dart' show accountBrowserProvider;
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/subscriptions_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/providers/providers_page.dart';
import 'package:dsh_app/ui/providers/subscription_page.dart';
import 'package:dsh_app/ui/providers/subscription_sheet.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../clipboard/fake_paste.dart';
import '../account/support.dart' show FakeBrowser;
import '../shell/golden_harness.dart' show goldenApp, loadGoldenFonts;
import 'support.dart';

const _url = 'https://auth.example.com/oauth/authorize?state=abc';

const _signedInChatGpt = [
  SubscriptionStatus(subscription: Subscription.chatgpt, signedIn: true, account: 'me@example.com'),
  SubscriptionStatus(subscription: Subscription.claude, signedIn: false),
];

final _codexCatalog = ModelCatalog(
  defaultSelection: null,
  routableProviders: const ['openai-codex'],
  groups: const [
    ProviderGroup('openai-codex', 'ChatGPT', [
      ModelInfo(provider: 'openai-codex', id: 'gpt-5.1-codex', name: 'GPT-5.1 Codex'),
      ModelInfo(provider: 'openai-codex', id: 'gpt-5.1', name: 'gpt-5.1'),
    ]),
  ],
  failures: const [],
);

/// A page with one button that opens the sign-in sheet and shows its result.
class _Opener extends StatefulWidget {
  const _Opener();

  @override
  State<_Opener> createState() => _OpenerState();
}

class _OpenerState extends State<_Opener> {
  String result = 'none';

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('result: $result'),
          TextButton(
            onPressed: () async {
              final ok = await showSubscriptionLogin(context, Subscription.chatgpt);
              setState(() => result = '$ok');
            },
            child: const Text('open'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _pump(WidgetTester tester, Widget home, List<Override> overrides, {double height = 900}) async {
  await tester.runAsync(loadGoldenFonts);
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(390 * 2, height * 2);
  tester.view.padding = const FakeViewPadding(top: 64, bottom: 48);
  tester.view.viewPadding = const FakeViewPadding(top: 64, bottom: 48);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(goldenApp(home: home, brightness: Brightness.light, overrides: overrides));
  await settle(tester);
}

/// Opens the sheet against [bridge]; returns the browser fake.
Future<FakeBrowser> _openSheet(WidgetTester tester, FakeSubscriptionBackend bridge, {String? os}) async {
  final browser = FakeBrowser();
  await _pump(tester, const _Opener(), [
    if (os != null) operatingSystemProvider.overrideWithValue(os),
    ...providerOverrides(FakeProviderBackend(), subscriptions: bridge),
    accountBrowserProvider.overrideWithValue(browser),
  ]);
  await tester.tap(find.text('open'));
  await settle(tester);
  return browser;
}

List<String> _mockClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  return copied;
}

void main() {
  group('rows', () {
    testWidgets('signed in shows the account; signed out a 登录 capsule', (tester) async {
      final bridge = FakeSubscriptionBackend(statuses: _signedInChatGpt);
      await _pump(
        tester,
        const ProvidersPage(),
        providerOverrides(
          FakeProviderBackend(
            profiles: const [
              gateway,
              // The bridge's own route: shown as the subscription, not again.
              ProviderProfile(route: 'openai-codex', displayName: 'ChatGPT'),
            ],
            credentials: const {'CUSTOM_MYGW_API_KEY': 'k'},
          ),
          subscriptions: bridge,
        ),
      );
      expect(find.text('订阅'), findsOneWidget);
      expect(find.text('已登录 · me@example.com'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '登录'), findsOneWidget);
      final titles = [
        for (final row in tester.widgetList<ListPageRow>(find.byType(ListPageRow)))
          row.title ?? row.spot?.title(appL10n),
      ];
      expect(titles, [appL10n.viewModelSelect, 'DeepSeek', 'ChatGPT', 'Claude', 'My Gateway', '添加渠道']);
      // Plain letters, no brand marks: 「G」 and 「C」.
      expect(find.text('G'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
    });

    testWidgets('no bridge on the engine: no rows, no gap', (tester) async {
      await _pump(
        tester,
        const ProvidersPage(),
        providerOverrides(FakeProviderBackend(), subscriptions: FakeSubscriptionBackend(available: false)),
      );
      expect(find.text('订阅'), findsNothing);
      expect(find.text('ChatGPT'), findsNothing);
      expect(find.text('Claude'), findsNothing);
    });

    testWidgets('the 登录 capsule ends 16 in, centred on the row', (tester) async {
      await _pump(
        tester,
        const ProvidersPage(),
        providerOverrides(FakeProviderBackend(), subscriptions: FakeSubscriptionBackend()),
      );
      final row = tester.getRect(find.widgetWithText(ListPageRow, 'Claude'));
      final card = tester.getRect(find.ancestor(of: find.text('Claude'), matching: find.byType(Material)).first);
      final capsule = tester.getRect(find.widgetWithText(FilledButton, '登录').last);
      expect(card.right - capsule.right, moreOrLessEquals(16, epsilon: 0.6));
      expect(capsule.center.dy, moreOrLessEquals(row.center.dy, epsilon: 0.6));
      expect(capsule.height, moreOrLessEquals(LoginCapsule.height, epsilon: 0.6));
      expect(row.height, moreOrLessEquals(52, epsilon: 0.6));
    });
  });

  group('sheet', () {
    testWidgets('open: the browser opens once, polling every second, reopen and copy', (tester) async {
      final copied = _mockClipboard(tester);
      final bridge = FakeSubscriptionBackend(
        steps: const [LoginStep(phase: LoginPhase.open, url: _url)],
      );
      final browser = await _openSheet(tester, bridge);
      expect(find.text('登录 ChatGPT'), findsOneWidget);
      expect(find.text('在浏览器中完成登录'), findsOneWidget);
      expect(bridge.calls.first, 'begin:openai-codex');
      expect(browser.opened, [Uri.parse(_url)]);

      final before = bridge.polls;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(bridge.polls, before + 2);
      expect(browser.opened, hasLength(1), reason: 'the same URL is not reopened by itself');

      await tester.tap(find.text('重新打开'));
      await tester.pump();
      expect(browser.opened, hasLength(2));
      await tester.tap(find.text('复制链接'));
      await tester.pump();
      expect(copied, [_url]);
      expect(find.text('已复制'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('复制链接'), findsOneWidget);

      // Closing stops polling and cancels the attempt.
      await tester.tap(find.byTooltip('关闭'));
      await settle(tester);
      expect(bridge.calls, contains('cancel:att-1'));
      final after = bridge.polls;
      await tester.pump(const Duration(seconds: 3));
      expect(bridge.polls, after);
      expect(find.text('result: false'), findsOneWidget);
    });

    testWidgets('open: the waiting line is centred as one unit; the buttons mirror', (tester) async {
      await _openSheet(
        tester,
        FakeSubscriptionBackend(
          steps: const [LoginStep(phase: LoginPhase.open, url: _url)],
        ),
      );
      final sheet = tester.getRect(find.byType(SubscriptionLoginSheet));
      final title = tester.getRect(find.text('在浏览器中完成登录'));
      final spinner = tester.getRect(
        find.descendant(of: find.byType(SubscriptionLoginSheet), matching: find.byType(CircularProgressIndicator)),
      );
      final text = tester.getRect(find.text('等待登录…'));
      final unitCentre = (spinner.left + text.right) / 2;
      expect(unitCentre, moreOrLessEquals(sheet.center.dx, epsilon: 0.6));
      expect(title.center.dx, moreOrLessEquals(sheet.center.dx, epsilon: 0.6));
      expect(spinner.center.dy, moreOrLessEquals(text.center.dy, epsilon: 1));
      final reopen = tester.getRect(find.widgetWithText(OutlinedButton, '重新打开'));
      final copy = tester.getRect(find.widgetWithText(OutlinedButton, '复制链接'));
      expect(reopen.width, moreOrLessEquals(copy.width, epsilon: 0.6));
      expect(reopen.left - sheet.left, moreOrLessEquals(20, epsilon: 0.6));
      expect(sheet.right - copy.right, moreOrLessEquals(20, epsilon: 0.6));
      expect(reopen.top, moreOrLessEquals(copy.top, epsilon: 0.6));
      expect(reopen.height, 48);
      expect(copy.height, 48);
      expect(copy.left - reopen.right, 12);
    });

    testWidgets('a browser that cannot open says so in place', (tester) async {
      final bridge = FakeSubscriptionBackend(
        steps: const [LoginStep(phase: LoginPhase.open, url: _url)],
      );
      final browser = FakeBrowser(succeeds: false);
      await _pump(tester, const _Opener(), [
        ...providerOverrides(FakeProviderBackend(), subscriptions: bridge),
        accountBrowserProvider.overrideWithValue(browser),
      ]);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('没能打开浏览器'), findsOneWidget);
    });

    testWidgets('device: the code, copy it, open the verification page', (tester) async {
      final copied = _mockClipboard(tester);
      final bridge = FakeSubscriptionBackend(
        steps: const [
          LoginStep(phase: LoginPhase.device, url: 'https://auth.example.com/device', userCode: 'WDJB-MJHT'),
        ],
      );
      final browser = await _openSheet(tester, bridge);
      expect(find.text('WDJB-MJHT'), findsOneWidget);
      expect(browser.opened, isEmpty, reason: 'the code comes first');
      await tester.tap(find.text('复制验证码'));
      await tester.pump();
      expect(copied, ['WDJB-MJHT']);
      await tester.tap(find.text('打开验证页'));
      await tester.pump();
      expect(browser.opened, [Uri.parse('https://auth.example.com/device')]);
    });

    testWidgets('prompt: paste, 确定 answers, then done closes the sheet and refreshes', (tester) async {
      final bridge = FakeSubscriptionBackend(
        steps: const [
          LoginStep(phase: LoginPhase.prompt, message: 'Paste the authorization code', placeholder: 'code#state'),
          LoginStep(phase: LoginPhase.done),
        ],
      );
      await _openSheet(tester, bridge);
      expect(find.text('粘贴授权码'), findsOneWidget);
      expect(find.text('Paste the authorization code'), findsNothing, reason: 'flow text shows only when localized');
      expect(promptTitle('Paste the redirect URL'), '粘贴跳转后的链接');
      expect(promptTitle(null), '粘贴授权码');
      final ok = find.widgetWithText(FilledButton, '确定');
      expect(tester.widget<FilledButton>(ok).onPressed, isNull, reason: 'nothing to send yet');
      await tester.enterText(find.byType(TextField), '  abc#xyz ');
      await tester.pump();
      await tester.tap(ok);
      await settle(tester);
      expect(bridge.calls, contains('answer:att-1:abc#xyz'));
      expect(find.text('已登录'), findsOneWidget);
      await tester.pump(SubscriptionLoginSheet.doneDwell);
      await settle(tester);
      expect(find.byType(SubscriptionLoginSheet), findsNothing);
      expect(find.text('result: true'), findsOneWidget);
      expect(bridge.calls, isNot(contains('cancel:att-1')), reason: 'a finished attempt is not cancelled');
    });

    group('prompt 粘贴', () {
      const prompt = [LoginStep(phase: LoginPhase.prompt, message: 'Paste the authorization code')];

      String field(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

      testWidgets('Android: Flutter\'s clipboard, trimmed, only filled in', (tester) async {
        final paste = FakePaste(tester, flutterText: '  abc#xyz ');
        final bridge = FakeSubscriptionBackend(steps: prompt);
        await _openSheet(tester, bridge);
        await tester.tap(find.byTooltip('粘贴'));
        await settle(tester);
        expect(field(tester), 'abc#xyz');
        expect(paste.flutterReads, 1);
        expect(paste.reads, isEmpty);
        expect(bridge.calls.where((call) => call.startsWith('answer')), isEmpty);
      });

      testWidgets('HarmonyOS: the system paste button, trimmed, only filled in', (tester) async {
        final paste = FakePaste(tester, reply: FakePaste.text('  abc#xyz '), flutterText: 'wrong');
        final bridge = FakeSubscriptionBackend(steps: prompt);
        await _openSheet(tester, bridge, os: 'ohos');
        await tester.tap(find.byTooltip('粘贴'));
        await settle(tester);
        expect(field(tester), 'abc#xyz');
        expect(paste.flutterReads, 0);
        expect(bridge.calls.where((call) => call.startsWith('answer')), isEmpty);
      });

      testWidgets('HarmonyOS: a failure shows on the field the sheet covers no notice of, until it changes', (
        tester,
      ) async {
        FakePaste(tester, reply: {'status': 'busy'});
        await _openSheet(tester, FakeSubscriptionBackend(steps: prompt), os: 'ohos');
        await tester.tap(find.byTooltip('粘贴'));
        await settle(tester);
        const text = '粘贴窗口尚未结束或仍在关闭，请完成或取消后重试。';
        expect(find.text(text), findsOneWidget);
        await tester.enterText(find.byType(TextField), 'a');
        await settle(tester);
        expect(find.text(text), findsNothing);
      });

      testWidgets('HarmonyOS: backed out of, nothing is said', (tester) async {
        FakePaste(tester, reply: {'status': 'cancelled'});
        await _openSheet(tester, FakeSubscriptionBackend(steps: prompt), os: 'ohos');
        await tester.tap(find.byTooltip('粘贴'));
        await settle(tester);
        expect(field(tester), isEmpty);
        expect(tester.widget<TextField>(find.byType(TextField)).decoration!.errorText, isNull);
      });
    });

    testWidgets('failed: the reason and 再试一次 starts a new attempt', (tester) async {
      final bridge = FakeSubscriptionBackend(
        steps: const [LoginStep(phase: LoginPhase.failed, error: '授权已过期')],
      );
      await _openSheet(tester, bridge);
      expect(find.text('登录没有完成'), findsOneWidget);
      expect(find.text('授权已过期'), findsOneWidget);
      final polls = bridge.polls;
      await tester.pump(const Duration(seconds: 2));
      expect(bridge.polls, polls, reason: 'a finished attempt is not polled');
      bridge.steps = const [LoginStep(phase: LoginPhase.open, url: _url)];
      await tester.tap(find.text('再试一次'));
      await settle(tester);
      expect(bridge.calls.where((c) => c.startsWith('begin')), hasLength(2));
      expect(find.text('在浏览器中完成登录'), findsOneWidget);
    });

    testWidgets('cancelled reads as such; a bridge that refuses to begin fails in place', (tester) async {
      await _openSheet(tester, FakeSubscriptionBackend(steps: const [LoginStep(phase: LoginPhase.cancelled)]));
      expect(find.text('登录已取消'), findsOneWidget);
      expect(find.text('再试一次'), findsOneWidget);
    });

    testWidgets('begin refused', (tester) async {
      final bridge = FakeSubscriptionBackend()
        ..beginError = const DshRemoteException('gateway/internal', 'could not reach https://auth.example.com');
      await _openSheet(tester, bridge);
      expect(find.text('登录没有完成'), findsOneWidget);
      expect(find.text('连不上登录服务，检查网络后重试'), findsOneWidget);
    });
  });

  test('unrecognized login errors use local copy', () {
    expect(describeLoginError(const DshRemoteException('gateway/internal', 'secret raw error')), '没能完成登录，再试一次');
  });

  group('session', () {
    testWidgets('[login-cancel] failed polling is cancelled when the real sheet closes', (tester) async {
      final bridge = _CancellationBridge(failPoll: true);
      try {
        await _openSheet(tester, bridge);
        expect(bridge.calls.where((c) => c.startsWith('begin:')).toList(), ['begin:openai-codex']);
        expect(bridge.calls.where((c) => c.startsWith('poll:')).toList(), ['poll:att-1']);
        await tester.pump(const Duration(seconds: 1));
        expect(bridge.polls, 2);
        await tester.pump(const Duration(seconds: 1));
        expect(bridge.polls, 3);
        expect(find.text('登录没有完成'), findsOneWidget);

        // A local transport failure did not report a terminal Host step.
        // Cancelling as soon as polling is abandoned is also valid.
        await tester.tap(find.byTooltip('关闭'));
        await settle(tester);
        await Future.wait(bridge.cancellations);
        expect(find.byType(SubscriptionLoginSheet), findsNothing);
        expect(find.text('result: false'), findsOneWidget);
        expect(bridge.calls.where((c) => c.startsWith('cancel:')).toList(), ['cancel:att-1']);
        await tester.pump(const Duration(seconds: 3));
        expect(bridge.polls, 3);
      } finally {
        await _closeCancellationSheet(tester, bridge);
      }
    });

    testWidgets('[login-cancel] failed answer is cancelled before the next poll', (tester) async {
      final bridge = _CancellationBridge(
        steps: const [LoginStep(phase: LoginPhase.prompt, message: 'Paste the code')],
        failAnswer: true,
      );
      final session = LoginSession(bridge, Subscription.claude);
      try {
        await session.start();
        expect(session.step.phase, LoginPhase.prompt);
        expect(bridge.calls, ['begin:anthropic', 'poll:att-1']);
        await session.answer('code');
        expect(bridge.calls, contains('answer:att-1:code'));
        expect(session.step.phase, LoginPhase.failed);
        expect(session.answering, isFalse);
        expect(bridge.polls, 1);

        // Do not advance the existing polling timer before this close.
        session.close();
        session.close();
        await Future.wait(bridge.cancellations);
        expect(bridge.calls.where((c) => c.startsWith('cancel:')).toList(), ['cancel:att-1']);
        await tester.pump(const Duration(seconds: 1));
        expect(bridge.polls, 1);
      } finally {
        session.dispose();
        await Future.wait(bridge.cancellations);
      }
    });

    for (final phase in [LoginPhase.done, LoginPhase.failed, LoginPhase.cancelled]) {
      testWidgets('[login-cancel] Host ${phase.name} remains terminal when closing', (tester) async {
        final bridge = _CancellationBridge(steps: [LoginStep(phase: phase)]);
        final session = LoginSession(bridge, Subscription.claude);
        try {
          await session.start();
          expect(session.step.phase, phase);
          expect(bridge.calls, ['begin:anthropic', 'poll:att-1']);
          session.close();
          session.close();
          await Future.wait(bridge.cancellations);
          expect(bridge.calls.where((c) => c.startsWith('cancel:')), isEmpty);
          await tester.pump(const Duration(seconds: 1));
          expect(bridge.polls, 1);
        } finally {
          session.dispose();
          await Future.wait(bridge.cancellations);
        }
      });
    }

    testWidgets('[login-cancel] failed begin has no known attempt to cancel', (tester) async {
      final bridge = _CancellationBridge()..beginError = const DshTransportException('timeout');
      final session = LoginSession(bridge, Subscription.claude);
      try {
        await session.start();
        expect(session.step.phase, LoginPhase.failed);
        expect(bridge.calls, ['begin:anthropic']);
        session.close();
        await Future.wait(bridge.cancellations);
        expect(bridge.calls.where((c) => c.startsWith('cancel:')), isEmpty);
      } finally {
        session.dispose();
        await Future.wait(bridge.cancellations);
      }
    });

    testWidgets('[login-cancel] retry after Host failure cancels only the new attempt', (tester) async {
      final bridge = _CancellationBridge(
        steps: const [LoginStep(phase: LoginPhase.failed, error: '授权已过期')],
      );
      try {
        await _openSheet(tester, bridge);
        expect(find.text('登录没有完成'), findsOneWidget);
        expect(bridge.calls.where((c) => c.startsWith('poll:')).toList(), ['poll:att-1']);
        bridge.steps = const [LoginStep(phase: LoginPhase.open, url: _url)];
        await tester.tap(find.text('再试一次'));
        await settle(tester);
        expect(bridge.calls.where((c) => c.startsWith('begin:')).toList(), [
          'begin:openai-codex',
          'begin:openai-codex',
        ]);
        expect(bridge.calls.where((c) => c.startsWith('poll:')).toList(), ['poll:att-1', 'poll:att-2']);
        expect(find.text('在浏览器中完成登录'), findsOneWidget);
        await tester.tap(find.byTooltip('关闭'));
        await settle(tester);
        await Future.wait(bridge.cancellations);
        expect(find.byType(SubscriptionLoginSheet), findsNothing);
        expect(find.text('result: false'), findsOneWidget);
        expect(bridge.calls.where((c) => c.startsWith('cancel:')).toList(), ['cancel:att-2']);
        final polls = bridge.polls;
        await tester.pump(const Duration(seconds: 3));
        expect(bridge.polls, polls);
      } finally {
        await _closeCancellationSheet(tester, bridge);
      }
    });

    testWidgets('[login-cancel] retry after local failure still cancels when begin fails', (tester) async {
      final bridge = _CancellationBridge(failPoll: true);
      final session = LoginSession(bridge, Subscription.claude);
      try {
        await session.start();
        expect(bridge.calls, ['begin:anthropic', 'poll:att-1']);
        await tester.pump(const Duration(seconds: 1));
        expect(bridge.polls, 2);
        await tester.pump(const Duration(seconds: 1));
        expect(bridge.polls, 3);
        expect(session.step.phase, LoginPhase.failed);

        bridge.beginError = const DshRemoteException('gateway/internal', 'could not reach https://auth.example.com');
        await session.start();
        expect(bridge.calls.where((c) => c.startsWith('begin:')).toList(), ['begin:anthropic', 'begin:anthropic']);
        expect(session.step.phase, LoginPhase.failed);
        session.close();
        session.close();
        await Future.wait(bridge.cancellations);
        expect(bridge.calls.where((c) => c.startsWith('cancel:')).toList(), ['cancel:att-1']);
        await tester.pump(const Duration(seconds: 1));
        expect(bridge.polls, 3);
      } finally {
        session.dispose();
        await Future.wait(bridge.cancellations);
      }
    });

    test('three failed polls in a row give up; one recovers', () async {
      final bridge = _FlakyBridge(failures: 3);
      final session = LoginSession(bridge, Subscription.claude, interval: Duration.zero);
      await session.start();
      for (var i = 0; i < 10 && !session.step.phase.finished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(session.step.phase, LoginPhase.failed);
      session.dispose();

      final flaky = _FlakyBridge(failures: 1);
      final ok = LoginSession(flaky, Subscription.claude, interval: Duration.zero);
      await ok.start();
      for (var i = 0; i < 10 && !ok.step.phase.finished; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(ok.step.phase, LoginPhase.done);
      ok.dispose();
    });
  });

  group('signed-in page', () {
    testWidgets('account, the models it brings, sign out with a confirm', (tester) async {
      final bridge = FakeSubscriptionBackend(statuses: [..._signedInChatGpt]);
      await _pump(tester, const _PageOpener(), [
        ...providerOverrides(FakeProviderBackend(), subscriptions: bridge),
        modelCatalogProvider.overrideWith((ref) async => _codexCatalog),
      ]);
      await tester.tap(find.text('open'));
      await settle(tester);
      expect(find.text('me@example.com'), findsOneWidget);
      expect(find.text('模型 · 2'), findsOneWidget);
      expect(find.text('GPT-5.1 Codex'), findsOneWidget);
      expect(find.text('gpt-5.1-codex'), findsOneWidget);

      await tester.tap(find.text('退出登录'));
      await settle(tester);
      expect(find.text('退出 ChatGPT？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(bridge.calls, isNot(contains('signOut:openai-codex')));

      await tester.tap(find.text('退出登录'));
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, '退出登录'));
      await settle(tester);
      expect(bridge.calls, contains('signOut:openai-codex'));
      expect(find.byType(SubscriptionPage), findsNothing);
    });
  });
}

class _PageOpener extends StatelessWidget {
  const _PageOpener();

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const SubscriptionPage(subscription: Subscription.chatgpt))),
        child: const Text('open'),
      ),
    ),
  );
}

/// Polls fail [failures] times, then the attempt is done.
class _FlakyBridge extends FakeSubscriptionBackend {
  _FlakyBridge({required this.failures});

  int failures;

  @override
  Future<LoginStep> poll(String attemptId) async {
    if (failures-- > 0) throw const DshTransportException('timeout');
    return const LoginStep(phase: LoginPhase.done);
  }
}

/// The existing backend seam, with only ordinary transport errors added.
class _CancellationBridge extends FakeSubscriptionBackend {
  _CancellationBridge({super.steps, this.failPoll = false, this.failAnswer = false});

  final bool failPoll;
  final bool failAnswer;
  final cancellations = <Future<void>>[];

  @override
  Future<LoginStep> poll(String attemptId) async {
    if (!failPoll) return super.poll(attemptId);
    calls.add('poll:$attemptId');
    throw const DshTransportException('timeout');
  }

  @override
  Future<void> answer(String attemptId, String value) async {
    await super.answer(attemptId, value);
    if (failAnswer) throw const DshTransportException('timeout');
  }

  @override
  Future<void> cancel(String attemptId) {
    final cancellation = super.cancel(attemptId);
    cancellations.add(cancellation);
    return cancellation;
  }
}

Future<void> _closeCancellationSheet(WidgetTester tester, _CancellationBridge bridge) async {
  if (find.byType(SubscriptionLoginSheet).evaluate().isNotEmpty) {
    await tester.tap(find.byTooltip('关闭'));
    await settle(tester);
  }
  await Future.wait(bridge.cancellations);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}
