// 引用追问: the passage travels as a Markdown blockquote in front of the
// message and comes back out of it for the bubble. In the composer, the quote
// chip is a capsule whose quote mark and ✕ sit like end caps (equal insets,
// mirrored); it sits 12 from the glass's top and sides — concentric with the
// glass corner — on the attachment row's left edge, with the same 8 to the
// text row below as the attachments.

import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/quote_chip.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _short = '超时重试多发了一次请求';
const _long =
    '是**超时重试**多发了一次请求：第一次请求在 30 秒时超时，客户端重试，'
    '而服务端其实已经处理完了第一次，于是同一笔订单被提交了两次。';

final _files = [
  DraftAttachment(name: '复现日志.txt', bytes: Uint8List(2400)),
  DraftAttachment(name: '订单.pdf', bytes: Uint8List(120000)),
];

Future<void> _pump(
  WidgetTester tester, {
  String? quote = _short,
  List<DraftAttachment> attachments = const [],
  double textScale = 1,
  Brightness brightness = Brightness.light,
  VoidCallback? onRemove,
}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      brightness: brightness,
      MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Composer(
                  controller: TextEditingController(),
                  connected: true,
                  running: false,
                  onSend: () {},
                  onStop: () {},
                  leading: AttachButton(onPressed: () {}),
                  hasAttachments: attachments.isNotEmpty,
                  tray: ComposerTrayStack.maybe(
                    quote: quote == null ? null : QuoteChip(quote: quote, onRemove: onRemove ?? () {}),
                    attachments: attachments.isEmpty ? null : ComposerTray(items: attachments, onRemove: (_) {}),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  // A tray part added to one already shown unfolds: measure where it lands.
  await tester.pumpAndSettle();
}

Rect _glass(WidgetTester tester) => tester.getRect(find.byType(Composer));
Rect _chip(WidgetTester tester) => tester.getRect(find.byType(QuoteChip));
Rect _inChip(WidgetTester tester, IconData icon) =>
    tester.getRect(find.descendant(of: find.byType(QuoteChip), matching: find.byIcon(icon)));
Rect _plus(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byIcon(AppIcons.add), matching: find.byType(Container)).first);

/// The quote mark and the ✕ sit like end caps: the same inset to the top,
/// the bottom and their own end.
void _expectEndCaps(WidgetTester tester) {
  final chip = _chip(tester);
  final mark = _inChip(tester, AppIcons.quote);
  final close = _inChip(tester, AppIcons.close);
  final inset = (chip.height - QuoteChip.glyph) / 2;
  expect(mark.size, const Size.square(QuoteChip.glyph));
  expect(close.size, mark.size);
  expect(mark.left - chip.left, moreOrLessEquals(inset, epsilon: 0.5));
  expect(chip.right - close.right, moreOrLessEquals(inset, epsilon: 0.5));
  for (final glyph in [mark, close]) {
    expect(glyph.top - chip.top, moreOrLessEquals(inset, epsilon: 0.5));
    expect(chip.bottom - glyph.bottom, moreOrLessEquals(inset, epsilon: 0.5));
  }
}

void main() {
  setUpAll(loadTestFonts);

  group('blockquote', () {
    test('a quote goes in front as a blockquote, a blank line after', () {
      expect(withQuote('第一行\n\n第三行', '这是为什么？'), '> 第一行\n>\n> 第三行\n\n这是为什么？');
      expect(withQuote('  只有引文  ', ''), '> 只有引文');
      expect(withQuote('   ', '原样'), '原样');
    });

    test('normalizeQuote folds blank runs and cuts long passages', () {
      expect(normalizeQuote('a  \r\nb\n\n\n\nc\n'), 'a\nb\n\nc');
      final long = normalizeQuote('字' * (maxQuoteLength + 50));
      expect(long.runes.length, maxQuoteLength + 1);
      expect(long.endsWith('…'), isTrue);
    });

    test('splitQuote takes the leading block back out', () {
      final sent = withQuote('第一行\n第二行', '这是为什么？\n还有别的原因吗');
      final split = splitQuote(sent);
      expect(split.quote, '第一行\n第二行');
      expect(split.body, '这是为什么？\n还有别的原因吗');

      final plain = splitQuote('没有引文\n> 中间的不算');
      expect(plain.quote, isNull);
      expect(plain.body, '没有引文\n> 中间的不算');

      expect(splitQuote('> 只有引文'), (quote: '只有引文', body: ''));
    });

    test('quoteLine shows the passage on one line without Markdown marks', () {
      expect(quoteLine('## 原因\n- 是**超时重试**\n- `retry` 多了一次'), '原因 是超时重试 retry 多了一次');
    });

    test('quotes are kept per conversation', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final quotes = container.read(composerQuoteProvider.notifier);
      quotes.set('s1', '  第一段  ');
      quotes.set('s2', '第二段');
      quotes.set('s3', '   ');
      expect(container.read(composerQuoteProvider), {'s1': '第一段', 's2': '第二段'});
      quotes.clear('s1');
      expect(container.read(composerQuoteProvider).keys, ['s2']);
    });
  });

  group('quote chip geometry', () {
    for (final scale in [1.0, 1.3]) {
      testWidgets('quote mark and ✕ are mirrored end caps (text ×$scale)', (tester) async {
        await _pump(tester, textScale: scale);
        final chip = _chip(tester);
        if (scale == 1) expect(chip.height, QuoteChip.minHeight);
        expect(chip.height, greaterThanOrEqualTo(QuoteChip.minHeight));
        _expectEndCaps(tester);
      });
    }

    testWidgets('12 from the glass top and sides: concentric with its corner', (tester) async {
      await _pump(tester, quote: _long);
      final glass = _glass(tester);
      final chip = _chip(tester);
      expect(chip.left - glass.left, moreOrLessEquals(12, epsilon: 0.5));
      expect(chip.top - glass.top, moreOrLessEquals(12, epsilon: 0.5));
      // A long passage fills the row and stops as far from the right edge.
      expect(glass.right - chip.right, moreOrLessEquals(12, epsilon: 0.5));
      // 28 − 12: the chip's end cap shares the glass corner's centre.
      expect(chip.height / 2, moreOrLessEquals(AppShape.xl - 12, epsilon: 0.5));
      _expectEndCaps(tester);
    });

    testWidgets('a short passage hugs its text', (tester) async {
      await _pump(tester);
      final glass = _glass(tester);
      // Its own width, well short of the 12 the row would end at.
      expect(glass.right - _chip(tester).right, greaterThan(48));
    });

    testWidgets('on the attachment row\'s left edge, with the same gap to the '
        'text row', (tester) async {
      await _pump(tester, quote: null, attachments: _files);
      final tray = tester.getRect(find.byType(ComposerTray));
      final trayGap = _plus(tester).top - tray.bottom;
      final tile = tester.getRect(find.byType(FileCard).first);

      await _pump(tester);
      expect(_plus(tester).top - _chip(tester).bottom, moreOrLessEquals(trayGap, epsilon: 0.5));

      await _pump(tester, attachments: _files);
      final chip = _chip(tester);
      expect(chip.left, moreOrLessEquals(tile.left, epsilon: 0.5));
      final under = tester.getRect(find.byType(FileCard).first);
      expect(under.left, moreOrLessEquals(chip.left, epsilon: 0.5));
      // The tiles' ✕ badges overhang 8: 4 + 4 of the badge's own inset puts
      // the badge circle 8 below the chip, the tile 12.
      expect(under.top - chip.bottom, moreOrLessEquals(12, epsilon: 0.5));
      expect(
        _plus(tester).top - tester.getRect(find.byType(ComposerTray)).bottom,
        moreOrLessEquals(trayGap, epsilon: 0.5),
      );
    });
  });

  testWidgets('✕ removes the quote; the chip reads as one quote', (tester) async {
    final semantics = tester.ensureSemantics();
    var removed = 0;
    await _pump(tester, onRemove: () => removed++);
    expect(find.bySemanticsLabel('引用：$_short'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('移除引用'));
    expect(removed, 1);
    semantics.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('golden: quote chip, then with attachments (${brightness.name})', (tester) async {
      await _pump(tester, quote: _long, brightness: brightness);
      await expectLater(find.byType(Composer), matchesGoldenFile('goldens/quote_chip_${brightness.name}.png'));
      await _pump(tester, attachments: _files, brightness: brightness);
      await expectLater(find.byType(Composer), matchesGoldenFile('goldens/quote_chip_tray_${brightness.name}.png'));
    });
  }
}
