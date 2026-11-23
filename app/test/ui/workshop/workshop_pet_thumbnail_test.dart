import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/pets/pet_library.dart';
import 'package:dsh_app/ui/workshop/workshop_auto_cover.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import '../../workshop/support.dart';

void main() {
  test('pet thumbnail shows the specified first idle cell, not the first atlas cell', () async {
    final root = await Directory.systemTemp.createTemp('workshop-pet-cover-');
    addTearDown(() => root.delete(recursive: true));
    final pack = workshopPet();
    final idle = (pack['animations']! as Map)['idle'] as Map;
    idle['frames'] = [
      {'i': 1, 'ms': 200},
      {'i': 0, 'ms': 300},
    ];
    final sprite = image.Image(width: 32, height: 16, numChannels: 4);
    for (final pixel in sprite) {
      pixel.setRgba(pixel.x < 16 ? 255 : 0, 0, pixel.x < 16 ? 0 : 255, 255);
    }
    final zip = workshopZip(root, {'pack.json': utf8.encode(jsonEncode(pack)), 'idle.png': image.encodePng(sprite)});
    final library = PetLibrary(() async => Directory('${root.path}/pets'));
    final source = await library.install(zip);
    final png = await workshopGeneratePetThumbnail(library, source.id);
    final cover = image.decodePng(png)!;
    expect((cover.width, cover.height), (16, 16));
    final pixel = cover.getPixel(8, 8);
    expect((pixel.r, pixel.g, pixel.b, pixel.a), (0, 0, 255, 255));
  });
}
