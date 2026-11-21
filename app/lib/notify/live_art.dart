// The pet's picture for the iOS live activity. The widget extension can read
// neither the app's assets nor its files (a brought pet lives in the app's
// documents), so the app draws the still and hands it over; the native side
// keeps it where the extension can read it (CompanionWidget/LiveActivityShared.swift).

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../pets/pet_pack.dart';
import '../pets/pet_sheets.dart';
import '../pets/pet_state.dart';

/// The longest side, in pixels: the lock screen's 60 pt at 3×, give or take.
const liveArtSide = 180;

@immutable
class LiveArt {
  const LiveArt({required this.key, required this.png, required this.pixelArt});

  /// Names this exact picture: another pet, state or re-import is another key.
  final String key;
  final Uint8List png;
  final bool pixelArt;
}

/// [mood]'s first frame of [pack], the way Android's live activity shows it:
/// the body and whatever the animation holds (a keyboard, a sign), on a
/// transparent canvas. Pixel art scales by whole pixels. Null when it can't be drawn.
Future<LiveArt?> liveArtOf(PetPack pack, PetStateName mood, AssetBundle bundle) async {
  final anim = pack.animFor(mood);
  if (anim.frames.isEmpty) return null;
  ui.Image? sheet;
  try {
    sheet = await PetSheets.instance.load(pack, anim, bundle);
    final window = anim.box.expandToInclude(pack.contentBox);
    var k = liveArtSide / math.max(window.width, window.height);
    if (pack.pixelArt && k >= 1) k = k.floorToDouble();
    final width = math.max(1, (window.width * k).round());
    final height = math.max(1, (window.height * k).round());
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      sheet,
      anim.sourceRect(anim.frames.first.i),
      Rect.fromLTWH(
        (anim.box.left - window.left) * k,
        (anim.box.top - window.top) * k,
        anim.box.width * k,
        anim.box.height * k,
      ),
      ui.Paint()..filterQuality = pack.pixelArt ? ui.FilterQuality.none : ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      final png = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      return LiveArt(key: '${pack.id}/${anim.name}/${_digest(png)}', png: png, pixelArt: pack.pixelArt);
    } finally {
      image.dispose();
    }
  } on Object catch (error) {
    // The picture is decoration: the card goes out without it.
    debugPrint('live activity: no still for ${pack.id}/${mood.name} ($error)');
    return null;
  } finally {
    sheet?.dispose();
  }
}

/// FNV-1a, 32 bits: tells a re-imported pet's new picture from the old one.
String _digest(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}
