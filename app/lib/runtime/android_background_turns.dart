import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/android_features.dart';
import '../state/connection_state.dart';
import '../state/hosts_state.dart';
import 'runtime_state.dart';

/// Follow the local engine in both shells, but only after an opt-in.
final androidBackgroundTurnsProvider = Provider.autoDispose<void>((ref) {
  if (ref.watch(operatingSystemProvider) != 'android' || !ref.watch(activeHostProvider).isLocal) return;
  final enabled = ref.watch(
    backgroundProtectionProvider.select((value) {
      final protection = value.value;
      return protection != null && protection.supported && (protection.audioEnabled || protection.locationEnabled);
    }),
  );
  if (!enabled) return;
  final client = ref.watch(localConnectionProvider.select((value) => value.value?.client));
  if (client == null) return;
  final bridge = ref.watch(runtimeBridgeProvider);
  Future<void> report(bool running) async {
    try {
      await bridge.setTurnRunning(running);
    } on MissingPluginException {
      // An older native host.
    } on PlatformException {
      // Without this signal, the native enhancement stays idle.
    }
  }

  final mux = client.mux;
  MuxGeneration? generation;
  final running = <String>{};
  Set<String>? touched;
  var reported = false;
  void publish() {
    final next = running.isNotEmpty;
    if (reported == next) return;
    reported = next;
    unawaited(report(next));
  }

  Future<void> snapshot(MuxGeneration expected, Set<String> changes) async {
    try {
      final sessions = await client.listSessions();
      if (!ref.mounted || !identical(mux.generation, expected)) return;
      running.addAll(sessions.where((s) => s.running && !changes.contains(s.sessionId)).map((s) => s.sessionId));
      publish();
    } on DshException {
      // Keep only live edges if the initial snapshot could not be read.
    } finally {
      if (identical(touched, changes)) touched = null;
    }
  }

  void syncGeneration() {
    final current = mux.generation;
    if (identical(current, generation)) return;
    generation = current;
    running.clear();
    touched = null;
    publish();
    if (current != null) {
      final changes = <String>{};
      touched = changes;
      unawaited(snapshot(current, changes));
    }
  }

  final states = mux.states.listen((_) => syncGeneration());
  final events = mux.hostEventReceipts.listen((receipt) {
    if (!receipt.provenance.current) return;
    syncGeneration();
    final (id, active) = switch (receipt.event) {
      SessionStatusEvent(:final sessionId, :final running) => (sessionId, running),
      SessionRemovedEvent(:final sessionId) => (sessionId, false),
      _ => (null, false),
    };
    if (id == null) return;
    touched?.add(id);
    if (active) {
      running.add(id);
    } else {
      running.remove(id);
    }
    publish();
  });
  ref.onDispose(() {
    unawaited(events.cancel());
    unawaited(states.cancel());
    if (reported) unawaited(report(false));
  });
  syncGeneration();
});
