// Generation mode (docs/design/media-generation.md §4): whether this host has
// the media plugin, what it can generate with (`state/media_catalog.dart`,
// read from `settings/describe`), and the mode each conversation is in.
//
// Since the 2026-10-28 revision a generation goes out as an ordinary chat
// message with a parameter header (grammar v1, §4.6,
// `ui/chat/media/generate_header.dart`); the plugin's tool answers with the
// v1 `meta["dsh-go/media"]`.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/chat/media/generate_header.dart';
import 'engine_settings_state.dart';
import 'media_catalog.dart';
import 'plugins_state.dart';

export '../ui/chat/media/generate_header.dart' show GenerateHeader, GenerateHeaderCode, GenerateKind, GenerateModelTag;
export 'media_catalog.dart';

// ── The plugin ───────────────────────────────────────────────────────────────

/// Package names the media plugin goes by: `@dsh-go/media` (the official
/// market's), `@ccchimneyyy/dsh-media` (the personal scope it falls back to,
/// docs/design/plugin-market.md D1), and `dsh-media` under any scope.
bool isMediaPluginName(String name) =>
    name == '@dsh-go/media' || name == '@ccchimneyyy/dsh-media' || name == 'dsh-media' || name.endsWith('/dsh-media');

/// The plugin's settings namespace under its own name; a host may rename the
/// instance, and the catalogue's metadata finds it anyway
/// ([mediaNamespacesOf]).
const mediaSettingsNamespaces = ['dsh-media', 'media'];

/// Where the media plugin stands on the current host.
enum MediaPluginState {
  /// Not in the host's list at all: no 生成 tile.
  absent,

  /// Offered (the official catalogue lists it) but not installed, or
  /// installed and off: 生成 opens 「在此主机上安装」.
  installable,

  /// Installed and on.
  ready,
}

/// From the host's plugin list (`pluginManager/listBundles`), which the chat
/// page reads anyway; [offered]: the official market lists the plugin, so a
/// host without it can install it (D3: it isn't preinstalled).
MediaPluginState mediaPluginStateOf(List<PluginBundle>? bundles, {bool offered = false}) {
  if (bundles == null) return MediaPluginState.absent;
  final bundle = bundles.where((b) => isMediaPluginName(b.name)).firstOrNull;
  if (bundle == null) return offered ? MediaPluginState.installable : MediaPluginState.absent;
  if (bundle.installed && bundle.enabled && bundle.error == null) return MediaPluginState.ready;
  return MediaPluginState.installable;
}

/// The media plugin in the official market, which 「在此主机上安装」 installs;
/// null while the market loads, when it failed or doesn't list one.
final mediaMarketEntryProvider = Provider<MarketEntry?>(
  (ref) => ref.watch(
    officialMarketProvider.select((c) => c.value?.entries.where((e) => isMediaPluginName(e.name)).firstOrNull),
  ),
);

/// The plugin list's word, or ready when a running plugin serves a catalogue
/// (under a name of the host's choosing).
final mediaPluginProvider = Provider.autoDispose<MediaPluginState>((ref) {
  final listed = mediaPluginStateOf(
    ref.watch(installedPluginsProvider.select((s) => s.value)),
    // A host that takes no market installs isn't offered one.
    offered: ref.watch(mediaMarketEntryProvider) != null && !(ref.watch(pluginHostProvider)?.installRefused ?? false),
  );
  if (listed == MediaPluginState.ready) return listed;
  final serves = ref.watch(
    engineSettingsProvider.select((s) => s.value == null ? false : mediaNamespacesOf(s.value!.namespaces).isNotEmpty),
  );
  return serves ? MediaPluginState.ready : listed;
});

// ── The catalogue ────────────────────────────────────────────────────────────

/// What this host can generate with: its catalogue crossed with the services
/// configured there and the keys the host says are set.
final mediaCatalogProvider = Provider.autoDispose<MediaCatalog>((ref) {
  final settings = ref.watch(engineSettingsProvider);
  final value = settings.value;
  if (value == null) return settings.isLoading ? MediaCatalog.loading : MediaCatalog.missing;
  return mediaCatalogFrom(value.namespaces, credentials: value.credentials);
});

// ── The mode ─────────────────────────────────────────────────────────────────

const Object _keep = Object();

/// What generation mode will send: the model (where it is and its name) and
/// the header's values. A null value is left to the host and not written.
class GenerateParams {
  const GenerateParams({
    this.kind = GenerateKind.image,
    this.model,
    this.aspect,
    this.count = 1,
    this.quality,
    this.seconds,
    this.resolution,
  });

  static const video = GenerateParams(kind: GenerateKind.video);

