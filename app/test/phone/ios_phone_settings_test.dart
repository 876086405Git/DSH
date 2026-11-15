import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/links/page_links.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/ui/features/feature_catalog.dart';
import 'package:dsh_app/ui/settings/index/spots.dart';
import 'package:dsh_app/ui/settings/search/settings_search.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS search exposes phone control and return without Android setup pages', () {
    List<String?> search(String query, {bool ios = true}) => [
      for (final hit in searchSettings(
        query,
        spots: SettingsIndex.spots,
        features: featureSections,
        zh: lookupL10n(AppLocale.zhCN),
        en: lookupL10n(AppLocale.en),
        androidFeatures: false,
        ios: ios,
      ))
        hit.spot?.id,
    ];
    expect(search('手机操控'), contains('page:phone'));
    expect(search('完成后返回'), contains('phone-return'));
    expect(search('手机操控', ios: false), isNot(contains('page:phone')));
    expect(SettingsIndex.androidOnlyLink('phone', ios: true), isFalse);
    expect(SettingsIndex.androidOnlyLink('phone'), isTrue);
    expect(SettingsIndex.androidOnlyLink('phone-confirm', ios: true), isTrue);
  });

  test('iOS page links open phone control while HarmonyOS keeps its existing gate', () {
    final ios = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ios')]);
    final ohos = ProviderContainer(overrides: [operatingSystemProvider.overrideWithValue('ohos')]);
    addTearDown(ios.dispose);
    addTearDown(ohos.dispose);
    expect(ios.read(pageLinkResolverProvider)('phone', null), isNotNull);
    expect(ios.read(pageLinkResolverProvider)('phone-confirm', null), isNull);
    expect(ohos.read(pageLinkResolverProvider)('phone', null), isNull);
  });
}
