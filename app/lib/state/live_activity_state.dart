// Keeps the live activity (lib/notify/live_activity.dart) fed: the global pet
// state in words, pushed to `dsh/notify` whenever it changes.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../notify/live_activity.dart';
import '../pets/pet_signals.dart';
import '../pets/pet_state.dart';
import 'android_features.dart';
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

/// Watch it to keep the live activity fed (with the pet overlay's bridge, in
/// both 原生 and 网页 modes). Equal pushes are not sent twice.
final liveActivityBridgeProvider = Provider<void>((ref) {
  // Only OH owns an ordinary fallback here. Android keeps its original
  // native live-activity lifecycle and receives no extra disposal message.
  if (ref.read(operatingSystemProvider) == 'ohos') {
    final channel = ref.read(notifyChannelProvider);
    ref.onDispose(() => unawaited(channel.live(const LivePush(enabled: false))));
  }
  ref.listen<LivePush>(livePushProvider, (previous, next) {
    if (previous == next) return;
    unawaited(ref.read(notifyChannelProvider).live(next));
  }, fireImmediately: true);
});

/// What the phone offers; re-read with `ref.invalidate` when the app comes back.
final liveSystemStatusProvider = FutureProvider<LiveSystemStatus>(
  (ref) => ref.watch(notifyChannelProvider).liveStatus(),
);
