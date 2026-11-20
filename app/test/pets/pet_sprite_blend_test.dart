// Smooth packs crossfade from one animation into the next; pixel art cuts.
import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/ui/pets/pet_sprite.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

final fish = diskPack('pink-fish');

Future<void> show(WidgetTester tester, PetPack pack, PetAnimation anim, {bool paused = false}) => tester.pumpWidget(
  MediaQuery(
    data: const MediaQueryData(),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: PetSprite(pack: pack, anim: anim, scale: 0.5, paused: paused),
      ),
    ),
  ),
);

PetSpriteState sprite(WidgetTester tester) => tester.state<PetSpriteState>(find.byType(PetSprite));

void main() {
  tearDown(PetSheets.instance.clear);

  testWidgets('a smooth pack fades the old animation out over petBlend', (tester) async {
    final idle = fish.animFor(PetStateName.idle);
    final next = fish.animFor(PetStateName.thinking);
    expect(fish.pixelArt, isFalse);
    expect(next, isNot(same(idle)));
    await warmSheets(tester, fish, [idle, next]);

    await show(tester, fish, idle);
    await tester.pump();
    expect(sprite(tester).shown, same(idle));
    expect(sprite(tester).blending, isFalse);

    await show(tester, fish, next);
    expect(sprite(tester).shown, same(next));
    expect(sprite(tester).blending, isTrue);

    await tester.pump(petBlend ~/ 2);
    expect(sprite(tester).blending, isTrue);
    await tester.pump(petBlend);
    expect(sprite(tester).blending, isFalse);
  });

  testWidgets('pausing mid-fade lands on the new picture at once', (tester) async {
    final idle = fish.animFor(PetStateName.idle);
    final next = fish.animFor(PetStateName.thinking);
    await warmSheets(tester, fish, [idle, next]);

    await show(tester, fish, idle);
    await tester.pump();
    await show(tester, fish, next);
    expect(sprite(tester).blending, isTrue);
    await show(tester, fish, next, paused: true);
    expect(sprite(tester).blending, isFalse);
    expect(sprite(tester).shown, same(next));
  });

  testWidgets('pixel art switches at once', (tester) async {
    final idle = deepy.animFor(PetStateName.idle);
    final next = deepy.animFor(PetStateName.thinking);
    await warmSheets(tester, deepy, [idle, next]);

    await show(tester, deepy, idle);
    await tester.pump();
    await show(tester, deepy, next);
    expect(sprite(tester).shown, same(next));
    expect(sprite(tester).blending, isFalse);
  });

  testWidgets('switching pets does not blend across packs', (tester) async {
    final from = deepy.animFor(PetStateName.idle);
    final to = fish.animFor(PetStateName.idle);
    await warmSheets(tester, deepy, [from]);
    await warmSheets(tester, fish, [to]);

    await show(tester, deepy, from);
    await tester.pump();
    await show(tester, fish, to);
    expect(sprite(tester).shown, same(to));
    expect(sprite(tester).blending, isFalse);
  });
}
