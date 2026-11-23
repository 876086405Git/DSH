import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pets/pet_library.dart';
import '../../state/workshop_publish_sources.dart';
import '../../themes/theme_library.dart';
import '../../workshop/workshop_models.dart';
import 'workshop_companion_auto_cover.dart';
import 'workshop_theme_auto_cover.dart';

typedef WorkshopAutoCoverBuilder = Widget Function(WorkshopPublishSource, ValueChanged<Uint8List?>);

final workshopAutoCoverBuilderProvider = Provider<WorkshopAutoCoverBuilder>((ref) {
  return (source, onResult) => switch (source.kind) {
    'companion' => WorkshopCompanionAutoCover(store: source.store, onResult: onResult),
    'pet' => _GeneratedCover(
      generate: () => workshopGeneratePetThumbnail(source.library ?? ref.read(petLibraryProvider), source.localId),
      onResult: onResult,
    ),
    _ => _GeneratedCover(
      generate: () => workshopGenerateThemeCover(
        library: source.themeLibrary ?? ref.read(themeLibraryProvider),
        localId: source.localId,
      ),
      onResult: onResult,
    ),
  };
});

/// Shows the same idle cell that the Worker derives from the uploaded pack.
Future<Uint8List> workshopGeneratePetThumbnail(PetLibrary library, String id) async {
  final pack = await library.load(id);
  final idle = pack.animations[pack.states['idle']!.first]!;
  final cell = idle.sourceRect(idle.frames.first.i);
  final scale = math.min(1.0, workshopPreviewSide / math.max(cell.width, cell.height));
  final width = math.max(1, (cell.width * scale).round());
  final height = math.max(1, (cell.height * scale).round());
  final codec = await ui.instantiateImageCodec(await File('${pack.dir}/${idle.sheet}').readAsBytes());
  try {
    final sheet = (await codec.getNextFrame()).image;
    try {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        sheet,
        cell,
        ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.none,
      );
      final picture = recorder.endRecording();
      try {
        final image = await picture.toImage(width, height);
        try {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          if (png == null) workshopInvalid('workshop_preview_png');
          return Uint8List.sublistView(png);
        } finally {
          image.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      sheet.dispose();
    }
  } finally {
    codec.dispose();
  }
}

class _GeneratedCover extends StatefulWidget {
  const _GeneratedCover({required this.generate, required this.onResult});

  final Future<Uint8List> Function() generate;
  final ValueChanged<Uint8List?> onResult;

  @override
  State<_GeneratedCover> createState() => _GeneratedCoverState();
}

class _GeneratedCoverState extends State<_GeneratedCover> {
  @override
  void initState() {
    super.initState();
    unawaited(_generate());
  }

  Future<void> _generate() async {
    Uint8List? bytes;
    try {
      bytes = await Future.sync(widget.generate);
    } on Object {
      // A missing or unreadable preview must not stop a submission.
    }
    if (mounted) widget.onResult(bytes);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
