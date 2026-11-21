import 'package:dsh_app/ui/companion/companion_stage.dart';
import 'package:flutter_test/flutter_test.dart';

const _gb = 1024 * 1024 * 1024;

void main() {
  group('her stage budget follows memory, not a guess at speed', () {
    test('a big iPhone draws like Android: screen density, full textures, its blur layers', () {
      expect(companionStageQuery(ios: true, totalMem: (5.6 * _gb).round()), {'antialias': '0'});
      expect(companionStageQuery(ios: false, totalMem: 8 * _gb), isEmpty);
    });

    test('a 4 GB phone only gets smaller textures', () {
      final reported = (3.7 * _gb).round();
      expect(companionStageQuery(ios: true, totalMem: reported), {'maxTexture': '2048', 'antialias': '0'});
      expect(companionStageQuery(ios: false, totalMem: reported), {'maxTexture': '2048'});
    });

    test('the smallest iPhones, or one that will not say, get the low GPU budget', () {
      const low = {'maxTexture': '1024', 'antialias': '0', 'dpr': '1.5', 'gpuBudget': 'low'};
      expect(companionStageQuery(ios: true, totalMem: (2.8 * _gb).round()), low);
      expect(companionStageQuery(ios: true, totalMem: 0), low);
      // Android's own small budget stays a texture size.
      expect(companionStageQuery(ios: false, totalMem: 2 * _gb), {'maxTexture': '2048'});
      expect(companionStageQuery(ios: false, totalMem: 0), isEmpty);
    });

    test('she starts where she settled last time; full resolution needs no word', () {
      expect(companionStageQuery(ios: false, totalMem: 8 * _gb, quality: 0.7), {'quality': '0.70'});
      expect(companionStageQuery(ios: false, totalMem: 8 * _gb, quality: 1), isEmpty);
      for (final odd in [0.2, 1.5, double.nan]) {
        expect(
          companionStageQuery(ios: false, totalMem: 8 * _gb, quality: odd),
          isEmpty,
          reason: '$odd',
        );
      }
    });

    test('reduced motion and the bare page still reach it', () {
      expect(companionStageQuery(ios: false, totalMem: 8 * _gb, reduceMotion: true, bare: true), {
        'reduceMotion': '1',
        'bare': '1',
      });
    });
  });
}
