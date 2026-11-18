part of '../plugins_state.dart';

// ── Market index ─────────────────────────────────────────────────────────────

typedef MarketIndexFetcher = Future<MarketIndex> Function(Uri url);

/// Thrown when the index could not be downloaded.
class MarketFetchException implements Exception {
  const MarketFetchException(this.message, {this.statusCode});
  final String message;

  /// The HTTP status when the server answered with something other than 200.
  final int? statusCode;

  @override
  String toString() => message;
}

/// GETs [url] and reads it in a background isolate (≈3 MB for dshfind).
Future<MarketIndex> fetchMarketIndex(Uri url) async {
  final body = (await fetchMarketFile(url)).text!;
  return Isolate.run(() => parseMarketIndexText(body, url));
}

/// One market file and its ETag; [text] is null when the server answered
/// 304 to the [etag] sent (the copy that has it is current).
typedef MarketFile = ({String? text, String? etag});

typedef MarketFileFetcher = Future<MarketFile> Function(Uri url, {String? etag});

/// GETs [url], with `If-None-Match: [etag]` when given.
Future<MarketFile> fetchMarketFile(Uri url, {String? etag}) async {
  final http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..userAgent = 'dsh-app';
  try {
    final request = await http.getUrl(url);
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (etag != null) request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (etag != null && response.statusCode == HttpStatus.notModified) {
      await response.drain<void>();
      return (text: null, etag: etag);
    }
    if (response.statusCode != HttpStatus.ok) {
      // The error page is unused; finally closes this request's client.
      throw MarketFetchException(appL10n.stateMarketHttpError(response.statusCode), statusCode: response.statusCode);
    }
    final text = await response
        .transform(utf8.decoder)
        .fold(StringBuffer(), (buffer, chunk) {
          if (buffer.length + chunk.length > 32 * 1024 * 1024) {
            throw MarketFetchException(appL10n.stateMarketTooLarge);
          }
          return buffer..write(chunk);
        })
        .timeout(const Duration(seconds: 60));
    return (text: text.toString(), etag: response.headers.value(HttpHeaders.etagHeader));
  } on SocketException {
    throw MarketFetchException(appL10n.stateMarketUnreachable);
  } on TimeoutException {
    throw MarketFetchException(appL10n.stateMarketTimeout);
  } on HttpException {
    throw MarketFetchException(appL10n.stateMarketInterrupted);
  } on TlsException {
    // The handshake or the certificate (HandshakeException, CertificateException):
    // a captive portal, a proxy or a wrong clock, never the catalog's format.
    throw MarketFetchException(appL10n.stateMarketInsecure);
  } on IOException {
    throw MarketFetchException(appL10n.stateMarketUnreachable);
  } on OSError {
    throw MarketFetchException(appL10n.stateMarketUnreachable);
  } finally {
    http.close(force: true);
  }
}

final marketIndexFetcherProvider = Provider<MarketIndexFetcher>((ref) => fetchMarketIndex);

/// One market entry with what the list needs precomputed.
class MarketEntry {
  MarketEntry(this.plugin, {required this.webOnly, required this.categoryTitle, this.category, this.listing})
    : haystack = _haystack(plugin, listing),
      featured = plugin.labels.contains('featured');

  final MarketPlugin plugin;

  /// Likely only affects the DSH web UI ([isWebOnlyPlugin]).
  final bool webOnly;
  final bool featured;
  final String? categoryTitle;

  /// Keep the declaration so a cached entry can follow the current UI locale.
  /// [categoryTitle] remains the fallback for callers with only a plain label.
  final MarketDeclaration? category;

  String? categoryTitleIn(String locale) => category?.title.resolve(locale) ?? categoryTitle;

  /// The official sidecar's word on the pinned version; null outside the
  /// official index (dshfind) or when the sidecar doesn't list it.
  final DshGoListing? listing;

  /// Lowercased name, titles, descriptions, keywords and author.
  final String haystack;

  String get name => plugin.name;

