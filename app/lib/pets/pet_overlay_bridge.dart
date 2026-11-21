// Feeds the out-of-app overlay (`dsh/pet_overlay`) every new [PetState].

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../companion/companion_float.dart';
import '../state/android_features.dart';
import '../state/live_activity_state.dart';
import '../state/notify_state.dart';
import '../ui/common/app_dialog.dart';
import 'overlay_channel.dart';
import 'pet_overlay_actions.dart';
import 'pet_signals.dart';
import 'pet_state.dart';
import 'pet_voice_dialog.dart';

/// Where states go: the overlay's channel (`dsh/pet_overlay`).
final petOverlayPushProvider = Provider<Future<void> Function(PetState state)>(
  (ref) => ref.watch(petOverlayChannelProvider).push,
);

/// Watch it to keep the overlay fed: pushes the state on start and on every
/// change (equal states are not pushed twice). Failures are dropped: no
/// native side in tests, or the overlay is off.
final petOverlayBridgeProvider = Provider<void>((ref) {
  ref.watch(companionFloatProvider.notifier);
  ref.watch(petOverlayActionBridgeProvider);
  // The status bar's live activity tells the same state in words.
  ref.watch(liveActivityBridgeProvider);
  // 停止 on the iOS live activity is the pet's own stop, with its checks.
  if (ref.read(operatingSystemProvider) == 'ios') {
    ref
        .read(notifyChannelProvider)
        .onLiveStop(
          (host, session) async =>
              await ref
                  .read(petOverlayActionsProvider)
                  .handle(MethodCall('stop', {'host': host, 'sessionId': session})) ==
              true,
        );
  }
  ref.listen<PetState>(petStateProvider, (previous, next) {
    if (previous == next) return;
    final push = ref.read(petOverlayPushProvider);
    unawaited(() async {
      try {
        await push(next);
      } catch (_) {}
    }());
  }, fireImmediately: true);
});

/// Keeps [petOverlayBridgeProvider] alive where it is mounted (the home
/// shell, so the overlay is fed in both 原生 and 网页 modes). Draws nothing.
class PetOverlayBridge extends ConsumerStatefulWidget {
  const PetOverlayBridge({super.key});
  @override
  ConsumerState<PetOverlayBridge> createState() => _PetOverlayBridgeState();
}

class _PetOverlayBridgeState extends ConsumerState<PetOverlayBridge> {
  late final PetOverlayChannel _channel;
  bool _voiceOpen = false;

  @override
  void initState() {
    super.initState();
    _channel = ref.read(petOverlayChannelProvider);
    _channel.voiceFallback = (text) async {
      if (!mounted || _voiceOpen) return text;
      _voiceOpen = true;
      try {
        return await showAppDialog<String>(
              context: context,
              barrierDismissible: false,
              builder: (_) => PetVoiceDialog(text: text),
            ) ??
            text;
      } finally {
        _voiceOpen = false;
      }
    };
  }

  @override
  void dispose() {
    _channel.voiceFallback = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<void>(petOverlayBridgeProvider, (_, _) {});
    return const SizedBox.shrink();
  }
}
