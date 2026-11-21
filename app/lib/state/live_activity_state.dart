// Keeps the live activity (lib/notify/live_activity.dart) fed: the global pet
// state in words, pushed to `dsh/notify` whenever it changes.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../notify/live_activity.dart';
import '../notify/live_art.dart';
import '../pets/pet_signals.dart';
import '../pets/pet_state.dart';
import 'android_features.dart';
import 'appearance_state.dart';
import 'notify_state.dart';

export '../notify/live_activity.dart';

/// Titles seen running or focused, so a finished conversation keeps its name.
final _liveTitlesProvider = Provider<Map<PetTarget, String>>((ref) => <PetTarget, String>{});

/// What the live activity shows now; null: nothing. Reads the pet's own
/// signals, so it sees exactly what the pet sees.
final liveActivityProvider = Provider<LiveActivity?>((ref) {
  final signals = ref.watch(petSignalsProvider);
  final titles = ref.watch(_liveTitlesProvider);
  learnLiveTitles(titles, signals.runs, focus: signals.focus);
  final prefs = ref.watch(notifyPrefsProvider);
  return liveActivityOf(
    pet: ref.watch(petStateProvider),
    runs: signals.runs,
    pending: signals.pending,
    focus: signals.focus,
    titles: titles,
    showDone: prefs.done,
    showFailed: prefs.failed,
  );
});

/// What `dsh/notify` is told: off with notifications or the switch, else the
/// activity and the pet whose pictures it uses.
final livePushProvider = Provider<LivePush>((ref) {
  final enabled = ref.watch(notifyPrefsProvider.select((p) => p.enabled && p.live));
  return LivePush(
    enabled: enabled,
    packId: ref.watch(petStateProvider.select((s) => s.packId == noPetId ? null : s.packId)),
    activity: enabled ? ref.watch(liveActivityProvider) : null,
  );
});

/// What iOS draws besides the [LivePush]: the theme's accent (light, dark) and
/// whether 停止 can work, which is when the floating pet's own stop can
/// ([PetState.canStop]) and the card is about the pet's conversation.
typedef IosLive = ({LivePush push, int tint, int tintDark, bool canStop});

final iosLiveProvider = Provider<IosLive>((ref) {
  final push = ref.watch(livePushProvider);
  final accent = ref.watch(accentProvider);
  final target = push.activity?.target;
  final canStop = ref.watch(petStateProvider.select((s) => s.canStop && target != null && s.target == target));
  return (push: push, tint: accent.seed.toARGB32(), tintDark: accent.seedDark.toARGB32(), canStop: canStop);
});

/// Watch it to keep the live activity fed (with the pet overlay's bridge, in
/// both 原生 and 网页 modes). Equal pushes are not sent twice.
final liveActivityBridgeProvider = Provider<void>((ref) {
  final os = ref.read(operatingSystemProvider);
  if (os == 'ios') {
    final sender = _IosLiveSender(ref);
    ref.listen<IosLive>(iosLiveProvider, (previous, next) {
      if (previous != next) sender.send(next);
    }, fireImmediately: true);
    return;
  }
  // Only OH owns an ordinary fallback here. Android keeps its original
  // native live-activity lifecycle and receives no extra disposal message.
  if (os == 'ohos') {
    final channel = ref.read(notifyChannelProvider);
    ref.onDispose(() => unawaited(channel.live(const LivePush(enabled: false))));
  }
  ref.listen<LivePush>(livePushProvider, (previous, next) {
    if (previous == next) return;
    unawaited(ref.read(notifyChannelProvider).live(next));
  }, fireImmediately: true);
});

/// One push at a time, in order: the still for an older state, slow to draw,
/// can't land on a newer one. Each picture crosses the channel once.
class _IosLiveSender {
  _IosLiveSender(this.ref);

  final Ref ref;
  Future<void> _tail = Future.value();
  final _arts = <String, LiveArt>{};
  String? _sent;

  void send(IosLive live) => _tail = _tail.then((_) => _send(live)).catchError((Object _) {});

  Future<void> _send(IosLive live) async {
    if (!ref.mounted) return;
    final push = live.push;
    final activity = push.activity, packId = push.packId;
    final art = push.enabled && activity != null && packId != null ? await _art(packId, activity.mood) : null;
    if (!ref.mounted) return;
    final l10n = appL10n;
    await ref.read(notifyChannelProvider).liveWith(push, {
      'tint': live.tint,
      'tintDark': live.tintDark,
      'canStop': live.canStop,
      'labels': {'stop': l10n.liveStop, 'stale': l10n.liveStale},
      // Null says so: native keeps extras a push leaves out, so the last pet's
      // picture would otherwise stay on a pet that has none.
      'artKey': art?.key,
      'artPixel': art?.pixelArt ?? false,
      if (art != null && art.key != _sent) 'art': art.png,
    });
    if (art != null) _sent = art.key;
  }

  Future<LiveArt?> _art(String packId, PetStateName mood) async {
    try {
      final pack = await ref.read(petPackProvider(packId).future);
      // The pack object, not its id: a pet brought again under the same id is new.
      final key = '${identityHashCode(pack)}/${mood.name}';
      if (_arts[key] case final art?) return art;
      final art = await liveArtOf(pack, mood, ref.read(petAssetBundleProvider));
      if (art == null) return null;
      if (_arts.length >= 16) _arts.remove(_arts.keys.first);
      return _arts[key] = art;
    } on Object {
      return null;
    }
  }
}

/// What the phone offers; re-read with `ref.invalidate` when the app comes back.
final liveSystemStatusProvider = FutureProvider<LiveSystemStatus>(
  (ref) => ref.watch(notifyChannelProvider).liveStatus(),
);