  /// The official section it is listed under, if any.
  MarketSection? get section => switch (listing) {
    DshGoListing(tier: MarketTier.official) => MarketSection.official,
    final listing? when listing.isAdapted => MarketSection.adapted,
    _ => null,
  };

  /// The sidecar's title in [locale], else the index's.
  String title([String locale = 'zh']) => listing?.title?.resolve(locale) ?? plugin.displayTitle(locale);

  /// The sidecar's summary in [locale], else the index's description.
  String? summary([String locale = 'zh']) => listing?.summary?.resolve(locale) ?? plugin.displayDescription(locale);

  static String _haystack(MarketPlugin p, DshGoListing? listing) => [
    p.name,
    ...?p.title?.all,
    ...?p.description?.all,
    ...?listing?.title?.all,
    ...?listing?.summary?.all,
    ...p.keywords,
    ?p.author,
  ].join('\n').toLowerCase();

  /// Every whitespace-separated term is a substring (works for Chinese
  /// without tokenizing: "小说 写作" matches "小说创作…写作").
  bool matches(List<String> terms) => terms.every(haystack.contains);
}

/// The two sections the official index fills (§2); 全部 is everything.
enum MarketSection { official, adapted }

/// The fetched index plus derived entries.
class MarketCatalog {
  /// [listings] (the official sidecar) apply to the version the index pins;
  /// one written for another version is ignored.
  MarketCatalog(this.index, {Map<String, DshGoListing> listings = const {}})
    : entries = [
        for (final plugin in index.plugins)
          MarketEntry(
            plugin,
            webOnly: isWebOnlyPlugin(plugin, index),
            categoryTitle: index.categories[plugin.category]?.title.resolve('zh'),
            category: index.categories[plugin.category],
            listing: listings[plugin.name]?.version == plugin.latest.version ? listings[plugin.name] : null,
          ),
      ];

  MarketCatalog._(this.index, this.entries);

  /// [all] with [official]'s entry in place of its own for the same package
  /// (the pinned version and its risk), and the official entries [all]
  /// doesn't have added at the end.
  factory MarketCatalog.merged(MarketCatalog all, MarketCatalog official) {
    final listed = {for (final e in all.entries) e.name};
    return MarketCatalog._(all.index, [
      for (final e in all.entries) official.byName[e.name] ?? e,
      for (final e in official.entries)
        if (!listed.contains(e.name)) e,
    ]);
  }

  final MarketIndex index;
  final List<MarketEntry> entries;

  late final Map<String, MarketEntry> byName = {for (final e in entries) e.name: e};

  /// Declared categories that have at least one entry, in index order.
  late final List<MarketDeclaration> categories = [
    for (final declaration in index.categories.values)
      if (entries.any((e) => e.plugin.category == declaration.id)) declaration,
  ];
}

/// Fetched once per app session (kept in memory); `ref.invalidate` reloads.
final marketCatalogProvider = FutureProvider<MarketCatalog>((ref) async {
  final index = await ref.watch(marketIndexFetcherProvider)(Uri.parse(dshfindIndexUrl));
  return MarketCatalog(index);
}, retry: (_, _) => null);

// ── Official index ───────────────────────────────────────────────────────────

/// The official market (docs/design/plugin-market.md): a format-1 index with
/// one pinned version per plugin, and the DSH Go sidecar (`dsh-go.json`)
/// beside it, read from [officialMarketBases]. Wherever it was read, the
/// index is the Worker's (this URL resolves its links).
const officialIndexUrl = 'https://go.dshtui.com/market/index.json';

/// Where both files are read, in turn: the public bucket the Worker's cron
/// writes (no Worker request), then the Worker.
const officialMarketBases = ['https://dl.dshtui.com/market/', 'https://go.dshtui.com/market/'];

/// How long the copy on the phone is used without asking the server.
const officialMarketFresh = Duration(hours: 6);

const _officialCopyKey = 'market.official';

typedef OfficialMarketFetcher = Future<MarketCatalog> Function();

bool _notPublished(Object? error) => error is MarketFetchException && error.statusCode == 404;

