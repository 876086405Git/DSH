// 「我的分享链接」, the hosted links made on this phone. Each holds its
// decryption key and delete token, so the list lives in the Keystore-backed
// secure storage, like the API keys (settings_state.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../secrets/secure_storage.dart';
import 'hosted_client.dart';
import 'hosted_link.dart';

abstract class HostedLinkStore {
  Future<List<HostedLink>> load();
  Future<void> save(List<HostedLink> links);
}

class SecureHostedLinkStore implements HostedLinkStore {
  const SecureHostedLinkStore([this._injected]);

  static const storageKey = 'hosted_links';
  final FlutterSecureStorage? _injected;
  AppSecureStorage get _storage => AppSecureStorage(_injected);

  @override
  Future<List<HostedLink>> load() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [for (final item in list) ?HostedLink.fromJson(item)];
    } on FormatException {
      return const [];
    }
  }

  @override
  Future<void> save(List<HostedLink> links) =>
      _storage.write(key: storageKey, value: jsonEncode([for (final l in links) l.toJson()]));
}

final hostedLinkStoreProvider = Provider<HostedLinkStore>((ref) => const SecureHostedLinkStore());

final hostedShareClientProvider = Provider<HostedShareClient>((ref) {
  final client = HostedShareClient();
  ref.onDispose(client.close);
  return client;
});

/// A delete that didn't go through; the link is back in the list.
class HostedDeleteFailure {
  const HostedDeleteFailure(this.link, this.error);
  final HostedLink link;
  final HostedShareException error;
}

class HostedLinksState {
  const HostedLinksState({this.links = const [], this.loaded = false, this.failure});

  /// Newest first, including links waiting out the undo window.
  final List<HostedLink> links;
  final bool loaded;
  final HostedDeleteFailure? failure;

  /// What 「我的分享链接」 shows.
  List<HostedLink> get visible => [
    for (final l in links)
      if (!l.deleting) l,
  ];

  HostedLinksState copyWith({List<HostedLink>? links, bool? loaded, HostedDeleteFailure? failure}) =>
      HostedLinksState(links: links ?? this.links, loaded: loaded ?? this.loaded, failure: failure ?? this.failure);
}

class HostedLinksController extends Notifier<HostedLinksState> {
  /// How long a deleted link can be brought back.
  static const undoWindow = Duration(seconds: 4);

  /// Expired links stay listed (as 已过期) this long, then drop off.
  static const keepExpired = Duration(days: 30);

  final _timers = <String, Timer>{};
  late Future<void> _ready;
  bool _canSave = false;

  @override
  HostedLinksState build() {
    _canSave = false;
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
      _timers.clear();
    });
    _ready = _load();
    return const HostedLinksState();
  }

  /// Completes once the saved list is in.
  Future<void> get ready => _ready;

  Future<void> _load() async {
    final List<HostedLink> saved;
    try {
      saved = await ref.read(hostedLinkStoreProvider).load();
    } catch (_) {
      if (ref.mounted) state = state.copyWith(loaded: true);
      return;
    }
    if (!ref.mounted) return;
    _canSave = true;
    final cutoff = DateTime.now().subtract(keepExpired);
    final links = [
      for (final l in saved)
        if (l.expiresAt == null || l.expiresAt!.isAfter(cutoff)) l,
    ];
    state = state.copyWith(links: links, loaded: true);
    if (links.length != saved.length) await _save();
    // Deletes confirmed before the app last closed.
    for (final l in links) {
      if (l.deleting) unawaited(_commit(l.id));
    }
  }

  Future<void> _save() async {
    // Keep this run usable without replacing a collection we never read.
    if (!ref.mounted || !_canSave) return;
    try {
      await ref.read(hostedLinkStoreProvider).save(state.links);
    } catch (_) {
      // Keystore trouble: the list still works for this run.
    }
  }

  HostedLink? _find(String id) {
    for (final l in state.links) {
      if (l.id == id) return l;
    }
    return null;
  }

  void _put(List<HostedLink> links) =>
      state = HostedLinksState(links: links, loaded: state.loaded, failure: state.failure);

  void _mark(String id, bool deleting) =>
      _put([for (final l in state.links) l.id == id ? l.copyWith(deleting: deleting) : l]);

  /// Encrypts and uploads [file] (a `.dshgo` file's bytes), keeps the link and
  /// returns it. Throws [HostedShareException].
  Future<HostedLink> publish(Uint8List file, {required String title, HostedTtl ttl = HostedTtl.fallback}) async {
    final link = await ref.read(hostedShareClientProvider).upload(file, ttl, title: title);
    await add(link);
    return link;
  }

  Future<void> add(HostedLink link) async {
    await _ready;
    if (!ref.mounted) return;
    _put([
      link,
      for (final l in state.links)
        if (l.id != link.id) l,
    ]);
    await _save();
  }

  /// Hides [id] now and deletes it on the host once [undoWindow] passes
  /// without [undo].
  Future<void> remove(String id) async {
    await _ready;
    if (!ref.mounted || _find(id) == null) return;
    _mark(id, true);
    await _save();
    _timers.remove(id)?.cancel();
    _timers[id] = Timer(undoWindow, () {
      _timers.remove(id);
      unawaited(_commit(id));
    });
  }

  Future<void> undo(String id) async {
    _timers.remove(id)?.cancel();
    if (!ref.mounted || _find(id)?.deleting != true) return;
    _mark(id, false);
    await _save();
  }

  Future<void> _commit(String id) async {
    final link = _find(id);
    if (link == null || !link.deleting) return;
    try {
      await ref.read(hostedShareClientProvider).delete(link);
      if (!ref.mounted) return;
      _put([
        for (final l in state.links)
          if (l.id != id) l,
      ]);
    } catch (e) {
      if (!ref.mounted) return;
      _mark(id, false);
      final error = e is HostedShareException ? e : const HostedShareException(HostedShareError.network);
      state = state.copyWith(failure: HostedDeleteFailure(link.copyWith(deleting: false), error));
    }
    await _save();
  }
}

final hostedLinksProvider = NotifierProvider<HostedLinksController, HostedLinksState>(HostedLinksController.new);
