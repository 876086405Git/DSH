import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/seams/seat_models.dart';
import '../../../state/hosts_state.dart';
import 'island_assets.dart';
import 'island_budget.dart';
import 'island_gate.dart';
import 'island_handle.dart';
import 'island_messages.dart';
import 'island_platform.dart';
import 'island_theme.dart';

/// The pool of live islands and the memory policy that runs it (§7):
/// how many may live, which go first, warm reuse, background, memory
/// pressure and renderer loss. Notifies when the live set, visibility or
/// renderer health change (not on every message of an island).
class IslandHost extends ChangeNotifier {
  IslandHost({IslandPlatform? platform, IslandAssets? assets, this.islandMb = IslandBudgetRules.extraIslandMb})
    : platform = platform ?? IslandPlatform.instance,
      assets = assets ?? IslandAssets.shared {
    _events = this.platform.events.listen(_onPlatform);
    _lifecycle = AppLifecycleListener(onHide: _onHide, onShow: _onShow);
    unawaited(_loadDevice());
  }

  final IslandPlatform platform;
  final IslandAssets assets;

  /// What each island past the first costs, MB (tests can pretend otherwise).
  final int islandMb;

  final _live = <String, IslandHandle>{};

  /// Specs that stay web links for now (each until its timer ends).
  final _failed = <String, Timer>{};
  final _hiddenTimers = <String, Timer>{};
  StreamSubscription<IslandPlatformEvent>? _events;
  AppLifecycleListener? _lifecycle;
  Timer? _backgroundTimer;
  bool _background = false;

  IslandDevice get device => _device;
  IslandDevice _device = IslandDevice.unknown;

  /// The platform side answered (Android or HarmonyOS, with the islands plugin).
  bool get supported => _device.totalMem > 0;

  /// Overrides the tier (the PoC opens three on a 2 GB emulator).
  int? maxOverride;

  int get max => maxOverride ?? maxLiveIslands(_device, islandMb: islandMb);

  bool get rendererLost => _rendererLost;
  bool _rendererLost = false;

  Iterable<IslandHandle> get live => _live.values;

  Future<void> _loadDevice() async {
    _device = await platform.device();
    if (kDebugMode) debugPrint('[island] device: webView=${_device.webView ?? 'unknown'}');
    notifyListenersIfLive();
  }

  List<LiveIsland> get _liveView => [
    for (final h in _live.values)
      if (h.phase != IslandPhase.closed)
        LiveIsland(key: h.spec.key, form: h.spec.form, visible: h.visible && h.views > 0, lastSeen: h.lastSeen),
  ];

  /// What the seat planner reads; [allowHost] is the security gate.
  IslandBudgetSnapshot snapshot({required bool Function(IslandSpec spec) allowHost}) {
    return IslandBudgetSnapshot(
      supported: supported,
      max: max,
      live: _liveView,
      rendererLost: _rendererLost,
      failed: {..._failed.keys},
      allowHost: allowHost,
    );
  }

  /// Whether an island for [spec] fits now (closing ones that rank lower).
  bool hasRoomFor(IslandSpec spec) =>
      supported && !_rendererLost && evictionsFor(spec.form, _liveView, max, key: spec.key) != null;

  /// The live island for [spec], or a new one (closing others the policy
  /// ranks lower), already counted as shown by the caller's view (release it
  /// with [detachView]). Null when it can't be had: no room, no recipe, no
  /// way to it, the renderer lost, not on Android.
  Future<IslandHandle?> acquire(
    IslandSpec spec, {
    required Uri url,
    required IslandTheme theme,
    List<String> labels = const [],
    bool visible = true,
  }) async {
    final warm = _live[spec.key];
    if (warm != null && warm.phase != IslandPhase.closed && warm.phase != IslandPhase.failed && warm.url == url) {
      attachView(warm);
      setVisible(warm, visible);
      return warm;
    }
    if (warm != null) await _close(warm);
    if (!supported || _rendererLost) return null;
    final book = await assets.recipes;
    final target = book.targetFor(spec, labels: labels);
    if (target == null) return null;
    // From here on no awaits until the island is in the pool: two views
    // asking at once must see each other.
    if (_live.containsKey(spec.key)) return acquire(spec, url: url, theme: theme, labels: labels, visible: visible);
    final evict = evictionsFor(spec.form, _liveView, max, key: spec.key);
    if (evict == null) return null;
    for (final key in evict) {
      final handle = _live[key];
      if (handle != null) {
        handle.giveUp(IslandFailure.evicted);
        unawaited(_close(handle));
      }
    }
    final handle =
        IslandHandle(
            spec: spec,
            url: url,
            target: target,
            recipe: book.recipeFor(spec.slot),
            book: book,
            assets: assets,
            platform: platform,
            theme: theme,
            onPhase: _onPhase,
          )
          ..views = 1
          ..visible = visible
          ..lastSeen = DateTime.now();
    _live[spec.key] = handle;
    notifyListeners();
    await handle.start();
    return handle;
  }

