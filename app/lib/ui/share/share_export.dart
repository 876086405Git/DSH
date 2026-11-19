// Turning a share card into a PNG and handing it to the Android share sheet or
// the photo album.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart' show getCrc32;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/artifacts.dart' show FilesChannel, filesChannelProvider;
import 'share_gallery.dart' show shareImagesSettled;

/// Pixel ratio for a card [height] logical pixels tall: 3× (1170 px wide)
/// for most, 2× for long ones. Long images are rasterised in strips.
double sharePixelRatio(double height) => height <= 2000 ? 3 : 2;

/// A share card's capture boundary. Its render object owns access to the
/// protected compositing layer used by long-image capture.
class ShareCaptureBoundary extends RepaintBoundary {
  const ShareCaptureBoundary({super.key, required super.child});

  @override
  RenderRepaintBoundary createRenderObject(BuildContext context) => _RenderShareCaptureBoundary();
}

class _RenderShareCaptureBoundary extends RenderRepaintBoundary {
  Future<Uint8List> captureLong(double ratio) => _captureLongCard(layer! as OffsetLayer, size, ratio);
}

/// Renders the [ShareCaptureBoundary] behind [key] as PNG bytes at
/// [sharePixelRatio], once the card's pictures are decoded (or given up on:
/// at most [imageTimeout]), so nothing is captured as an empty box. The
/// boundary is drawn at its own layout size, not at the size a preview
/// scales it to.
Future<Uint8List> captureShareCard(GlobalKey key, {Duration imageTimeout = const Duration(seconds: 8)}) async {
  if (key.currentContext case final context?) await shareImagesSettled(context, timeout: imageTimeout);
  final boundary = key.currentContext?.findRenderObject();
  if (boundary is! _RenderShareCaptureBoundary) throw StateError('share card is not on screen');
  // (debugNeedsPaint is debug-only.) A pending frame may still repaint it.
  if (SchedulerBinding.instance.hasScheduledFrame) await SchedulerBinding.instance.endOfFrame;
  final ratio = sharePixelRatio(boundary.size.height);
  if ((boundary.size.height * ratio).ceil() > _stripHeight) {
    return boundary.captureLong(ratio);
  }
  final image = await boundary.toImage(pixelRatio: ratio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

// Bound each raster allocation without shrinking the text. The overlap covers
// three sigma of the glass template's 30-logical-pixel backdrop blur.
const _stripHeight = 4096;
const _stripOverlap = 96.0;

typedef _ShareStrip = ({ui.Scene scene, int height, int skip, int rows});

Future<Uint8List> _captureLongCard(OffsetLayer layer, Size size, double ratio) async {
  final width = (size.width * ratio).ceil();
  final height = (size.height * ratio).ceil();
  final overlap = (_stripOverlap * ratio).ceil();
  final coreHeight = _stripHeight - 2 * overlap;
  final strips = <_ShareStrip>[];
  try {
    // Snapshot every scene before yielding: late images, GIF frames and a
    // dismissed preview must not change the layout between rasterisations.
    for (var y = 0; y < height; y += coreHeight) {
      final rows = math.min(coreHeight, height - y);
      final top = math.max(0, y - overlap);
      final bottom = math.min(height, y + rows + overlap);
      final transform = Matrix4.diagonal3Values(ratio, ratio, 1)
        ..setTranslationRaw(-layer.offset.dx * ratio, -layer.offset.dy * ratio - top, 0);
      final builder = ui.SceneBuilder()..pushTransform(transform.storage);
      strips.add((scene: layer.buildScene(builder), height: bottom - top, skip: y - top, rows: rows));
    }

    final png = BytesBuilder(copy: false)..add([137, 80, 78, 71, 13, 10, 26, 10]);
    final header = ByteData(13)
      ..setUint32(0, width)
      ..setUint32(4, height)
      ..setUint8(8, 8)
      ..setUint8(9, 6); // RGBA, 8 bits per channel.
    _pngChunk(png, 'IHDR', header.buffer.asUint8List());

    // All strips feed ONE zlib stream: IDAT boundaries are not image boundaries.
    await for (final bytes in ZLibEncoder().bind(_cardScanlines(strips, width))) {
      _pngChunk(png, 'IDAT', bytes);
    }
    _pngChunk(png, 'IEND', const []);
    return png.takeBytes();
  } finally {
    for (final strip in strips) {
      strip.scene.dispose();
    }
  }
}

Stream<List<int>> _cardScanlines(List<_ShareStrip> strips, int width) async* {
  final stride = width * 4;
  for (final strip in strips) {
    final image = await strip.scene.toImage(width, strip.height);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data == null) throw StateError('image readback failed');
      final rgba = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      // ZLibEncoder compresses each input event synchronously. Keep events
      // small and return to the event loop between them so the UI can respond.
      for (var first = 0; first < strip.rows; first += 64) {
        final rows = math.min(64, strip.rows - first);
        final scanlines = Uint8List(rows * (stride + 1));
        for (var row = 0; row < rows; row++) {
          // PNG filter 0 (None); skip overlap rather than repeating its rows.
          scanlines.setRange(
            row * (stride + 1) + 1,
            (row + 1) * (stride + 1),
            rgba,
            (strip.skip + first + row) * stride,
          );
        }
        yield scanlines;
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      image.dispose();
    }
  }
}

void _pngChunk(BytesBuilder png, String type, List<int> data) {
  final tag = type.codeUnits;
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, getCrc32(data, getCrc32(tag)));
  png
    ..add(length.buffer.asUint8List())
    ..add(tag)
    ..add(data)
    ..add(crc.buffer.asUint8List());
}

/// Where a finished card goes. A seam: tests record instead of sharing.
class ShareExporter {
  ShareExporter({
    required this.files,
    Future<Directory> Function()? cacheRoot,
    Future<void> Function(ShareParams params)? share,
    DateTime Function()? clock,
  }) : _cacheRoot = cacheRoot ?? getTemporaryDirectory,
       _share = share ?? _systemShare,
       _clock = clock ?? DateTime.now;

  final FilesChannel files;
  final Future<Directory> Function() _cacheRoot;
  final Future<void> Function(ShareParams params) _share;
  final DateTime Function() _clock;

  static Future<void> _systemShare(ShareParams params) async {
    await SharePlus.instance.share(params);
  }

  /// `dsh-go-20261024-153012.png`.
  String fileName() {
    final t = _clock();
    String two(int n) => n.toString().padLeft(2, '0');
    return 'dsh-go-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.png';
  }

  /// Writes [png] into the cache's `share/` (keeping only the last few).
  Future<File> write(Uint8List png) async {
    final dir = Directory('${(await _cacheRoot()).path}/share');
    await dir.create(recursive: true);
    final old = dir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    for (final file in old.skip(4)) {
      try {
        file.deleteSync();
      } catch (_) {}
    }
    final file = File('${dir.path}/${fileName()}');
    await file.writeAsBytes(png, flush: true);
    return file;
  }

  /// The Android share sheet with the image (and [text], for apps that take both).
  Future<void> share(File image, {String? text}) => _share(
    ShareParams(
      files: [XFile(image.path, mimeType: 'image/png', name: image.uri.pathSegments.last)],
      text: text,
    ),
  );

  /// Into the shared pictures the album shows (`Download/DSH-Go`, indexed as an
  /// image by MediaStore); returns where it landed.
  Future<String> save(File image) =>
      files.saveToDownloads(image.path, name: image.uri.pathSegments.last, mime: 'image/png');
}

final shareExporterProvider = Provider<ShareExporter>((ref) => ShareExporter(files: ref.watch(filesChannelProvider)));