/// The last official catalog that read well, kept between sessions.
typedef _OfficialCopy = ({String index, String? indexTag, String sidecar, String? sidecarTag, DateTime at});

Future<_OfficialCopy?> _readOfficialCopy() async {
  try {
    final json =
        jsonDecode((await SharedPreferences.getInstance()).getString(_officialCopyKey)!) as Map<String, Object?>;
    return (
      index: json['index']! as String,
      indexTag: json['indexTag'] as String?,
      sidecar: json['sidecar']! as String,
      sidecarTag: json['sidecarTag'] as String?,
      at: DateTime.parse(json['at']! as String),
    );
  } catch (_) {
    return null; // none yet, or unreadable: as if none
  }
}

Future<void> _writeOfficialCopy(_OfficialCopy copy) async {
  try {
    await (await SharedPreferences.getInstance()).setString(
      _officialCopyKey,
      jsonEncode({
        'index': copy.index,
        'indexTag': copy.indexTag,
        'sidecar': copy.sidecar,
        'sidecarTag': copy.sidecarTag,
        'at': copy.at.toUtc().toIso8601String(),
      }),
    );
  } catch (_) {
    // No preferences (tests without a mock): the next session asks again.
  }
}

Future<MarketCatalog> _officialCatalog(String index, MarketSidecar sidecar) async {
  final url = Uri.parse(officialIndexUrl);
  return MarketCatalog(await Isolate.run(() => parseMarketIndexText(index, url)), listings: sidecar.plugins);
}

/// Both files from [base]. A sidecar that is missing or not schema 1 leaves
/// the plugins without a tier; one that can't be fetched fails the read, so a
/// network problem doesn't pass for 暂无. The pair is kept when every plugin
/// has its listing for the pinned version (the edge may briefly serve one
/// file newer than the other).
Future<MarketCatalog> _readOfficial(String base, MarketFileFetcher get, _OfficialCopy? copy) async {
  final sidecarFile = get(Uri.parse('${base}dsh-go.json'), etag: copy?.sidecarTag);
  unawaited(sidecarFile.then((_) {}, onError: (Object _) {}));
  final indexFile = await get(Uri.parse('${base}index.json'), etag: copy?.indexTag);
  final index = indexFile.text ?? copy!.index;
  String? sidecarText;
  String? sidecarTag;
  var sidecar = MarketSidecar.empty;
  try {
    final file = await sidecarFile;
    sidecarText = file.text ?? copy!.sidecar;
    sidecarTag = file.etag;
    sidecar = parseMarketSidecarText(sidecarText);
  } on MarketIndexException {
    sidecarText = null;
  } on MarketFetchException catch (error) {
    if (!_notPublished(error)) rethrow;
  }
  final catalog = await _officialCatalog(index, sidecar);
  if (sidecarText != null && catalog.entries.every((e) => e.listing != null)) {
    await _writeOfficialCopy((
      index: index,
      indexTag: indexFile.etag,
      sidecar: sidecarText,
      sidecarTag: sidecarTag,
      at: DateTime.now(),
    ));
  }
  return catalog;
}

/// The official catalog: the copy on the phone while it is younger than
/// [officialMarketFresh] (unless [refresh]); else both files from the first
/// of [officialMarketBases] that serves them, sending the copy's ETags (304:
/// still current); else, offline, the copy at any age. Without a copy, an
/// index published nowhere (404) is an empty market and other failures fail.
Future<MarketCatalog> fetchOfficialMarket({MarketFileFetcher get = fetchMarketFile, bool refresh = false}) async {
  final copy = await _readOfficialCopy();
  if (copy != null && !refresh && DateTime.now().difference(copy.at) < officialMarketFresh) {
    return _officialCatalog(copy.index, parseMarketSidecarText(copy.sidecar));
  }
  Object? failure;
  for (final base in officialMarketBases) {
    try {
      return await _readOfficial(base, get, copy);
    } on Object catch (error) {
      failure = error;
    }
  }
  if (copy != null) return _officialCatalog(copy.index, parseMarketSidecarText(copy.sidecar));
  if (_notPublished(failure)) {
    return MarketCatalog(MarketIndex(url: Uri.parse(officialIndexUrl), title: LocalizedText.plain('go.dshtui.com')));
  }
  throw failure!;
}

