import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:dsh_app/themes/theme_library.dart';
import 'package:dsh_app/themes/theme_pack.dart';
import 'package:dsh_app/ui/workshop/workshop_theme_auto_cover.dart';
import 'package:dsh_app/workshop/workshop_models.dart';
import 'package:dsh_app/workshop/workshop_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ThemeLibrary local;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('theme-auto-cover-test-');
    local = ThemeLibrary(() async => Directory('${root.path}/local'));
  });
  tearDown(() async => root.delete(recursive: true));

  test('installed theme renders a square PNG accepted by the workshop', () async {
    final pack = await local.saveCustom(
      ThemePack.parse({
        'schema': 1,
        'id': 'local-theme',
        'name': 'Local theme',
        'palette': {
          'light': {'userBubble': '#D22740'},
        },
      }),
    );
    final png = await workshopGenerateThemeCover(library: local, localId: pack.id);
    final preview = WorkshopPreviewInput.themePng(png);
    expect(preview.source, 'theme-preview');
    expect((preview.width, preview.height), (workshopPreviewSide, workshopPreviewSide));
    expect(preview.size, lessThanOrEqualTo(workshopPreviewBytes));
    // Inside the user bubble but clear of its text.
    expect(await _pixelAt(png, 270, 194), 0xD22740FF);
  });

  test('a staged ZIP uses its own same-ID backdrop and crops without stretching', () async {
    const red = ui.Color(0xFFD22740);
    const blue = ui.Color(0xFF2F52D2);
    const green = ui.Color(0xFF25B66B);
    final background = await _stripedPng(red, green);
    final stagedBackground = await _stripedPng(red, blue);
    final top = ThemePack.parse({
      'schema': 1,
      'id': 'shared-id',
      'name': 'Shared ID',
      'surfaces': {'backdropImage': 'stripes.png', 'backdropOpacity': 1, 'backdropAlign': 'top'},
    });
    final bottom = top.copyWith(surfaces: top.surfaces.copyWith(backdropAlign: ThemeBackdropAlign.bottom));
    final installed = await local.saveCustom(top, assets: {'stripes.png': background});
    final zip = File('${root.path}/picked.zip');
    final manifest = utf8.encode(jsonEncode(bottom.toJson()));
    final archive = Archive()
      ..addFile(ArchiveFile.bytes('wrapper/theme.json', manifest))
      ..addFile(ArchiveFile.bytes('wrapper/stripes.png', stagedBackground));
    await zip.writeAsBytes(ZipEncoder().encode(archive));
    final staged = ThemeLibrary(() async => Directory('${root.path}/staging'));
    final stagedInstall = await staged.install(zip);
    expect(stagedInstall.id, installed.id);

    final localPng = await workshopGenerateThemeCover(library: local, localId: installed.id);
    final stagedPng = await workshopGenerateThemeCover(library: staged, localId: stagedInstall.id);
    // An uncovered part of the square, a quarter of the way down. Stretching
    // the portrait instead of cropping would leave both covers red here.
    expect(await _pixelAt(localPng, 8, 128), 0xD22740FF);
    expect(await _pixelAt(stagedPng, 8, 128), 0x2F52D2FF);
    expect((await local.load(installed.id)).surfaces.backdropAlign, ThemeBackdropAlign.top);
  });

  test('rejects an ID outside the publishable theme namespace', () async {
    await expectLater(
      workshopGenerateThemeCover(library: local, localId: 'user-../outside'),
      throwsA(isA<ThemeImportException>().having((e) => e.problem, 'problem', ThemeImportProblem.badPack)),
    );
  });
}

Future<Uint8List> _stripedPng(ui.Color top, ui.Color bottom) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawRect(const ui.Rect.fromLTWH(0, 0, 48, 72), ui.Paint()..color = top)
    ..drawRect(const ui.Rect.fromLTWH(0, 72, 48, 72), ui.Paint()..color = bottom);
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(48, 144);
    try {
      return Uint8List.sublistView((await image.toByteData(format: ui.ImageByteFormat.png))!);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

Future<int> _pixelAt(Uint8List png, int x, int y) async {
  final codec = await ui.instantiateImageCodec(png);
  try {
    final image = (await codec.getNextFrame()).image;
    try {
      final rgba = (await image.toByteData())!;
      return rgba.getUint32((y * image.width + x) * 4);
    } finally {
      image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
