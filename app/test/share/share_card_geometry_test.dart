// The share card's symmetry, measured: the same inset on the left, the right
// and below the QR code, the app's tile on its centre, and the brand block
// alone as far from the rule (or panel) as from the edge when a link is too
// long to scan; on the field templates the panel's margin repeated
// on every side and between the panel and the brand line; the meta capsules
// with equal room either side of their text; the galleries' even gaps and
// edges on the column; and the card unchanged by the phone's text size.

import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/share/qr_code.dart';
import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_gallery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _eps = 0.01;

Rect _rect(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

void main() {
  for (final template in ShareTemplate.values) {
    testWidgets('${template.name}: long prompts, paragraphs, code and later exchanges stay above the footer', (
      tester,
    ) async {
      final question = List.filled(12, 'Full question line').join('\n');
      final paragraph = List.filled(180, 'This paragraph must remain complete. ').join().trim();
      final code = [for (var i = 0; i < 200; i++) 'print($i)'].join('\n');
      await pumpShareCard(
        tester,
        ShareCard(
          template: template,
          content: ShareContent(
            blocks: [
              ShareQuestion(question),
              ShareAnswer(paragraph),
              ShareAnswer('```python\n$code\n```'),
              const ShareQuestion('One more question'),
              const ShareAnswer('FINAL ANSWER SENTINEL'),
            ],
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(find.text(question));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
      expect(tester.widget<ShareCodeWell>(find.byType(ShareCodeWell)).code, code);
      final tailFinder = find.byWidgetPredicate((w) => w is MarkdownBody && w.text == 'FINAL ANSWER SENTINEL');
      expect(tailFinder, findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is MarkdownBody && w.text == paragraph), findsOneWidget);
      expect(find.byKey(const ValueKey('share-more')), findsNothing);
      final footer = _rect(tester, 'share-brand');
      final tail = tester.getRect(tailFinder);
      final card = tester.getRect(find.byType(ShareCard));
      expect(card.height, greaterThan(4680), reason: 'grows beyond both former body caps');
      expect(tail.bottom, lessThan(footer.top), reason: 'the final text is not clipped under the footer');
      expect(footer.bottom, lessThan(card.bottom));
    });
  }

  for (final template in ShareTemplate.values.where((t) => !t.onField)) {
    testWidgets('${template.name}: one inset left, right and under the QR code', (tester) async {
      await pumpShareCard(tester, ShareCard(content: sampleReplyContent(), template: template));
      final card = tester.getRect(find.byType(ShareCard));
      final title = _rect(tester, 'share-title');
      final qr = _rect(tester, 'share-qr');
      final brand = _rect(tester, 'share-brand');
      final rule = _rect(tester, 'share-footer-rule');
      const inset = ShareCard.inset;
      expect(title.left - card.left, closeTo(inset, _eps));
      expect(brand.left - card.left, closeTo(inset, _eps));
      expect(card.right - qr.right, closeTo(inset, _eps));
      expect(card.bottom - qr.bottom, closeTo(inset, _eps), reason: 'the QR code\'s corner is as far from both edges');
      expect(rule.left - card.left, closeTo(inset, _eps));
      expect(card.right - rule.right, closeTo(inset, _eps));
      expect(qr.size, const Size.square(ShareCard.qrSize));
      expect(brand.center.dy, closeTo(qr.center.dy, _eps), reason: 'the brand block centres on the code');
      expect(qr.top - rule.bottom, closeTo(20, _eps));
    });
  }

  for (final template in ShareTemplate.values.where((t) => t.onField)) {
    testWidgets('${template.name}: the panel\'s margin on every side and around the brand line', (tester) async {
      await pumpShareCard(tester, ShareCard(content: sampleReplyContent(), template: template));
      final card = tester.getRect(find.byType(ShareCard));
      final panel = _rect(tester, 'share-panel');
      final title = _rect(tester, 'share-title');
      final qr = _rect(tester, 'share-qr');
      final brand = _rect(tester, 'share-brand');
      const m = ShareCard.fieldInset;
      expect(panel.left - card.left, closeTo(m, _eps));
      expect(card.right - panel.right, closeTo(m, _eps));
      expect(panel.top - card.top, closeTo(m, _eps));
      expect(qr.top - panel.bottom, closeTo(m, _eps));
      expect(card.bottom - qr.bottom, closeTo(m, _eps));
      expect(card.right - qr.right, closeTo(m, _eps));
      expect(brand.left, closeTo(panel.left, _eps), reason: 'the brand line starts at the panel\'s edge');
      expect(qr.right, closeTo(panel.right, _eps));
      expect(title.left - panel.left, closeTo(ShareCard.panelInset, _eps));
      expect(brand.center.dy, closeTo(qr.center.dy, _eps));
    });
  }

  for (final template in ShareTemplate.values) {
    testWidgets('${template.name}: the app\'s tile on the QR code\'s centre, one module of plate round it', (
      tester,
    ) async {
      await pumpShareCard(tester, ShareCard(content: sampleReplyContent(), template: template));
      final qr = _rect(tester, 'share-qr');
      final logo = tester.getRect(
        find.descendant(of: find.byKey(const ValueKey('share-qr')), matching: find.byKey(QrCodeView.logoKey)),
      );
      expect(logo.center.dx, closeTo(qr.center.dx, 1e-6));
      expect(logo.center.dy, closeTo(qr.center.dy, 1e-6));
      final (code, plate) = QrCodeView.codeFor(
        dshGoProjectUrl,
        QrEcc.medium,
        logo: true,
        size: ShareCard.qrSize,
        quietZone: 3,
      );
      expect((code.version, code.ecc), (5, QrEcc.high));
      final cell = ShareCard.qrSize / (code.size + 6);
      expect(logo.width, closeTo(plate!.logoSide * cell, 1e-6));
      for (final gap in [logo.left - qr.left, qr.right - logo.right, logo.top - qr.top, qr.bottom - logo.bottom]) {
        expect(gap, closeTo((3 + plate.logoStart) * cell, 1e-6));
      }
    });
  }

  test('at 72 the card takes the logo at every logo version: links up to 58 bytes', () {
    for (final (link, version) in [('https://qm.qq.com/q/example', 4), (dshGoProjectUrl, 5), ('x' * 58, 6)]) {
      final (code, plate) = QrCodeView.codeFor(link, QrEcc.medium, logo: true, size: ShareCard.qrSize, quietZone: 3);
      expect((code.version, code.ecc, plate?.side), (version, QrEcc.high, QrCode.logoPlates[version]));
      expect(ShareCard.qrSize / (code.size + 6), greaterThanOrEqualTo(QrCodeView.logoMinModule));
    }
  });

  test('a card draws a code up to version 6, and none past it', () {
    String link(int bytes) => 'https://go.dshtui.com/share/#p=${'A' * (bytes - 31)}';
    // Version 6 is the finest that read in every halved export; 7 is under the line.
    expect(ShareCard.qrSize / (4 * 6 + 17 + 6), greaterThanOrEqualTo(ShareCard.qrMinModule));
    expect(ShareCard.qrSize / (4 * 7 + 17 + 6), lessThan(ShareCard.qrMinModule));
    for (final (text, version, ecc, logo) in [
      (dshGoProjectUrl, 5, QrEcc.high, true),
      (link(58), 6, QrEcc.high, true),
      (link(59), 4, QrEcc.medium, false),
      (link(106), 6, QrEcc.medium, false),
    ]) {
      final (code, plate) = ShareCard.qrFor(text)!;
      expect((code.version, code.ecc, plate != null), (version, ecc, logo), reason: '${text.length} bytes');
    }
    expect(ShareCard.qrFor(link(107)), isNull, reason: 'version 7');
    expect(ShareCard.qrFor(samplePluginLink()), isNull, reason: 'a plugin card\'s own link');
  });

  for (final template in ShareTemplate.values) {
    testWidgets('${template.name}: no code, the brand block alone, as far from what is above as from the edge', (
      tester,
    ) async {
      await pumpShareCard(
        tester,
        ShareCard(
          content: ShareContent(blocks: const [samplePlugin], link: samplePluginLink()),
          template: template,
        ),
      );
      expect(find.byKey(const ValueKey('share-qr')), findsNothing);
      expect(find.byType(QrCodeView), findsNothing);
      expect(find.text('手机上的 DSH'), findsOneWidget);
      expect(find.textContaining('扫码'), findsNothing);
      final card = tester.getRect(find.byType(ShareCard));
      final brand = _rect(tester, 'share-brand');
      if (template.onField) {
        final panel = _rect(tester, 'share-panel');
        expect(brand.left, closeTo(panel.left, _eps), reason: 'at the panel\'s edge');
        expect(brand.top - panel.bottom, closeTo(ShareCard.fieldInset, _eps));
        expect(card.bottom - brand.bottom, closeTo(ShareCard.fieldInset, _eps));
      } else {
        final rule = _rect(tester, 'share-footer-rule');
        expect(brand.left - card.left, closeTo(ShareCard.inset, _eps), reason: 'where the text starts');
        expect(brand.top - rule.bottom, closeTo(ShareCard.inset, _eps));
        expect(card.bottom - brand.bottom, closeTo(ShareCard.inset, _eps));
      }
    });
  }

  testWidgets('meta capsules: 10 either side of the text, one height, 6 apart', (tester) async {
    await pumpShareCard(tester, ShareCard(content: sampleReplyContent()));
    final pills = [for (final text in sampleReplyContent().metaPills) (text, _rect(tester, 'share-pill-$text'))];
    expect(pills.map((p) => p.$1), ['deepseek-v4-pro', '53 秒', '8 步']);
    for (final (text, pill) in pills) {
      final label = tester.getRect(find.text(text));
      expect(pill.height, 24);
      expect(label.left - pill.left, closeTo(10, _eps), reason: text);
      expect(pill.right - label.right, closeTo(10, _eps), reason: text);
      expect(label.center.dy, closeTo(pill.center.dy, _eps), reason: text);
      expect(pill.top, pills.first.$2.top);
    }
    for (var i = 1; i < pills.length; i++) {
      expect(pills[i].$2.left - pills[i - 1].$2.right, closeTo(6, _eps));
    }
    final title = _rect(tester, 'share-title');
    expect(pills.first.$2.left, closeTo(title.left, _eps));
  });

  testWidgets('galleries: even gaps, flush with the bubble and the column', (tester) async {
    final p = await photos(tester);
    final markdown = shareMarkdown(
      '三张：\n\n${[for (final b in p.take(3)) dataImage(b)].join('\n')}\n\n六张：\n\n${[for (final b in p) dataImage(b)].join('\n')}',
      images: true,
    );
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          title: '照片',
          blocks: [
            ShareQuestion('两张', images: [for (final b in p.take(2)) ShareProvidedImage(MemoryImage(b))]),
            ShareAnswer(markdown),
          ],
        ),
      ),
    );
    final card = tester.getRect(find.byType(ShareCard));
    final galleries = find.byType(ShareGallery);
    expect(galleries, findsNWidgets(3));
    List<Rect> cells(int gallery) => [
      for (final e
          in find
              .descendant(
                of: galleries.at(gallery),
                matching: find.byWidgetPredicate(
                  (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('share-image-'),
                ),
              )
              .evaluate())
        tester.getRect(find.byWidget(e.widget)),
    ];
    const g = ShareGalleryLayout.gap;
    final left = card.left + ShareCard.inset, right = card.right - ShareCard.inset;

    // The prompt's two: equal squares, 4 apart, ending where the bubble ends.
    final q = cells(0);
    final bubble = _rect(tester, 'share-bubble');
    expect(q[0].size, q[1].size);
    expect(q[0].width, closeTo(q[0].height, _eps));
    expect(q[1].left - q[0].right, closeTo(g, _eps));
    expect(q[1].right, closeTo(bubble.right, _eps));
    expect(q[1].right - q[0].left, closeTo(ShareGalleryLayout.questionWidth, _eps));
    expect(bubble.top - q[0].bottom, closeTo(8, _eps));

    // Three: one tall on the left, two stacked; the frame spans the column.
    final three = cells(1);
    expect(three[0].left, closeTo(left, _eps));
    expect(three[1].right, closeTo(right, _eps));
    expect(three[1].left - three[0].right, closeTo(g, _eps));
    expect(three[2].top - three[1].bottom, closeTo(g, _eps));
    expect(three[0].top, closeTo(three[1].top, _eps));
    expect(three[0].bottom, closeTo(three[2].bottom, _eps));
    expect(three[0].width, closeTo(three[1].width, _eps));

    // Six: a 2 × 2 grid, 4 apart both ways, 「+2」 on the fourth.
    final grid = cells(2);
    expect(grid, hasLength(4));
    expect(grid[1].left - grid[0].right, closeTo(g, _eps));
    expect(grid[2].top - grid[0].bottom, closeTo(g, _eps));
    expect(grid[3].left - grid[2].right, closeTo(g, _eps));
    expect(grid[3].top - grid[1].bottom, closeTo(g, _eps));
    expect(grid[0].left, closeTo(left, _eps));
    expect(grid[3].right, closeTo(right, _eps));
    for (final c in grid) {
      expect(c.size, grid.first.size);
    }
    expect(find.text('+2'), findsOneWidget);
    expect(tester.getCenter(find.text('+2')).dx, closeTo(grid[3].center.dx, 0.5));
  });

  testWidgets('a lone picture keeps its shape within the column and the height cap', (tester) async {
    final tall = (await tester.runAsync(() => samplePhoto(600, 1200, seed: 2)))!;
    final wide = (await tester.runAsync(() => samplePhoto(1200, 600, seed: 3)))!;
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          blocks: [ShareAnswer(shareMarkdown('${dataImage(tall)}\n\n文字\n\n${dataImage(wide)}', images: true))],
        ),
      ),
    );
    final images = [
      for (final e in find.byKey(const ValueKey('share-image-0')).evaluate()) tester.getRect(find.byWidget(e.widget)),
    ];
    expect(images, hasLength(2));
    expect(images[0].height, closeTo(ShareGalleryLayout.answerMaxHeight, _eps));
    expect(images[0].width, closeTo(ShareGalleryLayout.answerMaxHeight / 2, _eps));
    expect(images[1].width, closeTo(ShareCard.contentWidth(ShareTemplate.light), _eps));
    expect(images[1].height, closeTo(images[1].width / 2, _eps));
  });

  testWidgets('the phone\'s text size does not change the card', (tester) async {
    Future<Size> sizeAt(double scale) async {
      await pumpShareCard(
        tester,
        ShareCard(content: sampleReplyContent(), template: ShareTemplate.paper),
        textScale: scale,
      );
      return tester.getSize(find.byType(ShareCard));
    }

    final normal = await sizeAt(1);
    final large = await sizeAt(1.3);
    expect(large, normal);
    expect(tester.takeException(), isNull);
  });
}
