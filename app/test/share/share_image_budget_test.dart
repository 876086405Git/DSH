import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_gallery.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

List<RawImage> _pictures(WidgetTester tester) => tester.widgetList<RawImage>(find.byType(RawImage)).toList();

// Hold a replacement decode until the pending-state assertion has observed it.
class _GatedImage extends ImageProvider<_GatedImage> {
  _GatedImage(this.bytes);

  final Uint8List bytes;
  var gate = Completer<void>()..complete();

  @override
  Future<_GatedImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_GatedImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(() async {
        await gate.future;
        final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
        try {
          return ImageInfo(image: (await codec.getNextFrame()).image);
        } finally {
          codec.dispose();
        }
      }());
}

void main() {
  test('the budget counts mounted cells, not hidden URLs or fenced examples', () {
    const image = ShareUrlImage('unused.png');
    final gallery = List.filled(20, '![](unused.png)').join('\n');
    expect(ShareImageScope.decodeBoundFor(const []), 1200);
    expect(ShareImageScope.decodeBoundFor([ShareAnswer(gallery)]), 1200);
    expect(
      ShareImageScope.decodeBoundFor([
        ShareQuestion('prompt', images: List.filled(20, image)),
        ShareAnswer('$gallery\n\n```md\n![](example.png)\n```'),
      ]),
      1200,
    );
    expect(ShareImageScope.decodeBoundFor(List.filled(9, const ShareAnswer('![](one.png)'))), 1131);
    expect(ShareImageScope.decodeBoundFor(List.filled(32, const ShareAnswer('![](one.png)'))), 600);
    expect(ShareImageScope.decodeBoundFor(List.filled(128, const ShareAnswer('![](one.png)'))), 300);
  });

  testWidgets('full card retains every gallery and passage within its decode budget', (tester) async {
    final bytes = (await tester.runAsync(() => samplePhoto(1600, 1600)))!;
    final picture = dataImage(bytes);
    final answer = [
      for (var i = 0; i < 7; i++) ...['Passage $i', List.filled(6, picture).join('\n')],
      '```text\nlast code line\n```',
    ].join('\n\n');
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          blocks: [
            ShareQuestion('prompt', images: List.filled(8, ShareProvidedImage(MemoryImage(bytes)))),
            ShareAnswer(answer),
          ],
        ),
      ),
    );
    expect(find.byType(ShareGallery), findsNWidgets(8));
    expect(find.text('+4'), findsOneWidget);
    expect(find.text('+2'), findsNWidgets(7));
    expect(find.textContaining('Passage 6', findRichText: true), findsWidgets);
    expect(find.byType(ShareCodeWell), findsOneWidget);
    expect(tester.widget<ShareCodeWell>(find.byType(ShareCodeWell)).code, 'last code line');
    final pictures = _pictures(tester);
    expect(pictures, hasLength(32));
    var pixels = 0;
    for (final picture in pictures) {
      expect(picture.image, isNotNull);
      expect(picture.image!.width, 600);
      expect(picture.image!.height, 600);
      pixels += picture.image!.width * picture.image!.height;
    }
    expect(pixels, lessThanOrEqualTo(11520000));
    expect(tester.takeException(), isNull);
  });

  testWidgets('hidden prompts leave a small answer at the existing 1200 limit', (tester) async {
    final bytes = (await tester.runAsync(() => samplePhoto(1600, 800)))!;
    await pumpShareCard(
      tester,
      ShareCard(
        showQuestion: false,
        content: ShareContent(
          blocks: [
            for (var i = 0; i < 8; i++)
              ShareQuestion('hidden $i', images: List.filled(4, ShareProvidedImage(MemoryImage(bytes)))),
            ShareAnswer(dataImage(bytes)),
          ],
        ),
      ),
    );
    expect(find.byType(ShareGallery), findsOneWidget);
    final picture = _pictures(tester).single.image!;
    expect(picture.width, 1200);
    expect(picture.height, 600);
  });

  testWidgets('an existing cell decodes again when the shared budget changes', (tester) async {
    final bytes = (await tester.runAsync(() => samplePhoto(1600, 1600)))!;
    final provider = _GatedImage(bytes);
    final gallery = ShareGallery(images: [ShareProvidedImage(provider)], width: 342);
    Widget host(int bound) => ProviderScope(
      child: MaterialApp(
        theme: buildLightTheme(),
        home: ShareImageScope(sessionId: null, decodeBound: bound, child: gallery),
      ),
    );
    await tester.pumpWidget(host(1200));
    for (var i = 0; i < 60 && _pictures(tester).isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(_pictures(tester).single.image!.width, 1200);
    final state = tester.state(find.byKey(const ValueKey('share-image-0')));
    provider.gate = Completer<void>();
    await tester.pumpWidget(host(600));
    expect(tester.state(find.byKey(const ValueKey('share-image-0'))), same(state));
    final context = tester.element(find.byType(ShareImageScope));
    expect(shareImagesPending(context), 1);
    expect(_pictures(tester), isEmpty, reason: 'the old full-size ImageInfo has been released');
    provider.gate.complete();
    for (var i = 0; i < 60 && shareImagesPending(context) > 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
    }
    expect(shareImagesPending(context), 0);
    expect(_pictures(tester).single.image!.width, 600);
    expect(_pictures(tester).single.image!.height, 600);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