/// The first read in a session may use the copy on the phone; any later one
/// is a pull to refresh or 重试 (both invalidate [officialMarketProvider]) and
/// asks the server.
final officialMarketFetcherProvider = Provider<OfficialMarketFetcher>((ref) {
  final get = ref.watch(marketFileFetcherProvider);
  var reads = 0;
  return () => fetchOfficialMarket(get: get, refresh: reads++ > 0);
});

final marketFileFetcherProvider = Provider<MarketFileFetcher>((ref) => fetchMarketFile);

/// Read once per app session like dshfind's (the copy on the phone may
/// answer: [fetchOfficialMarket]); the chat's 生成 entry reads it too (the
/// media plugin it offers).
final officialMarketProvider = FutureProvider<MarketCatalog>(
  (ref) => ref.watch(officialMarketFetcherProvider)(),
  retry: (_, _) => null,
);

/// 全部: dshfind with the official entries merged in; dshfind alone while
/// the official index loads or when it failed.
final marketAllProvider = Provider<AsyncValue<MarketCatalog>>((ref) {
  final official = ref.watch(officialMarketProvider).value;
  return ref
      .watch(marketCatalogProvider)
      .whenData((all) => official == null ? all : MarketCatalog.merged(all, official));
});

/// [section]'s entries passing the search box, in index order. Categories
/// and the web-only switch belong to 全部.
List<MarketEntry> marketSection(MarketCatalog official, MarketSection section, MarketFilter filter) {
  final terms = filter.terms;
  return [
    for (final entry in official.entries)
      if (entry.section == section && (terms.isEmpty || entry.matches(terms))) entry,
  ];
}

/// The app's own version, for `dshGo.minApp`.
final appVersionProvider = Provider<AppVersion>((ref) => AppVersion.tryParse(AppInfo.version)!);

/// The version [entry] needs when this app is older: it shows but doesn't
/// install. Null when it can be installed.
AppVersion? marketNeedsApp(MarketEntry entry, AppVersion app) {
  final min = entry.listing?.minApp;
  return min != null && min.isNewerThan(app) ? min : null;
}

/// [installed] (the host's copy of [entry]'s package) is a withdrawn version.
bool marketBlockedInstall(MarketEntry entry, PluginBundle? installed) {
  final version = installed?.version;
  return version != null &&
      (installed!.installed || installed.availability == 'profile') &&
      (entry.listing?.blockedVersions.contains(version) ?? false);
}

typedef NpmIntegrityReader = Future<String?> Function(String name, String version);

/// What npm reports as `dist.integrity` for `name@version` (the public
/// registry, then npmmirror); null when neither answers in time.
///
/// The host can't be asked: `pluginManager/inspect` and the install result
/// carry no integrity, and pnpm checks the tarball against whichever
/// registry the host uses without saying what it saw. So this proves the
/// registry serves the version the market checked, not the host's download.
final npmIntegrityProvider = Provider<NpmIntegrityReader>((ref) {
  final net = ref.watch(shareNetProvider);
  return (name, version) async =>
      (await net.npmFacts(name, version).timeout(const Duration(seconds: 10), onTimeout: () => null))?.integrity;
});

/// [entry]'s pinned `name@version`; an npm entry the sidecar gives an
/// integrity for is checked against the registry before pnpm runs.
PluginInstallRequest marketInstallRequest(MarketEntry entry, {bool replace = false}) {
  final plugin = entry.plugin;
  final latest = plugin.latest;
  final target = latest.installTarget(plugin.name);
  final integrity = latest.source is MarketNpmSource ? entry.listing?.integrity : null;
  return PluginInstallRequest(
    name: plugin.name,
    spec: target.spec,
    registry: target.registry,
    title: entry.title(AppLocale.current.languageCode),
    published: latest.published,
    replaceInstalled: replace,
    integrity: integrity == null ? null : (version: latest.version, integrity: integrity),
  );
}

