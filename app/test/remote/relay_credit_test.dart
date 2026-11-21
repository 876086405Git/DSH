// The credit under the DSH Remote card: only the project name opens
// github.com/liguobao/ds-harness-remote; its tap area reaches 48dp tall into
// the empty space around the line and stays clear of every control near it.

import 'package:dsh_app/remote/relay/relay_backend.dart';
import 'package:dsh_app/remote/secret_store.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/star_prompt.dart' show starLinkOpenerProvider;
import 'package:dsh_app/ui/common/app_sheet.dart' show SheetGroup;
import 'package:dsh_app/ui/remote/relay_credit.dart';
import 'package:dsh_app/ui/remote/remote_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../support/english_preview.dart';
import 'support/fake_relay.dart';

const _project = 'https://github.com/liguobao/ds-harness-remote';

class _SelfHostedRelay extends FakeRelayBackend {
  @override
  String get serverLabel => 'remote.example.com';
}

void main() {
  /// What the browser app was asked to open (the project link's opener).
  late List<Uri> opened;
  late Future<bool> Function(Uri) opener;

  /// What the sign-in opener (Custom Tab) was asked to open.
  late List<Uri> signInPages;

  setUp(() {
    opened = [];
    signInPages = [];
    opener = (url) async {
      opened.add(url);
      return true;
    };
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> frames(WidgetTester tester, [int n = 6]) async {
    for (var i = 0; i < n; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pump(WidgetTester tester, {RelayBackend? relay}) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        home: const RemoteScreen(),
        brightness: Brightness.light,
        overrides: [
          secretStoreProvider.overrideWithValue(MemorySecretStore()),
          networkKicksProvider.overrideWithValue(const Stream.empty()),
          relayBackendProvider.overrideWithValue(relay ?? FakeRelayBackend()),
          hostLinkStatusProvider.overrideWith((ref, host) => Stream.value(HostLinkStatus.idle)),
          localRuntimeProvider.overrideWith(
            () => FakeRuntime(const LocalRuntimeState(loaded: true, status: runningStatus)),
          ),
          starLinkOpenerProvider.overrideWithValue((url) => opener(url)),
          urlOpenerProvider.overrideWithValue((url) async {
            signInPages.add(url);
            return true;
          }),
        ],
      ),
    );
    await frames(tester);
  }

  RenderParagraph paragraph(WidgetTester tester) => tester.renderObject<RenderParagraph>(
    find.descendant(of: find.byType(RelayCredit), matching: find.byType(RichText)).first,
  );

  /// The credit as laid out: the word joiner and the glyph's placeholder
  /// follow the name.
  String creditText(WidgetTester tester) => paragraph(tester).text.toPlainText(includeSemanticsLabels: false);

  /// [part] of the credit as drawn, in screen coordinates.
  Rect partRect(WidgetTester tester, String part) {
    final p = paragraph(tester);
    final text = creditText(tester);
    final at = text.indexOf(part);
    expect(at, isNonNegative, reason: '"$part" in "$text"');
    final boxes = p.getBoxesForSelection(TextSelection(baseOffset: at, extentOffset: at + part.length));
    final local = boxes.map((b) => b.toRect()).reduce((a, b) => a.expandToInclude(b));
    return MatrixUtils.transformRect(p.getTransformTo(null), local);
  }

  Rect lineRect(WidgetTester tester) {
    final p = paragraph(tester);
    return MatrixUtils.transformRect(p.getTransformTo(null), Offset.zero & p.size);
  }

  /// A tap at [point] reaches the link's recognizer.
  bool hitsLink(WidgetTester tester, Offset point) => tester
      .hitTestOnBinding(point)
      .path
      .any(
        (e) => switch (e.target) {
          TextSpan(:final TapGestureRecognizer recognizer, :final String text) =>
            recognizer.onTap != null && text.startsWith('liguobao/'),
          _ => false,
        },
      );

  /// Every point of the page between [top] and [bottom] whose tap goes to the
  /// link, on a [step] grid: their bounds.
  Rect? linkRegion(WidgetTester tester, double top, double bottom, {double step = 1}) {
    Rect? region;
    for (var y = top; y <= bottom; y += step) {
      for (var x = 0.5; x < 390; x += step) {
        final p = Offset(x, y);
        if (hitsLink(tester, p)) {
          region = region?.expandToInclude(Rect.fromLTWH(x, y, 0, 0)) ?? Rect.fromLTWH(x, y, 0, 0);
        }
      }
    }
    return region;
  }

  Finder card(String text) => find.ancestor(of: find.text(text), matching: find.byType(SheetGroup));

  testWidgets('reads 服务由 liguobao/ds-harness-remote 提供', (tester) async {
    await pump(tester);
    expect(creditText(tester), startsWith('服务由 liguobao/ds-harness-remote\u2060\uFFFC 提供'));
    expect(find.textContaining('李国宝', findRichText: true), findsNothing);
  });

  testWidgets('tapping the project name opens its GitHub page', (tester) async {
    await pump(tester);
    await tester.tapAt(partRect(tester, 'liguobao/ds-harness-remote').center);
    await frames(tester, 2);
    expect(opened, [Uri.parse(_project)]);

    // The glyph after the name is part of the link.
    final glyph = tester.getRect(find.descendant(of: find.byType(RelayCredit), matching: find.byType(Icon)));
    await tester.tapAt(glyph.center);
    await frames(tester, 2);
    expect(opened, [Uri.parse(_project), Uri.parse(_project)]);
  });

  testWidgets('the rest of the line does nothing', (tester) async {
    await pump(tester);
    await tester.tapAt(partRect(tester, '服务由').center);
    await tester.tapAt(partRect(tester, '提供').center);
    // Just past either end of the link, on its line.
    final name = partRect(tester, 'liguobao/ds-harness-remote');
    final glyph = tester.getRect(find.descendant(of: find.byType(RelayCredit), matching: find.byType(Icon)));
    await tester.tapAt(Offset(name.left - 2, name.center.dy));
    await tester.tapAt(Offset(glyph.right + 3, name.center.dy));
    // Below the reach of the link, and beside it in the space it reaches into.
    await tester.tapAt(Offset(name.center.dx, lineRect(tester).bottom + 23.5));
    await tester.tapAt(Offset(partRect(tester, '服务由').center.dx, lineRect(tester).bottom + 10));
    await frames(tester, 2);
    expect(opened, isEmpty);
  });

  testWidgets('the name takes taps a little above and below its line', (tester) async {
    await pump(tester);
    final line = lineRect(tester);
    final x = partRect(tester, 'liguobao/ds-harness-remote').center.dx;
    await tester.tapAt(Offset(x, line.top - 7));
    await frames(tester, 2);
    expect(opened, hasLength(1));
    await tester.tapAt(Offset(x, line.bottom + 20));
    await frames(tester, 2);
    expect(opened, hasLength(2));
  });

  testWidgets('the tap area is 48dp tall and overlaps no other control', (tester) async {
    await pump(tester);
    final relayCard = tester.getRect(card('登录 DSH Remote'));
    // One button per sign-in provider; the lowest one sits nearest the credit line.
    final signIn = tester.getRect(find.byWidgetPredicate((w) => w is FilledButton).last);
    final selfHosted = tester.getRect(find.widgetWithText(TextButton, '自建服务器 · 邮箱登录'));
    final sshTitle = tester.getRect(find.text('SSH 主机'));
    final sshCard = tester.getRect(card('添加 SSH 主机'));
    final line = lineRect(tester);
    final name = partRect(tester, 'liguobao/ds-harness-remote');
    final glyph = tester.getRect(find.descendant(of: find.byType(RelayCredit), matching: find.byType(Icon)));

    // Every point from the sign-in button to the SSH card, 1dp apart.
    final region = linkRegion(tester, signIn.top, sshCard.bottom)!;
    expect(region.top, greaterThanOrEqualTo(relayCard.bottom), reason: 'stays out of the card');
    expect(region.bottom, lessThan(sshTitle.top), reason: 'stays out of the next section');
    for (final (label, rect) in [('sign-in', signIn), ('self-hosted', selfHosted), ('SSH card', sshCard)]) {
      expect(region.overlaps(rect), isFalse, reason: '$label $rect vs link $region');
    }
    // Only the name and its glyph across.
    expect(region.left, closeTo(name.left, 1.01));
    expect(region.right, closeTo(glyph.right, 1.01));

    // Height to a quarter dp, through the middle of the name.
    var top = line.center.dy, bottom = line.center.dy;
    while (hitsLink(tester, Offset(name.center.dx, top - 0.25))) {
      top -= 0.25;
    }
    while (hitsLink(tester, Offset(name.center.dx, bottom + 0.25))) {
      bottom += 0.25;
    }
    expect(bottom - top, greaterThanOrEqualTo(kMinInteractiveDimension - 0.5));
    expect(bottom - top, lessThanOrEqualTo(kMinInteractiveDimension + 0.5));

    // The neighbours keep their own edges.
    for (final edge in [
      Offset(selfHosted.center.dx, selfHosted.bottom - 0.5),
      Offset(sshCard.center.dx, sshCard.top + 0.5),
      Offset(signIn.center.dx, signIn.bottom - 0.5),
    ]) {
      expect(hitsLink(tester, edge), isFalse, reason: '$edge');
    }
  });

  testWidgets('the layout is that of a plain footer', (tester) async {
    await pump(tester);
    final line = lineRect(tester);
    // Card → 8 → the line → the section margin (24) → the next section's title.
    expect(line.top - tester.getRect(card('登录 DSH Remote')).bottom, closeTo(8, 0.01));
    expect(tester.getRect(find.text('SSH 主机')).top - line.bottom, closeTo(24, 0.01));
  });

  testWidgets('signing in still opens the sign-in page, not the project', (tester) async {
    await pump(tester);
    await tester.tap(find.text('使用 GitHub 登录'));
    await frames(tester, 3);
    expect(signInPages, [Uri.parse('https://dsh.r2049.cn/qr/scan/abc')]);
    expect(opened, isEmpty);
    await tester.tap(find.text('取消'));
    await frames(tester, 3);
  });

  testWidgets('no browser: the address is copied and a line says so', (tester) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    opener = (url) async => false;
    await pump(tester);
    await tester.tapAt(partRect(tester, 'liguobao/ds-harness-remote').center);
    await frames(tester, 4);
    expect(clipboard, _project);
    expect(find.text('没能打开浏览器，网址已复制'), findsOneWidget);
  });

  testWidgets('a browser that throws is a message, not a crash', (tester) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') throw PlatformException(code: 'no-clipboard');
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    opener = (url) async => throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
    await pump(tester);
    await tester.tapAt(partRect(tester, 'liguobao/ds-harness-remote').center);
    await frames(tester, 4);
    expect(tester.takeException(), isNull);
    expect(find.text('没能打开浏览器'), findsOneWidget);
  });

  testWidgets('a self-hosted server is named after the credit; the link still works', (tester) async {
    await pump(tester, relay: _SelfHostedRelay());
    expect(creditText(tester), '服务由 liguobao/ds-harness-remote\u2060\uFFFC 提供 · 当前服务器 remote.example.com');
    await tester.tapAt(partRect(tester, 'remote.example.com').center);
    await frames(tester, 2);
    expect(opened, isEmpty);
    await tester.tapAt(partRect(tester, 'liguobao/ds-harness-remote').center);
    await frames(tester, 2);
    expect(opened, [Uri.parse(_project)]);
  });

  testWidgets('English: Service by liguobao/ds-harness-remote', (tester) async {
    useEnglish();
    await pump(tester);
    expect(creditText(tester), 'Service by liguobao/ds-harness-remote\u2060\uFFFC');
    await tester.tapAt(partRect(tester, 'Service').center);
    await frames(tester, 2);
    expect(opened, isEmpty);
    await tester.tapAt(partRect(tester, 'liguobao/ds-harness-remote').center);
    await frames(tester, 2);
    expect(opened, [Uri.parse(_project)]);
    // The same reach above and below the line.
    final x = partRect(tester, 'liguobao/ds-harness-remote').center.dx;
    await tester.tapAt(Offset(x, lineRect(tester).top - 7));
    await tester.tapAt(Offset(x, lineRect(tester).bottom + 20));
    await frames(tester, 2);
    expect(opened, hasLength(3));
  });

  testWidgets('the link is announced as a link', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester);
    final link = find.semantics.byLabel('liguobao/ds-harness-remote').evaluate().single;
    expect(link.flagsCollection.isLink, isTrue);
    expect(link.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    tester.semantics.tap(find.semantics.byLabel('liguobao/ds-harness-remote'));
    await frames(tester, 2);
    expect(opened, [Uri.parse(_project)]);
    semantics.dispose();
  });
}
