import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../voice/streaming_asr.dart';
import '../voice/ohos_streaming_asr.dart';
import 'android_features.dart' show operatingSystemProvider;

final streamingAsrProvider = Provider<StreamingAsr>((ref) {
  final asr = ref.watch(operatingSystemProvider) == 'ohos' ? OhosStreamingAsr() : StreamingAsr();
  ref.onDispose(() => unawaited(asr.dispose()));
  return asr;
});

enum SystemAsrReadiness { ready, busy, unavailable }

/// A current system-service probe, independent of the downloaded sherpa model.
/// Native errors remain AsyncError; readiness is not a promise about a later start.
final ohosStreamingAsrReadyProvider = FutureProvider.autoDispose<SystemAsrReadiness>((ref) async {
  if (ref.watch(operatingSystemProvider) != 'ohos') return SystemAsrReadiness.unavailable;
  if (OhosStreamingAsr.isTransitioning) return SystemAsrReadiness.busy;
  if (OhosStreamingAsr.hasActiveSession) return SystemAsrReadiness.ready;
  final probe = OhosStreamingAsr.forReadiness();
  Object? failure;
  final events = probe.events.listen((_) {}, onError: (Object error) { failure = error; });
  Future<void>? closing;
  Future<void> close() => closing ??= probe.dispose();
  ref.onDispose(() => unawaited(close().catchError((Object _) {})));
  try {
    // recognitionMode=1 uses supplied PCM and never opens the microphone.
    await probe.start(const StreamingAsrModel.system());
    if (failure case final error?) throw error;
    return probe.active || OhosStreamingAsr.hasActiveSession
        ? SystemAsrReadiness.ready : SystemAsrReadiness.busy;
  } finally {
    try { await close(); }
    finally { await events.cancel(); }
  }
}, retry: (_, _) => null);
