import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workshop/workshop_client.dart';
import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart';
import 'workshop_dependencies.dart';

enum WorkshopKindFilter { all, pet, companion, theme }

const _unchanged = Object();

class WorkshopCatalogState {
  WorkshopCatalogState({this.origin, this.snapshot, List<WorkshopItemState> items = const [],
    this.loading = false, this.refreshing = false, this.localStateKnown = false,
    this.refreshError, this.localError, this.cacheIssue,
    this.kind = WorkshopKindFilter.all, this.query = ''}) : items = List.unmodifiable(items);

  final Uri? origin;
  final WorkshopCatalogSnapshot? snapshot;
  final List<WorkshopItemState> items;
  final bool loading, refreshing, localStateKnown;
  final String? refreshError, localError, cacheIssue;
  final WorkshopKindFilter kind;
  final String query;

  List<WorkshopItemState> get visibleItems {
    final search = query.trim().toLowerCase();
    return List.unmodifiable(items.where((item) {
      final metadata = item.entry.metadata;
      if (kind != WorkshopKindFilter.all && metadata.kind != kind.name) return false;
      return search.isEmpty || metadata.author.toLowerCase().contains(search) ||
        metadata.title.values.any((title) => title.toLowerCase().contains(search));
    }));
  }

  WorkshopCatalogState copyWith({Uri? origin, WorkshopCatalogSnapshot? snapshot,
    List<WorkshopItemState>? items, bool? loading, bool? refreshing, bool? localStateKnown,
    Object? refreshError = _unchanged, Object? localError = _unchanged,
    Object? cacheIssue = _unchanged, WorkshopKindFilter? kind, String? query}) => WorkshopCatalogState(
      origin: origin ?? this.origin, snapshot: snapshot ?? this.snapshot, items: items ?? this.items,
      loading: loading ?? this.loading, refreshing: refreshing ?? this.refreshing,
      localStateKnown: localStateKnown ?? this.localStateKnown,
      refreshError: identical(refreshError, _unchanged) ? this.refreshError : refreshError as String?,
      localError: identical(localError, _unchanged) ? this.localError : localError as String?,
      cacheIssue: identical(cacheIssue, _unchanged) ? this.cacheIssue : cacheIssue as String?,
      kind: kind ?? this.kind, query: query ?? this.query,
    );
}

final workshopCatalogProvider = NotifierProvider<WorkshopCatalogController, WorkshopCatalogState>(
  WorkshopCatalogController.new,
);

/// Details and the filtered browser share the repository's one item projection.
/// Read [workshopCatalogProvider] as well to distinguish unknown local state.
final workshopItemProvider = Provider.family<WorkshopItemState?, String>((ref, identity) {
  return ref.watch(workshopCatalogProvider).items
    .where((item) => item.entry.metadata.identity == identity).firstOrNull;
});

class WorkshopCatalogController extends Notifier<WorkshopCatalogState> {
  int _generation = 0;
  Future<void>? _refreshing;
  Future<void>? _localRefresh;
  late Future<WorkshopClient> _client;
  late Future<WorkshopRepository> _repository;
  late String _appVersion;
  late Future<void> _ready;

  Future<void> get ready {
    final _ = state;
    return _ready;
  }

