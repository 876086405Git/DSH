// 「我的分享链接」: copy, delete with confirm + undo, empty state, row
// geometry, and light / dark goldens. Regenerate the goldens with
// `flutter test --update-goldens test/share_hosted/hosted_links_page_test.dart`.

import 'package:dsh_app/share_hosted/hosted_client.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/share_hosted/hosted_crypto.dart';
import 'package:dsh_app/share_hosted/hosted_link.dart';
import 'package:dsh_app/share_hosted/hosted_links_state.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/share_hosted/hosted_links_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';
import '../secrets/hosted_storage_recovery_test.dart' show FaultStorage;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dsh_app/l10n/l10n.dart';

import '../support/english_preview.dart' show useEnglish, inEnglish;
import 'hosted_client_test.dart' show FakeHost;
import 'hosted_links_state_test.dart' show MemoryStore;

final _now = DateTime(2026, 10, 25, 12);

HostedLink _link(String id, String title, {DateTime? expires, HostedTtl ttl = HostedTtl.month}) => HostedLink(
  id: id,
  // Fixed keys: the goldens don't show them, but keep runs identical.
  key: encodeHostedKey(List.generate(32, (i) => (i * 7 + id.codeUnitAt(0)) & 0xff)),
  deleteToken: 'token-$id-0123456789',
  title: title,
  createdAt: DateTime(2026, 10, 20),
  ttl: ttl,
  expiresAt: expires,
  origin: 'https://go.example',
);

final _links = [
  _link('M000000001', '修复登录按钮重复提交', expires: DateTime(2026, 11, 24, 9)),
  _link('A000000002', '给周报写一个自动汇总脚本', expires: DateTime(2026, 10, 26, 9), ttl: HostedTtl.week),
  _link('z000000003', '把 DeepSeek 装进口袋：一次完整的部署记录', ttl: HostedTtl.forever),
  _link('A000000004', '旧的排查记录', expires: DateTime(2026, 10, 20, 9), ttl: HostedTtl.week),
];

Future<(FakeHost, MemoryStore)> _pump(
  WidgetTester tester, {
  List<HostedLink>? links,
  Brightness brightness = Brightness.light,
}) async {
  usePhoneView(tester);
  final host = FakeHost();
  for (final l in links ?? _links) {
    host.blobs[l.id] = Uint8List(40);
    host.tokens[l.id] = l.deleteToken;
  }
  final store = MemoryStore(links ?? _links);
  await tester.pumpWidget(
    testApp(
      HostedLinksPage(clock: () => _now),
      brightness: brightness,
      overrides: [
        hostedLinkStoreProvider.overrideWithValue(store),
        hostedShareClientProvider.overrideWithValue(
          HostedShareClient(client: host.client, origin: 'https://go.example'),
        ),
      ],
    ),
  );
  await pumpFrames(tester, 6);
  return (host, store);
}