  /// What the mode store kept. A mode the old app saved (a model id without a
  /// service) keeps its values and starts over on a default model.
  factory GenerateParams.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    T? read<T>(String key) => map[key] is T ? map[key] as T : null;
    return GenerateParams(
      kind: read<String>('kind') == 'video' ? GenerateKind.video : GenerateKind.image,
      model: MediaModelRef.fromJson(map['model']),
      aspect: read<String>('aspect'),
      count: read<num>('count')?.round().clamp(1, 4) ?? 1,
      quality: read<String>('quality'),
      seconds: read<num>('seconds')?.round(),
      resolution: read<String>('resolution'),
    );
  }

  final GenerateKind kind;
  final MediaModelRef? model;

  /// `3:4`; null: the host's.
  final String? aspect;

  /// Pictures (image).
  final int count;

  /// The catalogue's own value (image); null: 「自动」, the host's.
  final String? quality;

  /// Length (video).
  final int? seconds;

  /// `720p` (video).
  final String? resolution;

  bool get isVideo => kind == GenerateKind.video;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'model': ?model?.toJson(),
    'aspect': ?aspect,
    'count': count,
    'quality': ?quality,
    'seconds': ?seconds,
    'resolution': ?resolution,
  };

  /// These values with some replaced; pass null to clear one.
  GenerateParams copyWith({
    GenerateKind? kind,
    Object? model = _keep,
    Object? aspect = _keep,
    int? count,
    Object? quality = _keep,
    Object? seconds = _keep,
    Object? resolution = _keep,
  }) => GenerateParams(
    kind: kind ?? this.kind,
    model: identical(model, _keep) ? this.model : model as MediaModelRef?,
    aspect: identical(aspect, _keep) ? this.aspect : aspect as String?,
    count: count ?? this.count,
    quality: identical(quality, _keep) ? this.quality : quality as String?,
    seconds: identical(seconds, _keep) ? this.seconds : seconds as int?,
    resolution: identical(resolution, _keep) ? this.resolution : resolution as String?,
  );

  /// These values on their model — [catalog]'s default for the kind when
  /// there is none — each kept to what the model allows. An empty set of
  /// choices leaves that value to the host (null); nothing is made up. A
  /// model that no longer pins one choice stays as it is: the person picks.
  GenerateParams fitTo(MediaCatalog catalog) {
    final MediaEntry? entry;
    if (model == null) {
      entry = catalog.defaultFor(kind);
    } else {
      entry = catalog.resolve(model, kind);
      if (entry == null) return this;
    }
    if (entry == null) return this;
    final m = entry.model;
    String? pick(String? value, List<String> allowed, String preferred) {
      if (allowed.isEmpty) return null;
      if (value != null && allowed.contains(value)) return value;
      return allowed.contains(preferred) ? preferred : allowed.first;
    }

    int? nearest(int? value, List<int> allowed) {
      if (allowed.isEmpty) return null;
      if (value == null) return allowed.reduce((a, b) => a < b ? a : b);
      if (allowed.contains(value)) return value;
      return allowed.reduce((a, b) => (a - value).abs() <= (b - value).abs() ? a : b);
    }

    return GenerateParams(
      kind: kind,
      model: entry.ref,
      aspect: pick(aspect, m.ratios, isVideo ? '16:9' : '1:1'),
      count: isVideo ? 1 : count.clamp(1, m.maxN),
      quality: !isVideo && quality != null && m.qualities.contains(quality) ? quality : null,
      seconds: isVideo ? nearest(seconds, m.durations) : null,
      resolution: isVideo ? pick(resolution, m.resolutions, '720p') : null,
    );
  }

  /// Where a fresh mode starts on [catalog]: these values, the model dropped
  /// when it isn't one of this host's choices (it was another host's or
  /// conversation's), then fitted.
  GenerateParams startOn(MediaCatalog catalog) =>
      (catalog.resolve(model, kind) == null ? copyWith(model: null) : this).fitTo(catalog);

  /// A header sent earlier (编辑后重发) as a mode: exactly its values — an
  /// omitted one stays the host's — and its model by marker, else by a name
  /// only one choice has (§4.6.5); then fitted.
  factory GenerateParams.fromHeader(GenerateHeader header, MediaCatalog catalog) => GenerateParams(
    kind: header.kind,
    model: header.model == null ? null : catalog.refOfTag(header.model!, header.kind),
    aspect: header.aspect,
    count: header.count ?? 1,
    quality: header.quality,
    seconds: header.seconds,
    resolution: header.resolution,
  ).fitTo(catalog);

  /// A card's batch (↻, 修改) as a mode: its request's values, the model by
  /// provider and id when only one choice fits.
  factory GenerateParams.fromMeta(MediaMeta meta, MediaCatalog catalog) {
    final request = meta.request;
    final video = meta.kind == MediaKind.video;
    final kind = video ? GenerateKind.video : GenerateKind.image;
    return GenerateParams(
      kind: kind,
      model: catalog.refOfRequest(request, kind),
      aspect: request.aspect,
      count: video ? 1 : (request.n ?? (meta.items.isEmpty ? 1 : meta.items.length)),
      quality: video ? null : request.quality,
      seconds: video ? request.seconds?.round() : null,
      resolution: video ? request.resolution : null,
    ).fitTo(catalog);
  }

  /// The header for this request: the model with its marker when pinned.
  GenerateHeader get header => GenerateHeader(
    kind: kind,
    aspect: aspect,
    count: isVideo ? null : count,
    quality: isVideo ? null : quality,
    seconds: isVideo ? seconds : null,
    resolution: isVideo ? resolution : null,
    model: model?.tag,
  );

  /// The message for [description], or why not (§4.6.4).
  ({String? text, String? code}) tryMessage(String description) => header.tryMessage(description);

  @override
  bool operator ==(Object other) => other is GenerateParams && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// The mode of each conversation by draft key (`new` for the new-chat
