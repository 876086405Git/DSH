// Owns the local page for the second renderer of the existing PetOverlay.
// The native owner decides visibility, gestures and retry/fallback. Pixel
// selection does not resolve a pack, open a socket or allocate a WebView.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../l10n/l10n.dart';
import '../pets/overlay_channel.dart';
import '../pets/pet_prefs.dart';
import 'companion_pack.dart';
import 'companion_server.dart';

@immutable
class CompanionFloatOptions {
  const CompanionFloatOptions({this.enabled = false, this.zoom = 0.9, this.y = 0});

  final bool enabled;
  final double zoom;
  final double y;

  Map<String, String> get query => {
    'mode': 'float',
    'maxTexture': '2048',
    'maskSize': '1024',
    'antialias': '0',
    'floatZoom': '$zoom',
    'floatY': '$y',
  };

  @override
  bool operator ==(Object other) =>
      other is CompanionFloatOptions && other.enabled == enabled && other.zoom == zoom && other.y == y;
  @override
  int get hashCode => Object.hash(enabled, zoom, y);
}

@immutable
class CompanionFloatState {
  const CompanionFloatState({this.loading = false, this.configured = false, this.problem});
  final bool loading;

  /// The native owner accepted the page; this is not proof of a rendered frame.
  final bool configured;
  final String? problem;
}

/// A page capability and its cleanup. Tests replace the socket boundary, not
/// the generation/ownership logic. Never put [page] in logs or diagnostics.
class CompanionFloatPage {
  const CompanionFloatPage(this.page, this.close);
  final Uri page;
  final Future<void> Function() close;
}

typedef CompanionFloatConfigure = Future<void> Function(Uri? page);
typedef CompanionFloatStart = Future<CompanionFloatPage> Function(
  CompanionPackStore store,
  CompanionFloatOptions options,
);

class CompanionFloatSession {
  CompanionFloatSession({
    required this.loadStore,
    required this.startPage,
    required this.configure,
    required this.changed,
  });

  final Future<CompanionPackStore> Function() loadStore;
  final CompanionFloatStart startPage;
  final CompanionFloatConfigure configure;
  final void Function(CompanionFloatState) changed;
  CompanionFloatOptions _options = const CompanionFloatOptions();
  Future<CompanionPackStore>? _storeFuture;
  CompanionPackStore? _store;
  StreamSubscription<int>? _revisions;
  void Function()? _unhook;
  CompanionFloatPage? _page;
  final _closingPages = <CompanionFloatPage>{};
  Future<void> _nativeQueue = Future.value();
  Future<void> _stopQueue = Future.value();
  bool _nativeSent = false;
  bool _closed = false;
  int _generation = 0;

  Future<void> select(CompanionFloatOptions options) async {
    if (_closed || options == _options) return;
    _options = options;
    await _refresh();
  }

  /// The same choice on a new page: the native owner counts faults per page,
  /// so one that fell back to pixels tries again.
  Future<void> retry() async {
    if (!_closed && _options.enabled) await _refresh();
  }

  bool _current(int generation, [int? revision]) =>
      !_closed && _generation == generation && (revision == null || _store?.revision == revision);

  void _publish(CompanionFloatState value) {
    if (!_closed) changed(value);
  }

