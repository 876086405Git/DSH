import 'dart:typed_data';

import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import 'support.dart' show workshopError;

void main() {
  test('a small JPEG becomes a valid companion PNG without upscaling', () async {
    final source = image.Image(width: 32, height: 24);
    source.clear(image.ColorRgb8(224, 48, 32));
    final jpeg = image.encodeJpg(source);
    final png = await workshopReadCover(Stream.value(jpeg));

    final preview = WorkshopPreviewInput.companionPng(png);
    expect((preview.width, preview.height), (32, 24));
    expect(image.decodePng(png)!.getPixel(12, 8).r, greaterThan(200));
  });

  test('an image over the old byte limit fits a theme cover and keeps its alpha', () async {
    final source = image.Image(width: 768, height: 1024, numChannels: 4);
    source.clear(image.ColorRgba8(48, 32, 224, 128));
    final original = image.encodePng(source, level: 0);
    expect(original.length, greaterThan(workshopPreviewBytes));

    final png = await workshopReadCover(Stream.value(original), length: original.length);
    final preview = WorkshopPreviewInput.themePng(png);
    expect((preview.width, preview.height), (384, 512));
    expect(preview.size, lessThanOrEqualTo(workshopPreviewBytes));
    expect(image.decodePng(png)!.getPixel(12, 8).a, 128);
  });

  test('a corrupt image reports the cover format error', () async {
    await expectLater(
      workshopReadCover(Stream.value(Uint8List.fromList([1, 2, 3, 4]))),
      workshopError('workshop_preview_png'),
    );
  });

  test('an oversized file is refused without opening its stream', () async {
    var opened = false;
    Stream<List<int>> source() async* {
      opened = true;
      yield [0];
    }

    await expectLater(
      workshopReadCover(source(), length: 32 * 1024 * 1024 + 1),
      workshopError('workshop_preview_size'),
    );
    expect(opened, isFalse);
  });
}