const _webOnlyCategoryIds = {'ui', 'skin', 'skins', 'theme', 'themes', 'client', 'clients', 'web', 'webui', 'web-ui'};
final _webOnlyCategoryTitle = RegExp(r'\b(?:ui|themes?|skins?|panels?|clients?|appearance)\b', caseSensitive: false);
final _webOnlyName = RegExp(r'(?:client-ui|web-ui|webui|(?:^|[-/])(?:themes?|skins?)(?:-|$))');

/// Heuristic for "only changes the DSH web UI or is a separate client".
///
/// Format 1 has no surface field, so this reads what indexes do carry:
/// * the category id: dshfind `ui` (Panels & Views), `skin` (Skins & Themes),
///   `client` (Clients, e.g. dsh-TUI); awesome-dsh-plugin `ui`, `theme`;
/// * otherwise the category's English title (UI / theme / skin / panel /
///   client / appearance), for other indexes;
/// * for uncategorized entries, package names like `dsh-client-ui-*`,
///   `*-web-ui`, `*-theme`, `skin-*`.
/// Such plugins load into DSH's web profile but do nothing for this app's
/// native chat; they are hidden by default behind 「显示网页版插件」.
bool isWebOnlyPlugin(MarketPlugin plugin, MarketIndex index) {
  final category = plugin.category;
  if (category != null) {
    if (_webOnlyCategoryIds.contains(category.toLowerCase())) return true;
    final title = index.categories[category]?.title;
    if (title != null && _webOnlyCategoryTitle.hasMatch(title.values['en'] ?? title.resolve('en'))) {
      return true;
    }
  }
  return _webOnlyName.hasMatch(plugin.name);
}

/// Search box, category chip and the web-only switch.
class MarketFilter {
  const MarketFilter({this.query = '', this.category, this.showWebOnly = false});

  final String query;

  /// Category id; null = all.
  final String? category;
  final bool showWebOnly;

  List<String> get terms =>
      query.trim().toLowerCase().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList(growable: false);

  MarketFilter copyWith({String? query, String? Function()? category, bool? showWebOnly}) => MarketFilter(
    query: query ?? this.query,
    category: category == null ? this.category : category(),
    showWebOnly: showWebOnly ?? this.showWebOnly,
  );
}

class MarketFilterController extends Notifier<MarketFilter> {
  @override
  MarketFilter build() => const MarketFilter();

  void setQuery(String query) => state = state.copyWith(query: query);

  void setCategory(String? category) => state = state.copyWith(category: () => category);

  void setShowWebOnly(bool show) => state = state.copyWith(showWebOnly: show);
}

final marketFilterProvider = NotifierProvider<MarketFilterController, MarketFilter>(MarketFilterController.new);

/// Entries passing [filter], in index order. Pure for testing.
List<MarketEntry> filterMarket(MarketCatalog catalog, MarketFilter filter) {
  final terms = filter.terms;
  final category = filter.category;
  return [
    for (final entry in catalog.entries)
      if ((filter.showWebOnly || !entry.webOnly || category != null && entry.plugin.category == category) &&
          (category == null || entry.plugin.category == category) &&
          (terms.isEmpty || entry.matches(terms)))
        entry,
  ];
}

/// How many entries the web-only switch hides for the current filter.
int hiddenWebOnlyCount(MarketCatalog catalog, MarketFilter filter) {
  if (filter.showWebOnly) return 0;
  return filterMarket(catalog, filter.copyWith(showWebOnly: true)).length - filterMarket(catalog, filter).length;
}

final marketResultsProvider = Provider<AsyncValue<List<MarketEntry>>>((ref) {
  final filter = ref.watch(marketFilterProvider);
  return ref.watch(marketCatalogProvider).whenData((catalog) => filterMarket(catalog, filter));
});