  @override
  WorkshopCatalogState build() {
    _client = ref.watch(workshopClientProvider.future);
    _repository = ref.watch(workshopRepositoryProvider.future);
    _appVersion = ref.watch(workshopAppVersionProvider);
    // A missing deployment can fail the repository before cache lookup awaits
    // it. Observe that Future now; its error is still reported by the operation.
    unawaited(_repository.then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
    unawaited(_client.then<void>((_) {}, onError: (Object error, StackTrace stack) {}));
    final generation = ++_generation;
    ref.onDispose(() => _generation++);
    _localRefresh = null;
    _ready = Future<void>.microtask(() => _load(generation, cachedFirst: true));
    _refreshing = _ready;
    unawaited(_ready.whenComplete(() {
      if (_current(generation)) _refreshing = null;
    }));
    return WorkshopCatalogState(loading: true, refreshing: true);
  }

  bool _current(int generation) {
    if (!ref.mounted) return false;
    // Notifier.state flushes invalidated dependencies before this generation
    // comparison. A mounted Ref alone does not force a pending rebuild.
    final _ = state;
    return ref.mounted && generation == _generation;
  }

  void setKind(WorkshopKindFilter kind) => state = state.copyWith(kind: kind);
  void setQuery(String query) => state = state.copyWith(query: query);

  Future<void> refresh() {
    if (!ref.mounted) return Future.value();
    final _ = state;
    if (_refreshing case final running?) return running;
    retryWorkshopDependencies(ref, includeLocal: true);
    final current = state;
    // Retrying a failed factory may have rebuilt this controller; its initial
    // load already owns the replacement dependency Futures.
    if (_refreshing case final running?) return running;
    final generation = _generation;
    state = current.copyWith(refreshing: true, refreshError: null);
    final run = _load(generation, cachedFirst: false);
    _refreshing = run;
    return run.whenComplete(() {
      if (_current(generation) && identical(_refreshing, run)) _refreshing = null;
    });
  }

  Future<void> _load(int generation, {required bool cachedFirst}) async {
    // Capture dependencies before the first await: a source change can rebuild
    // this notifier while an old request is still completing.
    final clientFuture = _client, repositoryFuture = _repository;
    final appVersion = _appVersion;
    try {
      final client = await clientFuture;
      if (!_current(generation)) return;
      state = state.copyWith(origin: client.origin);
      if (cachedFirst) {
        final cached = await client.cachedCatalog();
        if (!_current(generation)) return;
        state = state.copyWith(cacheIssue: client.cacheIssue);
        if (cached != null) {
          await _accept(generation, client.origin, cached, repositoryFuture, appVersion);
          if (!_current(generation)) return;
        }
      }
      final fresh = await client.catalog();
      if (!_current(generation)) return;
      await _accept(generation, client.origin, fresh, repositoryFuture, appVersion);
    } on Object catch (error) {
      if (_current(generation)) state = state.copyWith(refreshError: workshopLocalError(error).code);
    } finally {
      if (_current(generation)) state = state.copyWith(loading: false, refreshing: false);
    }
  }

  Future<void> _accept(int generation, Uri origin, WorkshopCatalogSnapshot snapshot,
    Future<WorkshopRepository> repositoryFuture, String appVersion) async {
    // A receipt read can be queued behind a current installer. Publish the
    // catalog immediately and label its local status unknown until projected.
    final publicItems = [for (final entry in snapshot.catalog.entries)
      WorkshopItemState(entry: entry, unavailable: snapshot.catalog.unavailable(entry, appVersion))];
    state = state.copyWith(origin: origin, snapshot: snapshot, items: publicItems, loading: false,
      localStateKnown: false, localError: null,
      refreshError: snapshot.refreshError?.code, cacheIssue: snapshot.cacheIssue);
    List<WorkshopItemState> items;
    String? localError;
    try {
      final repository = await repositoryFuture;
      if (!_current(generation)) return;
      if (repository.client.origin != origin) workshopInvalid('workshop_untrusted_origin');
      items = await repository.states(snapshot.catalog);
    } on Object catch (error) {
      localError = workshopLocalError(error).code;
      // Public availability is still useful. Null installed here means
      // unknown, as exposed by localStateKnown, not confirmed absent.
      items = publicItems;
    }
    if (!_current(generation)) return;
    state = state.copyWith(origin: origin, snapshot: snapshot, items: items, loading: false,
      localStateKnown: localError == null, localError: localError,
      refreshError: snapshot.refreshError?.code, cacheIssue: snapshot.cacheIssue);
  }

  /// Re-read receipts after a mutation without starting another HTTP refresh.
  Future<void> reloadLocal() {
    if (!ref.mounted) return Future.value();
    if (_localRefresh case final running?) return running;
    final generation = _generation;
    final run = _reloadLocal(generation);
    _localRefresh = run;
    return run.whenComplete(() {
      if (_current(generation) && identical(_localRefresh, run)) _localRefresh = null;
    });
  }

  Future<void> _reloadLocal(int generation) async {
    await _refreshing;
    if (!_current(generation)) return;
    final snapshot = state.snapshot;
    if (snapshot == null) return;
    try {
      final repository = await _repository;
      if (!_current(generation)) return;
      if (repository.client.origin != state.origin) workshopInvalid('workshop_untrusted_origin');
      final items = await repository.states(snapshot.catalog);
      if (_current(generation) && identical(state.snapshot, snapshot)) {
        state = state.copyWith(items: items, localStateKnown: true, localError: null);
      }
    } on Object catch (error) {
      if (_current(generation) && identical(state.snapshot, snapshot)) {
        state = state.copyWith(localStateKnown: false, localError: workshopLocalError(error).code);
      }
    }
  }
}