  Future<void> _native(Future<void> Function() action) {
    final run = _nativeQueue.then((_) => action());
    _nativeQueue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<CompanionPackStore> _ensureStore() async {
    final pending = _storeFuture ??= loadStore();
    final CompanionPackStore store;
    try {
      store = await pending;
    } on Object {
      if (identical(_storeFuture, pending)) _storeFuture = null;
      rethrow;
    }
    if (!_closed && _store == null) {
      _store = store;
      _unhook = store.beforeChanges(() async {
        ++_generation; // Invalidate checks and server starts before directory mutation.
        await _stopReaders(); // Never await a store operation from this hook.
      });
      _revisions = store.revisions.listen((_) {
        if (!_closed && _options.enabled) unawaited(_refresh());
      });
    }
    return store;
  }

  Future<void> _stopReaders() {
    // The revision event and the mutation hook can both request cleanup.
    // A later caller must also await the first caller's server handlers.
    final run = _stopQueue.then((_) => _stopNow());
    _stopQueue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _stopNow() async {
    final page = _page;
    _page = null;
    if (page != null) _closingPages.add(page);
    try {
      await _native(() async {
        if (!_nativeSent) return;
        await configure(null); // Native closes its WebView synchronously before replying.
        _nativeSent = false;
      });
    } finally {
      await Future.wait([for (final pending in List.of(_closingPages)) _closePage(pending)]);
    }
  }

  Future<void> _closePage(CompanionFloatPage page) async {
    _closingPages.add(page);
    await page.close();
    _closingPages.remove(page);
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    final options = _options;
    if (options.enabled) _publish(const CompanionFloatState(loading: true));
    try {
      await _stopReaders();
      if (!_current(generation)) return;
      if (!options.enabled) {
        _publish(const CompanionFloatState());
        return;
      }
      final store = await _ensureStore();
      if (!_current(generation)) return;
      final revision = store.revision;
      final problem = await store.unavailableReason();
      if (!_current(generation, revision)) return;
      if (problem != null) {
        _publish(CompanionFloatState(problem: problem));
        return;
      }
      final page = await startPage(store, options);
      if (!_current(generation, revision)) {
        await _closePage(page);
        return;
      }
      _page = page; // Publish ownership before awaiting the native acknowledgement.
      await _native(() async {
        if (!_current(generation, revision) || !identical(_page, page)) return;
        _nativeSent = true; // A lost reply does not prove native rejected the page.
        try {
          await configure(page.page);
        } on MissingPluginException {
          _nativeSent = false; // This method was not dispatched to a native owner.
          rethrow;
        }
      });
      if (_current(generation, revision) && identical(_page, page)) {
        _publish(const CompanionFloatState(configured: true));
      }
    } on Object catch (error) {
      if (!_current(generation)) return;
      try {
        await _stopReaders();
      } on Object {
        /* Keep the primary stable error. */
      }
      if (_current(generation)) {
        _publish(
          CompanionFloatState(
            problem: switch (error) {
              MissingPluginException() => 'companion_native_unavailable',
              PlatformException() => 'companion_channel_failed',
              FileSystemException() => 'companion_storage',
              SocketException() => 'companion_server_failed',
              _ => 'companion_unavailable',
            },
          ),
        );
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    await _revisions?.cancel();
    await _stopReaders();
    _unhook?.call();
    _unhook = null;
  }
}

/// Same-root stores share mutation hooks. Keep the factory, not a failed
/// Future: reopening settings or explicitly reselecting can retry storage.
final companionFloatStoreProvider = Provider<Future<CompanionPackStore> Function()>(
  (ref) =>
      () async => CompanionPackStore(Directory('${(await getApplicationSupportDirectory()).path}/companion')),
);

/// Subscribe before checking; a late check from a replaced/removed pack is
/// never offered as an enabled choice. Opening settings does not download.
final companionFloatAvailabilityProvider = StreamProvider.autoDispose<String?>((ref) async* {
  final store = await ref.watch(companionFloatStoreProvider)();
  if (!ref.mounted) return;
  final events = StreamController<int>();
  final subscription = store.revisions.listen(events.add);
  ref.onDispose(() {
    unawaited(subscription.cancel());
    unawaited(events.close());
  });
  events.add(store.revision);
  int? checked;
  await for (final _ in events.stream) {
    final revision = store.revision;
    if (checked == revision) continue;
    final reason = await store.unavailableReason();
    if (!ref.mounted) return;
    if (store.revision != revision) continue;
    checked = revision;
    yield reason;
  }
});

/// One controller survives ordinary preference/status changes. Rebuilding it
/// per selection would let an old asynchronous close clear a newer page.
final companionFloatProvider = NotifierProvider<CompanionFloatController, CompanionFloatState>(
  CompanionFloatController.new,
);

class CompanionFloatController extends Notifier<CompanionFloatState> {
  late CompanionFloatSession _session;

  /// See [CompanionFloatSession.retry].
  Future<void> retry() => _session.retry();

  @override
  CompanionFloatState build() {
    final channel = ref.read(petOverlayChannelProvider);
    final session = _session = CompanionFloatSession(
      loadStore: () => ref.read(companionFloatStoreProvider)(),
      startPage: (store, options) async {
        final server = await CompanionServer.start(rootBundle, store.pack);
        return CompanionFloatPage(server.pageUrl(query: options.query), server.close);
      },
      configure: (page) async {
        await channel.configureCompanion(page: page, notice: page == null ? null : appL10n.botsPetOverlayFallback);
      },
      changed: (value) {
        if (ref.mounted) state = value;
      },
    );
    ref.onDispose(() => unawaited(session.close().catchError((Object _) {})));
    void update() {
      // Provider listeners can run during widget build; publish after it.
      scheduleMicrotask(() {
        if (!ref.mounted) return;
        final prefs = ref.read(petPrefsProvider);
        final overlay = ref.read(petOverlayProvider);
        unawaited(
          session.select(
            CompanionFloatOptions(
              enabled:
                  !overlay.ios &&
                  prefs.loaded &&
                  prefs.enabled &&
                  prefs.overlayRenderer == PetOverlayRenderer.companion &&
                  overlay.working,
              zoom: prefs.floatZoom,
              y: prefs.floatY,
            ),
          ),
        );
      });
    }

    ref.listen(petPrefsProvider, (_, _) => update());
    ref.listen(petOverlayProvider.select((value) => value.working), (_, _) => update());
    update();
    return const CompanionFloatState();
  }
}
