// The export waits for the card's pictures: a capture started while a
// picture is still on its way finishes only once it is drawn, and a picture
// that never comes is given up on after the timeout rather than holding the
// export.

import 'dart:async';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/share/share_card.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_export.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'support.dart';

/// A picture whose bytes arrive when [gate] completes.
class _GatedImage extends ImageProvider<_GatedImage> {
  _GatedImage(this.gate, this.bytes);

  final Completer<void> gate;
  final Uint8List bytes;

  @override
  Future<_GatedImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(_GatedImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(() async {
        await gate.future;
        final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
        return ImageInfo(image: (await codec.getNextFrame()).image);
      }());
}

Future<void> _drainUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter(this.bandHeight);

  final double bandHeight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(const Color(0x80ff0000), BlendMode.src);
    canvas.drawRect(Rect.fromLTRB(0, bandHeight, size.width, size.height), Paint()..color = const Color(0xff00ff00));
    if (size.height > 2 * bandHeight) {
      canvas.drawRect(
        Rect.fromLTRB(0, 2 * bandHeight, size.width, size.height),
        Paint()..color = const Color(0xff0000ff),
      );
    }
  }

  @override
  bool shouldRepaint(_StripPainter oldDelegate) => false;
}

void main() {
  for (final (height, ratio, blur) in [(4200.5, 2.0, false), (1500.0, 3.0, false), (1500.0, 3.0, true)]) {
    testWidgets('${ratio}x blur=$blur: a narrow preview exports all strips and the offscreen last row', (tester) async {
      final key = GlobalKey();
      final coreHeight = 4096 - 2 * (96 * ratio).ceil();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SingleChildScrollView(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 4,
                child: FittedBox(
                  fit: BoxFit.fitWidth,
                  child: ShareCaptureBoundary(
                    key: key,
                    child: ClipRect(
                      child: SizedBox(
                        width: 8.5,
                        height: height,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            CustomPaint(painter: _StripPainter(coreHeight / ratio)),
                            if (blur)
                              BackdropFilter(
                                filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                                child: const ColoredBox(color: Colors.transparent),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final layer = boundary.debugLayer! as OffsetLayer;
      final previousCreate = ui.Image.onCreate;
      final previousDispose = ui.Image.onDispose;
      var created = 0;
      var live = 0;
      var peak = 0;
      final heights = <int>[];
      ui.Image.onCreate = (image) {
        previousCreate?.call(image);
        created++;
        live++;
        if (live > peak) peak = live;
        heights.add(image.height);
        // Simulate a preview repaint/dismissal between the first and later
        // rasterisations. Every scene must already own the old picture tree.
        if (!blur && created == 1) layer.removeAllChildren();
      };
      ui.Image.onDispose = (image) {
        previousDispose?.call(image);
        live--;
      };
      late Uint8List png;
      try {
        Uint8List? captured;
        final capture = captureShareCard(key).then((value) => captured = value);
        await _drainUntil(tester, () => captured != null);
        expect(captured, isNotNull, reason: 'capture must finish while scheduled frames and timers are pumped');
        png = await capture;
      } finally {
        ui.Image.onCreate = previousCreate;
        ui.Image.onDispose = previousDispose;
      }
      expect(created, ((height * ratio).ceil() / coreHeight).ceil());
      expect(heights, everyElement(lessThanOrEqualTo(4096)));
      expect(peak, 1, reason: 'only one strip bitmap is live at a time');
      expect(live, 0, reason: 'all raster images were disposed');
      final decoded = img.decodePng(png)!;
      final pixelHeight = (height * ratio).ceil();
      expect((decoded.width, decoded.height), ((8.5 * ratio).ceil(), pixelHeight));
      img.Image? reference;
      if (blur) {
        // A small-width full raster is safe in CI and exposes missing blur
        // input at seams; it is not the production long-image capture path.
        final bytes = (await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: ratio);
          try {
            return (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
          } finally {
            image.dispose();
          }
        }))!;
        reference = img.decodePng(bytes)!;
      }
      for (final y in [
        0,
        coreHeight - 1,
        coreHeight,
        if (pixelHeight > 2 * coreHeight) ...[2 * coreHeight - 1, 2 * coreHeight],
        pixelHeight - 1,
      ]) {
        final pixel = decoded.getPixel(0, y);
        final channels = [pixel.r, pixel.g, pixel.b, pixel.a];
        if (reference != null) {
          final expected = reference.getPixel(0, y);
          final targets = [expected.r, expected.g, expected.b, expected.a];
          for (var channel = 0; channel < 4; channel++) {
            expect(channels[channel], closeTo(targets[channel], 1), reason: 'blur matches the full raster at row $y');
          }
        } else {
          final expected = y < coreHeight
              ? [255, 0, 0, 128]
              : (y < 2 * coreHeight ? [0, 255, 0, 255] : [0, 0, 255, 255]);
          expect(channels, expected, reason: 'row $y, including strip boundaries');
        }
      }
    });
  }

  testWidgets('a capture waits for a picture still on its way', (tester) async {
    final bytes = (await tester.runAsync(() => samplePhoto(400, 300)))!;
    final gate = Completer<void>();
    final key = GlobalKey();
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          title: '图',
          blocks: [
            ShareQuestion('看看', images: [ShareProvidedImage(_GatedImage(gate, bytes))]),
          ],
        ),
      ),
      boundary: key,
      settle: false,
    );
    Uint8List? png;
    final capture = captureShareCard(key).then((value) => png = value);
    await _drainUntil(tester, () => false);
    expect(png, isNull, reason: 'the picture has not come yet');
    expect(find.byType(RawImage), findsNothing);

    gate.complete();
    await _drainUntil(tester, () => png != null);
    await capture;
    expect(png, isNotNull);
    expect(find.byType(RawImage), findsOneWidget, reason: 'drawn before the capture');
  });

  testWidgets('a picture that never comes does not hold the export', (tester) async {
    final gate = Completer<void>();
    final key = GlobalKey();
    await pumpShareCard(
      tester,
      ShareCard(
        content: ShareContent(
          blocks: [
            ShareQuestion('看看', images: [ShareProvidedImage(_GatedImage(gate, Uint8List(0)))]),
          ],
        ),
      ),
      boundary: key,
      settle: false,
    );
    Uint8List? png;
    unawaited(captureShareCard(key, imageTimeout: const Duration(seconds: 2)).then((value) => png = value));
    await tester.pump(const Duration(seconds: 3));
    await _drainUntil(tester, () => png != null);
    expect(png, isNotNull);
  });
}
