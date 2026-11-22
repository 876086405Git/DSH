// Settings search: one query against every page and row of the settings
// index and every 全部功能 card, in Chinese and English at once whatever the
// app's language, by title, synonyms (old names among them) and the way
// there. docs/design/settings-ia.md §4.5.

import '../../../l10n/l10n.dart';
import '../../features/feature_catalog.dart' show FeatureItem, FeatureSection;
import '../index/spots.dart';

/// Lower case, full-width forms folded to ASCII, no spaces: 「ＡＰＩ Key」
/// and 「apikey」 read alike.
String normalizeQuery(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    var r = rune;
    if (r == 0x3000) continue; // ideographic space
    if (r >= 0xFF01 && r <= 0xFF5E) r -= 0xFEE0;
    final c = String.fromCharCode(r);
    if (c.trim().isEmpty) continue;
    out.write(c.toLowerCase());
  }
  return out.toString();
}

/// How a query met an entry, best first.
enum SearchMatch {
  titleExact(100),
  titlePrefix(80),
  title(60),
  synonymExact(50),
  synonym(40),
  path(20);

  const SearchMatch(this.score);
  final int score;

  bool get bySynonym => this == synonymExact || this == synonym;
}

/// One result: a settings page or row, or a 全部功能 card.
class SearchHit {
  const SearchHit._({this.spot, this.feature, this.section, required this.match, required this.score, this.synonym});

  final SettingSpot? spot;
  final FeatureItem? feature;

  /// The 全部功能 group a [feature] sits in.
  final FeatureSection? section;
  final SearchMatch match;
  final int score;

  /// The synonym that matched, when the title didn't (shown after it).
  final String? synonym;

  bool get isFeature => feature != null;
}

/// The words an entry answers to in one language.
class _Words {
  _Words(String title, List<String> synonyms, String path)
    : title = normalizeQuery(title),
      synonyms = [for (final s in synonyms) (text: s.trim(), normalized: normalizeQuery(s))],
      path = normalizeQuery(path);

  final String title;
  final List<({String text, String normalized})> synonyms;
  final String path;
}

(SearchMatch, String?)? _best(String q, List<_Words> langs) {
  (SearchMatch, String?)? best;
  void take(SearchMatch m, [String? synonym]) {
    if (best == null || m.score > best!.$1.score) best = (m, synonym);
  }

  for (final w in langs) {
    final title = w.title;
    if (title == q) {
      take(SearchMatch.titleExact);
    } else if (title.startsWith(q)) {
      take(SearchMatch.titlePrefix);
    } else if (title.contains(q)) {
      take(SearchMatch.title);
    }
    for (final s in w.synonyms) {
      final n = s.normalized;
      if (n.isEmpty) continue;
      if (n == q) {
        take(SearchMatch.synonymExact, s.text);
      } else if (n.contains(q)) {
        take(SearchMatch.synonym, s.text);
      }
    }
    if (w.path.contains(q)) take(SearchMatch.path);
  }
  return best;
}

List<String> _split(String? list) => [
  for (final s in (list ?? '').split(','))
    if (s.trim().isNotEmpty) s.trim(),
];

/// At most this many results.
const searchLimit = 20;

/// The results for [query]: settings ([spots], pages and rows) and
/// 全部功能's cards ([features]), scored by how they matched plus how often
/// people come for them, best first, [searchLimit] at most. Matches in [zh]
/// and [en] alike. Without [androidFeatures], nothing that is Android's own
/// ([SettingsIndex.androidOnly]), nor a word for what is only there
/// ([SettingSpot.ohosKeywords]); with them, nothing that is HarmonyOS's own.
/// On [ios], Android's own that it has too stays ([SettingSpot.iosToo]) and
/// HarmonyOS's own stays out.
List<SearchHit> searchSettings(
  String query, {
  required Iterable<SettingSpot> spots,
  required List<FeatureSection> features,
  required L10n zh,
  required L10n en,
  bool androidFeatures = true,
  bool ios = false,
}) {
  if (normalizeQuery(query).isEmpty) return const [];
  return SettingsSearchIndex(
    spots: spots,
    features: features,
    zh: zh,
    en: en,
    androidFeatures: androidFeatures,
    ios: ios,
  ).search(query);
}

/// Resolved, normalized words for one catalog and platform. The page keeps
/// this until its plugin settings or feature catalog changes, so typing only
/// normalizes the query, not every title, synonym and path again.
class SettingsSearchIndex {
  SettingsSearchIndex({
    required Iterable<SettingSpot> spots,
    required List<FeatureSection> features,
    required L10n zh,
    required L10n en,
    bool androidFeatures = true,
    bool ios = false,
  }) {
    final harmony = !androidFeatures && !ios;
    for (final spot in spots) {
      if (!androidFeatures && SettingsIndex.androidOnly(spot) && !(ios && spot.iosToo)) continue;
      if ((androidFeatures || ios) && spot.ohosOnly) continue;
      if (ios && spot.iosLacks) continue;
      _spots.add((
        spot: spot,
        langs: [
          for (final l in [zh, en])
            _Words(spot.titleOn(harmony: harmony)(l), [
              ..._split((harmony ? spot.ohosKeywords ?? spot.keywords : spot.keywords)?.call(l)),
              ?spot.altTitle?.call(l),
            ], SettingsIndex.path(spot, l).join(' ')),
        ],
      ));
    }
    for (final section in features) {
      for (final item in section.items) {
        // Cards that open a settings page are found as that page.
        if (SettingsIndex.linkIds.contains(item.id)) continue;
        _features.add((
          item: item,
          section: section,
          langs: [
            for (final l in [zh, en]) _Words(item.titleIn(l), const [], section.titleIn(l)),
          ],
        ));
      }
    }
  }

  final _spots = <({SettingSpot spot, List<_Words> langs})>[];
  final _features = <({FeatureItem item, FeatureSection section, List<_Words> langs})>[];

  List<SearchHit> search(String query) {
    final q = normalizeQuery(query);
    if (q.isEmpty) return const [];
    final hits = <SearchHit>[];
    for (final entry in _spots) {
      final best = _best(q, entry.langs);
      if (best == null) continue;
      hits.add(
        SearchHit._(
          spot: entry.spot,
          match: best.$1,
          score: best.$1.score + entry.spot.freq.bonus,
          synonym: best.$1.bySynonym ? best.$2 : null,
        ),
      );
    }
    for (final entry in _features) {
      final best = _best(q, entry.langs);
      if (best == null) continue;
      hits.add(SearchHit._(feature: entry.item, section: entry.section, match: best.$1, score: best.$1.score));
    }
    // Stable: a tie keeps the index's order (pages before rows, the hub first).
    final order = {for (final (i, h) in hits.indexed) h: i};
    hits.sort((a, b) => b.score != a.score ? b.score.compareTo(a.score) : order[a]!.compareTo(order[b]!));
    return hits.take(searchLimit).toList();
  }
}