void main() {
  for (final english in [false, true]) {
    testWidgets('read retry and failed delete are visible (${english ? "en" : "zh"})', (tester) async {
      if (english) useEnglish();
      usePhoneView(tester);
      final storage = FaultStorage([_links.first])..readError = PlatformException(code: 'locked');
      await tester.pumpWidget(
        testApp(
          english ? inEnglish(const HostedLinksPage()) : const HostedLinksPage(),
          overrides: [
            operatingSystemProvider.overrideWithValue('ohos'),
            hostedLinkStoreProvider.overrideWithValue(SecureHostedLinkStore(storage)),
          ],
        ),
      );
      await pumpFrames(tester, 6);
      expect(find.text(appL10n.remoteHostedLoadFailed), findsOneWidget);
      storage.readError = null;
      await tester.tap(find.text(appL10n.commonRetry));
      await pumpFrames(tester, 6);
      expect(find.text(_links.first.title), findsOneWidget);
      storage.writeError = PlatformException(code: 'locked');
      await tester.tap(find.byKey(const ValueKey('hosted-delete-M000000001')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, appL10n.commonDelete));
      await pumpFrames(tester, 6);
      expect(find.text(_links.first.title), findsOneWidget);
      expect(find.text(appL10n.remoteHostedDeleteSaveFailed), findsOneWidget);
      expect(find.text(appL10n.remoteHostedLinkDeleted), findsNothing);
    });
  }
  testWidgets('opening the page retries a prior read failure without losing unsaved links on re-open', (tester) async {
    usePhoneView(tester);
    final storage = FaultStorage([_links.first])..readError = PlatformException(code: 'locked');
    final container = ProviderContainer(
      overrides: [
        operatingSystemProvider.overrideWithValue('ohos'),
        hostedLinkStoreProvider.overrideWithValue(SecureHostedLinkStore(storage)),
      ],
    );
    addTearDown(container.dispose);
    final links = container.read(hostedLinksProvider.notifier);
    await links.ready;
    storage.readError = null;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(HostedLinksPage(clock: () => _now)),
      ),
    );
    await pumpFrames(tester, 6);
    expect(find.text(_links.first.title), findsOneWidget);
    storage.writeError = PlatformException(code: 'locked');
    await links.add(_links[1]);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: testApp(HostedLinksPage(clock: () => _now)),
      ),
    );
    await pumpFrames(tester, 6);
    expect(find.text(_links[1].title), findsOneWidget);
    expect(find.textContaining('尚未保存'), findsOneWidget);
  });
  testWidgets('undo save failure restores the row and warns about restart instead of deleting', (tester) async {
    usePhoneView(tester);
    final storage = FaultStorage([_links.first]);
    final host = FakeHost();
    await tester.pumpWidget(
      testApp(
        const HostedLinksPage(),
        overrides: [
          operatingSystemProvider.overrideWithValue('ohos'),
          hostedLinkStoreProvider.overrideWithValue(SecureHostedLinkStore(storage)),
          hostedShareClientProvider.overrideWithValue(
            HostedShareClient(client: host.client, origin: 'https://go.example'),
          ),
        ],
      ),
    );
    await pumpFrames(tester, 6);
    await tester.tap(find.byKey(const ValueKey('hosted-delete-M000000001')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, appL10n.commonDelete));
    await pumpFrames(tester, 3);
    storage.writeError = PlatformException(code: 'locked');
    await tester.tap(find.text(appL10n.remoteUndo));
    await tester.pumpAndSettle();
    expect(find.text(_links.first.title), findsOneWidget);
    expect(find.text(appL10n.remoteHostedUndoUnsaved), findsOneWidget);
    await tester.pump(HostedLinksController.undoWindow + const Duration(seconds: 1));
    expect(host.requests, isEmpty);
  });
  test('expiry wording', () {
    expect(hostedExpiryText(_links[0], _now), '11 月 24 日到期');
    expect(hostedExpiryText(_links[1], _now), '明天到期');
    expect(hostedExpiryText(_links[2], _now), '永久有效');
    expect(hostedExpiryText(_links[3], _now), '已过期');
    expect(hostedExpiryText(_link('A000000005', 't', expires: DateTime(2026, 10, 25, 20)), _now), '今天到期');
    expect(hostedExpiryText(_link('M000000006', 't', expires: DateTime(2027, 1, 3, 9)), _now), '2027 年 1 月 3 日到期');
  });

  testWidgets('lists every link with its expiry', (tester) async {
    await _pump(tester);
    expect(find.text('我的分享链接'), findsWidgets);
    for (final l in _links) {
      expect(find.text(l.title), findsOneWidget);
    }
    expect(find.text('11 月 24 日到期'), findsOneWidget);
    expect(find.text('永久有效'), findsOneWidget);
    expect(find.text('已过期'), findsOneWidget);
    // An expired link can't be copied, only removed.
    final copyExpired = tester.widget<IconButton>(find.byKey(const ValueKey('hosted-copy-A000000004')));
    expect(copyExpired.onPressed, isNull);
  });

  testWidgets('copy puts the full link, key included, on the clipboard', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('hosted-copy-M000000001')));
    await tester.pump();
    expect(copied, _links[0].url);
    expect(copied, contains('#k='));
    expect(find.text('已复制链接'), findsOneWidget);
  });

  testWidgets('delete asks, can be undone, then removes it from the host', (tester) async {
    final (host, store) = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('hosted-delete-M000000001')));
    await tester.pumpAndSettle();
    expect(find.text('删除这个链接？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text(_links[0].title), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('hosted-delete-M000000001')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await pumpFrames(tester, 3);
    expect(find.text(_links[0].title), findsNothing);
    expect(find.text('已删除链接'), findsOneWidget);
    await tester.tap(find.text('撤销'));
    await pumpFrames(tester, 3);
    expect(find.text(_links[0].title), findsOneWidget);
    await tester.pump(HostedLinksController.undoWindow + const Duration(seconds: 1));
    expect(host.blobs, contains('M000000001'));

    await tester.tap(find.byKey(const ValueKey('hosted-delete-M000000001')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump(HostedLinksController.undoWindow + const Duration(milliseconds: 50));
    await pumpFrames(tester, 3);
    expect(host.blobs, isNot(contains('M000000001')));
    expect(store.saved.map((l) => l.id), isNot(contains('M000000001')));
    expect(find.text(_links[0].title), findsNothing);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a failed delete brings the link back with a short note', (tester) async {
    final (host, _) = await _pump(tester);
    host.failWith = 503;
    await tester.tap(find.byKey(const ValueKey('hosted-delete-z000000003')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump();
    await tester.pump(HostedLinksController.undoWindow + const Duration(milliseconds: 50));
    await pumpFrames(tester, 3);
    expect(find.text(_links[2].title), findsOneWidget);
    expect(find.text('没能删除，稍后再试'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('empty', (tester) async {
    await _pump(tester, links: const []);
    expect(find.text('还没有分享链接'), findsOneWidget);
  });

  testWidgets('row geometry: buttons alike, last glyph on the text inset', (tester) async {
    await _pump(tester);
    final row = find.ancestor(of: find.text(_links[0].title), matching: find.byType(ListPageRow));
    final rowBox = tester.getRect(row);
    final copy = tester.getRect(find.byKey(const ValueKey('hosted-copy-M000000001')));
    final delete = tester.getRect(find.byKey(const ValueKey('hosted-delete-M000000001')));
    expect(copy.size, delete.size);
    expect(copy.center.dy, closeTo(delete.center.dy, 0.01));
    expect(delete.center.dy, closeTo(rowBox.center.dy, 0.5));
    expect(delete.left, closeTo(copy.right, 0.01));
    final glyph = tester.getRect(
      find.descendant(of: find.byKey(const ValueKey('hosted-delete-M000000001')), matching: find.byType(Icon)),
    );
    expect(rowBox.right - glyph.right, closeTo(ListPageRow.horizontal, 0.5));
    final leading = tester.getRect(find.descendant(of: row, matching: find.byType(Icon)).first);
    expect(leading.center.dy, closeTo(rowBox.center.dy, 0.5));
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('golden ($mode)', (tester) async {
      await _pump(tester, brightness: brightness);
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/hosted_links_$mode.png'));
    });
  }
}