  void _onPhase(IslandHandle handle) {
    if (handle.phase == IslandPhase.failed) {
      final failure = handle.failure;
      // Failures of the island itself count against the spec (a timeout only
      // briefly); memory and the renderer don't.
      final memory = failure == null ? null : IslandBudgetRules.memoryFor(failure);
      if (memory != null) {
        final key = handle.spec.key;
        _failed.remove(key)?.cancel();
        _failed[key] = Timer(memory, () {
          _failed.remove(key);
          // The planner asks again.
          notifyListenersIfLive();
        });
      }
      unawaited(_close(handle));
    }
  }

  bool _disposed = false;

  /// For timers that may outlive the host.
  void notifyListenersIfLive() {
    if (!_disposed) notifyListeners();
  }

  /// A view started showing [handle].
  void attachView(IslandHandle handle) {
    handle.views++;
    handle.lastSeen = DateTime.now();
    _hiddenTimers.remove(handle.spec.key)?.cancel();
    notifyListeners();
  }

  /// A view stopped showing [handle]: it stays warm for a while.
  void detachView(IslandHandle handle) {
    handle.views = (handle.views - 1).clamp(0, 1 << 20);
    handle.lastSeen = DateTime.now();
    if (handle.views == 0) {
      handle.visible = false;
      // Turning off an overlay must stop its scripts and sound, not keep a
      // hidden live page around for the normal page-island grace period.
      final grace = handle.spec.form == IslandForm.probe || handle.spec.form == IslandForm.overlay
          ? Duration.zero
          : IslandBudgetRules.hiddenGrace;
      _hiddenTimers.remove(handle.spec.key)?.cancel();
      _hiddenTimers[handle.spec.key] = Timer(grace, () {
        _hiddenTimers.remove(handle.spec.key);
        if (handle.views == 0) unawaited(_close(handle));
      });
    }
    notifyListeners();
  }

  /// The view's page is on top (or not): islands under another page count as
  /// off screen for the budget.
  void setVisible(IslandHandle handle, bool visible) {
    if (handle.visible == visible) return;
    handle.visible = visible;
    handle.lastSeen = DateTime.now();
    if (!visible) {
      unawaited(handle.pause());
    } else if (!_background) {
      unawaited(handle.resume());
    }
    notifyListeners();
  }

  /// After the renderer died: islands may open again (the view's 重新打开).
  void reopen() {
    if (!_rendererLost) return;
    _rendererLost = false;
    notifyListeners();
  }

  Future<void> _close(IslandHandle handle, {IslandFailure? because}) async {
    _hiddenTimers.remove(handle.spec.key)?.cancel();
    if (_live[handle.spec.key] == handle) _live.remove(handle.spec.key);
    notifyListeners();
    await handle.close(because: because);
  }

  /// Closes every island matching [test].
  Future<void> closeWhere(bool Function(IslandHandle h) test, IslandFailure because) async {
    for (final handle in [..._live.values.where(test)]) {
      handle.giveUp(because);
      await _close(handle, because: because);
    }
  }

  void _onPlatform(IslandPlatformEvent event) {
    switch (event) {
      case IslandRendererGone():
        // One renderer serves every WebView of the app: all islands are gone.
        _rendererLost = true;
        unawaited(closeWhere((_) => true, IslandFailure.renderer));
      case IslandTrimMemory(:final level):
        if (level >= 10) {
          unawaited(closeWhere((h) => !(h.visible && h.views > 0) || _background, IslandFailure.evicted));
        }
    }
  }

  void _onHide() {
    _background = true;
    for (final h in _live.values) {
      unawaited(h.pause());
    }
    _backgroundTimer?.cancel();
    _backgroundTimer = Timer(IslandBudgetRules.backgroundGrace, () {
      unawaited(closeWhere((_) => true, IslandFailure.evicted));
    });
  }

  void _onShow() {
    _background = false;
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    for (final h in _live.values) {
      if (h.visible && h.views > 0) unawaited(h.resume());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final t in _failed.values) {
      t.cancel();
    }
    unawaited(_events?.cancel());
    _lifecycle?.dispose();
    _backgroundTimer?.cancel();
    for (final t in _hiddenTimers.values) {
      t.cancel();
    }
    for (final h in [..._live.values]) {
      unawaited(h.close());
    }
    _live.clear();
    super.dispose();
  }
}

/// The app's island pool.
final islandHostProvider = Provider<IslandHost>((ref) {
  final host = IslandHost();
  ref.onDispose(host.dispose);
  return host;
});

/// What `islandBudgetProvider` reads: the budget with the security gate,
/// rebuilt whenever the pool changes.
final liveIslandBudgetProvider = Provider<IslandBudget>((ref) {
  final host = ref.watch(islandHostProvider);
  void changed() => ref.invalidateSelf();
  host.addListener(changed);
  ref.onDispose(() => host.removeListener(changed));
  final active = ref.watch(activeHostProvider);
  final gates = <HostRef, bool>{
    HostRef.local: ref.watch(islandHostGateProvider(HostRef.local)),
    active: ref.watch(islandHostGateProvider(active)),
  };
  return host.snapshot(allowHost: (spec) => gates[spec.host] ?? false);
});