/// screen), kept across launches; and the last values of each kind, which a
/// fresh mode starts from.
class GenerateModes {
  const GenerateModes({this.byKey = const {}, this.lastImage, this.lastVideo, this.lastKind = GenerateKind.image});

  final Map<String, GenerateParams> byKey;
  final GenerateParams? lastImage;
  final GenerateParams? lastVideo;
  final GenerateKind lastKind;

  /// What 「生成」 starts with: the kind used last, with its last values.
  GenerateParams get start => switch (lastKind) {
    GenerateKind.image => lastImage ?? const GenerateParams(),
    GenerateKind.video => lastVideo ?? GenerateParams.video,
  };

  GenerateParams startOf(GenerateKind kind) => switch (kind) {
    GenerateKind.image => lastImage ?? const GenerateParams(),
    GenerateKind.video => lastVideo ?? GenerateParams.video,
  };
}

class GenerateModeStore extends Notifier<GenerateModes> {
  static const prefsKey = 'media.generate.v1';

  /// The modes of at most this many conversations are kept.
  static const keep = 40;

  @override
  GenerateModes build() {
    unawaited(_load());
    return const GenerateModes();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null || !ref.mounted) return;
      final json = jsonDecode(raw);
      if (json is! Map) return;
      final modes = json['modes'];
      state = GenerateModes(
        byKey: {
          if (modes is Map)
            for (final MapEntry(:key, :value) in modes.entries)
              if (key is String && key != 'new') key: GenerateParams.fromJson(value),
          ...state.byKey,
        },
        lastImage: json['image'] == null ? state.lastImage : GenerateParams.fromJson(json['image']),
        lastVideo: json['video'] == null ? state.lastVideo : GenerateParams.fromJson(json['video']),
        lastKind: json['kind'] == 'video' ? GenerateKind.video : GenerateKind.image,
      );
    } catch (_) {
      // No preferences backend: modes last for this run.
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = state.byKey.entries.where((e) => e.key != 'new').toList();
      final kept = entries.length > keep ? entries.sublist(entries.length - keep) : entries;
      await prefs.setString(
        prefsKey,
        jsonEncode({
          'modes': {for (final e in kept) e.key: e.value.toJson()},
          'image': ?state.lastImage?.toJson(),
          'video': ?state.lastVideo?.toJson(),
          'kind': state.lastKind.name,
        }),
      );
    } catch (_) {}
  }

  /// [key] into generation mode with [params] (null: out of it, the text
  /// stays where it is).
  void set(String key, GenerateParams? params) {
    final byKey = {...state.byKey}..remove(key);
    if (params != null) byKey[key] = params;
    state = GenerateModes(
      byKey: Map.unmodifiable(byKey),
      lastImage: params != null && !params.isVideo ? params : state.lastImage,
      lastVideo: params != null && params.isVideo ? params : state.lastVideo,
      lastKind: params?.kind ?? state.lastKind,
    );
    unawaited(_save());
  }

  /// A new chat's mode follows it to the conversation it became.
  void move(String from, String to) {
    final params = state.byKey[from];
    if (params == null) return;
    final byKey = {...state.byKey}
      ..remove(from)
      ..[to] = params;
    state = GenerateModes(
      byKey: Map.unmodifiable(byKey),
      lastImage: state.lastImage,
      lastVideo: state.lastVideo,
      lastKind: state.lastKind,
    );
    unawaited(_save());
  }
}

final generateModeProvider = NotifierProvider<GenerateModeStore, GenerateModes>(GenerateModeStore.new);
