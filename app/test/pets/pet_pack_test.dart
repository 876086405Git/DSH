// The runtime pack format (docs/design/pets.md §3): the two whale packs (鲸娘,
// Deepy) parse with their measured values, animations resolve by state and
// tier, hit boxes by the documented lookup order, and broken packs are refused
// whole.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dsh_app/pets/pet_pack.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> _json(String id) =>
    jsonDecode(File('assets/pets/$id/pack.json').readAsStringSync()) as Map<String, Object?>;

/// A [math.Random] whose draw is fixed, so a pick can be checked.
class _Pick implements math.Random {
  _Pick(this.index);

  final int index;

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;

  @override
  int nextInt(int max) => index % max;
}

void main() {
  group('Deepy 小鲸鱼', () {
    test('canvas, 5× sheets, foot point, body', () {
      expect(deepy.id, 'deepy-whale');
      expect(deepy.name, 'Deepy 小鲸鱼');
      expect(deepy.scale, 5);
      expect(deepy.pixelArt, isTrue);
      expect(deepy.canvas, const Size(52, 52));
      expect(deepy.anchorX, 28);
      expect(deepy.baseline, 48);
      expect(deepy.contentBox, const Rect.fromLTWH(12, 26, 36, 22));
    });

    test('cells sit in a grid of cols, cropped to box', () {
      final idle = deepy.animFor(PetStateName.idle);
      expect(idle.name, 'idle');
      expect(idle.frameWidth, idle.box.width * 5);
      expect(idle.frameHeight, idle.box.height * 5);
      expect(idle.sourceRect(0), Rect.fromLTWH(0, 0, idle.frameWidth.toDouble(), idle.frameHeight.toDouble()));
      final next = idle.sourceRect(idle.cols);
      expect(next.left, 0, reason: 'cell `cols` starts the second row');
      expect(next.top, idle.frameHeight.toDouble());
      expect(idle.durationMs, idle.frames.fold<int>(0, (s, f) => s + f.ms));
    });

    test('every sheet fits a 4096 texture', () {
      for (final a in deepy.animations.values) {
        final cells = a.frames.map((f) => f.i).reduce((x, y) => x > y ? x : y) + 1;
        final rows = (cells / a.cols).ceil();
        expect(a.cols * a.frameWidth, lessThanOrEqualTo(4096), reason: a.name);
        expect(rows * a.frameHeight, lessThanOrEqualTo(4096), reason: a.name);
      }
    });

    test('states and tiers pick their animations', () {
      expect(deepy.animFor(PetStateName.thinking).name, 'thinking');
      expect(deepy.animFor(PetStateName.working, tier: 1).name, 'typing');
      expect(deepy.animFor(PetStateName.working, tier: 2).name, 'music');
      expect(deepy.animFor(PetStateName.working, tier: 3).name, 'building');
      expect(deepy.animFor(PetStateName.working, tier: 7).name, 'building');
      expect(deepy.animFor(PetStateName.juggling, tier: 1).name, 'music');
      expect(deepy.animFor(PetStateName.juggling, tier: 2).name, 'conducting');
      expect(deepy.animFor(PetStateName.notification).name, 'notification');
      expect(deepy.animFor(PetStateName.attention).name, 'happy');
      expect(deepy.animFor(PetStateName.error).name, 'error');
      expect(deepy.animFor(PetStateName.sweeping).name, 'compacting');
      expect(deepy.animFor(PetStateName.carrying).name, 'carrying');
      expect(deepy.animFor(PetStateName.sleeping).name, 'sleeping');
      expect(deepy.animFor(PetStateName.waking).name, 'waking');
    });

    test('reactions, walking, waking, timings', () {
      expect(deepy.reaction('tapLeft')!.name, 'react-left');
      expect(deepy.reaction('tapRight')!.name, 'react-right');
      expect(deepy.reaction('tickle')!.name, 'react-double');
      expect(deepy.reaction('drag')!.name, 'react-drag');
      expect(deepy.reaction('tapLeft')!.loop, isFalse);
      expect(deepy.reaction('drag')!.loop, isTrue);
      expect(deepy.roam.name, 'roam-hop');
      expect(deepy.roamFacing, PetFacing.left);
      expect(deepy.mirrorWalking(right: true), isTrue, reason: 'drawn facing left');
      expect(deepy.mirrorWalking(right: false), isFalse);
      expect(deepy.wakeDuration, 1500);
      expect(deepy.autoReturn.containsKey('notification'), isFalse, reason: 'notification waits until handled');
      expect(deepy.sleepAfter, const Duration(seconds: 60));
      expect(deepy.bonus, isEmpty);
    });

    test('hit boxes: byAnim, then sleeping, then wide, then default', () {
      final hits = _json('deepy-whale')['hitBoxes']! as Map<String, Object?>;
      Rect rect(Object? m) {
        final r = m! as Map<String, Object?>;
        return Rect.fromLTWH(
          (r['x']! as num).toDouble(),
          (r['y']! as num).toDouble(),
          (r['w']! as num).toDouble(),
          (r['h']! as num).toDouble(),
        );
      }

      final byAnim = hits['byAnim']! as Map<String, Object?>;
      for (final MapEntry(:key, :value) in byAnim.entries) {
        expect(deepy.hitBoxFor(deepy.animations[key]!), rect(value), reason: key);
      }
      for (final name in (hits['sleepingAnims']! as List).cast<String>()) {
        if (byAnim.containsKey(name)) continue;
        expect(deepy.hitBoxFor(deepy.animations[name]!), rect(hits['sleeping']), reason: name);
      }
      for (final name in (hits['wideAnims']! as List).cast<String>()) {
        if (byAnim.containsKey(name)) continue;
        expect(deepy.hitBoxFor(deepy.animations[name]!), rect(hits['wide']), reason: name);
      }
      expect(deepy.hitBoxFor(deepy.animations['idle']!), rect(hits['default']));
      expect(deepy.hitBoxFor(deepy.animations['thinking']!), rect(hits['default']), reason: 'the cloud is no body');
    });

    test('idle extras with their play times and interval', () {
      expect(deepy.idles.map((e) => e.anim), ['idle-look', 'idle-spout']);
      expect(deepy.idles.map((e) => e.ms), [6800, 6400]);
      expect(deepy.idleEvery.min, 45000);
      expect(deepy.idleEvery.max, 300000);
      expect(deepy.idleEvery.draw(0), const Duration(seconds: 45));
      expect(deepy.idleEvery.draw(0.999999), const Duration(minutes: 5));
      // The median of min + Exp(mean − min) ≈ 45 + 75 × ln 2 s.
      expect(deepy.idleEvery.draw(0.5).inSeconds, inInclusiveRange(95, 98));
    });
  });

  group('鲸娘', () {
    test('1× pixel art, front-facing swim, attention extras', () {
      expect(girl.name, '鲸娘');
      expect(girl.scale, 1);
      expect(girl.canvas, const Size(69, 66));
      expect(girl.anchorX, 35.5);
      expect(girl.baseline, 60);
      expect(girl.roam.name, 'swim');
      expect(girl.roamFacing, PetFacing.front);
      expect(girl.mirrorWalking(right: true), isFalse);
      expect(girl.mirrorWalking(right: false), isFalse);
      expect(girl.reaction('tapLeft')!.name, 'poke-left');
      expect(girl.reaction('tickle')!.name, 'tickle');
      final bonus = girl.bonusOf(PetStateName.attention)!;
      expect(bonus.anims, unorderedEquals(['smile-hearts', 'thumbs-up']));
      expect(bonus.chance, 0.2);
      expect(girl.wakeDuration, 1880);
      expect(
        girl.hitBoxFor(girl.animations['swim']!).height,
        greaterThan(girl.hitBoxFor(girl.animations['idle']!).height - 1),
      );
    });

    test('each strip is one row', () {
      for (final a in girl.animations.values) {
        final cells = a.frames.map((f) => f.i).reduce((x, y) => x > y ? x : y) + 1;
        expect(a.cols, greaterThanOrEqualTo(cells), reason: a.name);
      }
    });
  });

  group('reactions may list several animations (arrays and numbered keys)', () {
    PetPack withReactions(Object? reactions) => PetPack.parse({..._json('whale-girl'), 'reactions': reactions});

    test('a string is one animation, an array is a list', () {
      final pack = withReactions({
        'tapLeft': 'poke-left',
        'tickle': ['tickle', 'poke-left'],
      });
      expect(pack.reactions['tapLeft'], ['poke-left']);
      expect(pack.reactions['tickle'], ['tickle', 'poke-left']);
    });

    test('an empty array is no reaction, not an error', () {
      final pack = withReactions({'tapLeft': [], 'tickle': 'tickle'});
      expect(pack.reactions.containsKey('tapLeft'), isFalse);
      expect(pack.reaction('tapLeft'), isNull);
      expect(pack.reactions['tickle'], ['tickle']);
    });

    test('every name in an array must be an animation', () {
      expect(() => withReactions({'tickle': ['tickle', 'nope']}), throwsFormatException);
      expect(() => withReactions({'tickle': 42}), throwsFormatException, reason: 'neither a name nor an array');
      expect(() => withReactions({'tickle': 'tickle', 'tickle2': 'nope'}), throwsFormatException);
    });

    test('numbered keys merge into the plain one, whatever their order', () {
      final pack = withReactions({
        'tickle2': 'poke-left',
        'tickle': 'tickle',
        'tickle3': 'drag',
      });
      // The base name stays first: it is the one older apps play.
      expect(pack.reactions['tickle'], ['tickle', 'poke-left', 'drag']);
      expect(pack.reactions.keys, ['tickle']);
      expect(pack.reaction('tickle')!.name, 'tickle');
      expect(pack.reactionOutOf('tickle', _Pick(2))!.name, 'drag');
    });

    test('a numbered key without its plain one is a reaction of its own', () {
      final pack = withReactions({'tickle2': 'poke-left', 'tickle3': ['drag', 'tickle']});
      expect(pack.reactions['tickle2'], ['poke-left']);
      expect(pack.reactions['tickle3'], ['drag', 'tickle']);
      expect(pack.reactions.containsKey('tickle'), isFalse);
      // An empty base name is the same as no base name.
      final noBase = withReactions({'tickle': [], 'tickle2': 'poke-left'});
      expect(noBase.reactions, {
        'tickle2': ['poke-left'],
      });
    });

    test('arrays and numbered keys mix', () {
      final pack = withReactions({
        'tickle': ['tickle', 'poke-left'],
        'tickle2': 'drag',
      });
      expect(pack.reactions['tickle'], ['tickle', 'poke-left', 'drag']);
    });

    test('reaction() is the first; reactionOutOf() picks one per play', () {
      final pack = withReactions({
        'tapLeft': 'poke-left',
        'tickle': ['tickle', 'poke-left', 'drag'],
      });
      expect(pack.reaction('tickle')!.name, 'tickle');
      expect(pack.reaction('tapLeft')!.name, 'poke-left');
      // A lone animation: that one, whatever the dice say.
      expect(pack.reactionOutOf('tapLeft', _Pick(1))!.name, 'poke-left');
      // Several: the dice pick one of them; every entry is reachable.
      expect(pack.reactionOutOf('tickle', _Pick(0))!.name, 'tickle');
      expect(pack.reactionOutOf('tickle', _Pick(1))!.name, 'poke-left');
      expect(pack.reactionOutOf('tickle', _Pick(2))!.name, 'drag');
      expect(pack.reactionOutOf('nope', _Pick(0)), isNull);
    });
  });

  group('a pack that only writes idle still works', () {
    Map<String, Object?> animation(String sheet) => {
      'sheet': sheet,
      'frameW': 16,
      'frameH': 16,
      'cols': 1,
      'box': {'x': 0, 'y': 0, 'w': 16, 'h': 16},
      'frames': [
        {'i': 0, 'ms': 100},
      ],
    };

    Map<String, Object?> minimal({Map<String, Object?>? animations, Map<String, Object?>? states}) => {
      'schema': 1,
      'id': 'min',
      'canvas': {'w': 16, 'h': 16},
      'contentBox': {'x': 0, 'y': 0, 'w': 16, 'h': 16},
      'animations': animations ?? {'idle': animation('idle.png')},
      'states': states ?? {'idle': ['idle']},
    };

    test('states and tiers it does not name play idle', () {
      final pack = PetPack.parse(minimal());
      for (final state in PetStateName.values) {
        expect(pack.animFor(state).name, 'idle', reason: state.name);
      }
      expect(pack.tiers, isEmpty);
      expect(pack.animFor(PetStateName.working, tier: 3).name, 'idle', reason: 'no tiers: the one animation');
      expect(pack.roam.name, 'idle');
      expect(pack.bonusOf(PetStateName.attention), isNull);
      // Missing boxes and timings fall back to the documented defaults.
      expect(pack.hitBoxFor(pack.animations['idle']!), pack.contentBox);
      expect(pack.playOf(pack.animations['idle']!), 100);
      expect(pack.wakeDuration, 1500);
    });

    test('a reaction it does not write is simply absent', () {
      final pack = PetPack.parse(minimal());
      expect(pack.reactions, isEmpty);
      for (final key in ['tapLeft', 'tapRight', 'tickle', 'annoyed', 'drag']) {
        expect(pack.reaction(key), isNull, reason: key);
        expect(pack.reactionOutOf(key, _Pick(0)), isNull, reason: key);
      }
    });

    test('idle extras fall back to the idle state’s second animation', () {
      final pack = PetPack.parse(
        minimal(
          animations: {'idle': animation('idle.png'), 'idle-look': animation('idle-look.png')},
          states: {
            'idle': ['idle', 'idle-look'],
          },
        ),
      );
      expect(pack.idlePool, isEmpty);
      expect(pack.idles.map((e) => e.anim), ['idle-look']);
      expect(pack.idles.single.ms, pack.animations['idle-look']!.durationMs * 2);
    });
  });

  group('broken packs are refused', () {
    Map<String, Object?> base() => _json('whale-girl');

    test('another schema', () {
      expect(() => PetPack.parse({...base(), 'schema': 2}), throwsFormatException);
    });

    test('a state naming a missing animation', () {
      final json = base();
      final states = {
        ...json['states']! as Map<String, Object?>,
        'error': ['nope'],
      };
      expect(() => PetPack.parse({...json, 'states': states}), throwsFormatException);
    });

    test('a frame without time', () {
      final json = base();
      final anims = {...json['animations']! as Map<String, Object?>};
      final idle = {...anims['idle']! as Map<String, Object?>};
      idle['frames'] = [
        {'i': 0, 'ms': 0},
      ];
      anims['idle'] = idle;
      expect(() => PetPack.parse({...json, 'animations': anims}), throwsFormatException);
    });

    test('a reaction naming a missing animation', () {
      final json = base();
      expect(
        () => PetPack.parse({
          ...json,
          'reactions': {'tapLeft': 'nope'},
        }),
        throwsFormatException,
      );
    });
  });
}
