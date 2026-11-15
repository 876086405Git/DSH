// 本机引擎 → Linux 环境 (iOS): the Linux root file system iSH runs, installed on demand. The
// native side is app/ios/Runner/GuestChannel.swift, reached through lib/runtime/ios_guest.dart.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime/ios_guest.dart';

/// What the page needs from the installer (a fake one in tests).
abstract interface class GuestInstaller {
  Stream<Map<Object?, Object?>> get events;
  Future<IosGuestStatus> status();
  Future<IosGuestStatus> install();
  Future<IosGuestStatus> uninstall();
  Future<IosGuestStatus> resume();
  Future<bool> cancel();
  Future<Map<String, int>> usage();
}

class _Bridge implements GuestInstaller {
  final _bridge = IosGuestBridge();

  @override
  Stream<Map<Object?, Object?>> get events => _bridge.events;
  @override
  Future<IosGuestStatus> status() => _bridge.status();
  @override
  Future<IosGuestStatus> install() => _bridge.install();
  @override
  Future<IosGuestStatus> uninstall() => _bridge.uninstall();
  @override
  Future<IosGuestStatus> resume() => _bridge.resume();
  @override
  Future<bool> cancel() => _bridge.cancel();
  @override
  Future<Map<String, int>> usage() => _bridge.usage();
}

/// Null where there is none: everywhere but iOS.
final guestInstallerProvider = Provider<GuestInstaller?>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? _Bridge() : null,
);

/// The step an install is in, as the native side reports it.
enum GuestStep { download, verify, extract, publish }

class GuestView {
  const GuestView({
    this.status,
    this.step,
    this.done = 0,
    this.total = 0,
    this.bytes,
    this.failure,
    this.justInstalled = false,
    this.justResumed = false,
  });

  /// Null until the first answer, and off iOS.
  final IosGuestStatus? status;
  final GuestStep? step;
  final int done;
  final int total;

  /// Space it takes, once installed.
  final int? bytes;

  /// The last install or uninstall that didn't work, by its code without the `ios_guest_` prefix.
  /// A cancelled install isn't one.
  final String? failure;

  /// Installed while the app was open: the engine picks it up when it starts again.
  final bool justInstalled;

  /// Turned back on after a run that didn't finish: like [justInstalled], it waits for the engine
  /// to start again.
  final bool justResumed;

  /// Within the current step, 0–1; null when there's nothing to measure yet.
  double? get fraction => total > 0 ? (done / total).clamp(0.0, 1.0) : null;

  bool get installing => switch (status?.phase) {
    'downloading' || 'verifying' || 'extracting' || 'publishing' => true,
    _ => false,
  };

  GuestView copyWith({
    IosGuestStatus? status,
    GuestStep? step,
    bool clearStep = false,
    int? done,
    int? total,
    int? bytes,
    String? failure,
    bool clearFailure = false,
    bool? justInstalled,
    bool? justResumed,
  }) => GuestView(
    status: status ?? this.status,
    step: clearStep ? null : step ?? this.step,
    done: clearStep ? 0 : done ?? this.done,
    total: clearStep ? 0 : total ?? this.total,
    bytes: bytes ?? this.bytes,
    failure: clearFailure ? null : failure ?? this.failure,
    justInstalled: justInstalled ?? this.justInstalled,
    justResumed: justResumed ?? this.justResumed,
  );
}

final iosGuestProvider = NotifierProvider<IosGuestController, GuestView>(IosGuestController.new);

class IosGuestController extends Notifier<GuestView> {
  GuestInstaller? get _installer => ref.read(guestInstallerProvider);

  @override
  GuestView build() {
    final installer = ref.watch(guestInstallerProvider);
    if (installer == null) return const GuestView();
    final sub = installer.events.listen(_onEvent, onError: (_) {});
    ref.onDispose(sub.cancel);
    unawaited(_refresh());
    return const GuestView();
  }

  Future<void> _refresh() async {
    final installer = _installer;
    if (installer == null) return;
    try {
      _show(await installer.status());
    } on Object {
      // No native side (an app built without it): the section stays away.
    }
  }

  void _onEvent(Map<Object?, Object?> event) {
    if (!ref.mounted) return;
    switch (event['type']) {
      case 'status' when event['status'] is Map:
        _show(IosGuestStatus.fromMap(Map<Object?, Object?>.from(event['status'] as Map)));
      case 'progress':
        final step = GuestStep.values.asNameMap()[event['step']];
        if (step == null) return;
        state = state.copyWith(
          step: step,
          done: (event['done'] as num?)?.toInt() ?? 0,
          total: (event['total'] as num?)?.toInt() ?? 0,
        );
    }
  }

  void _show(IosGuestStatus status) {
    if (!ref.mounted) return;
    final before = state.status;
    state = state.copyWith(
      status: status,
      clearStep: !GuestView(status: status).installing,
    );
    if (status.installed && !status.busy && (before == null || !before.installed || state.bytes == null)) {
      unawaited(_measure());
    }
  }

  Future<void> _measure() async {
    try {
      final usage = await _installer!.usage();
      if (ref.mounted) state = state.copyWith(bytes: usage['totalBytes']);
    } on Object {
      // Measured again next time it's opened.
    }
  }

  Future<void> install() async {
    final installer = _installer;
    if (installer == null || state.installing) return;
    state = state.copyWith(clearFailure: true);
    try {
      final status = await installer.install();
      if (!ref.mounted) return;
      state = state.copyWith(justInstalled: status.installed);
      _show(status);
    } on PlatformException catch (error) {
      _failed(error);
    }
  }

  Future<void> cancel() async {
    try {
      await _installer?.cancel();
    } on PlatformException {
      // Too late to cancel: the install finishes and says so.
    }
  }

  Future<void> uninstall() async {
    final installer = _installer;
    if (installer == null) return;
    state = state.copyWith(clearFailure: true);
    try {
      final status = await installer.uninstall();
      if (!ref.mounted) return;
      state = GuestView(status: status);
    } on PlatformException catch (error) {
      _failed(error);
    }
  }

  /// After a Linux run that didn't finish (the app may have crashed with it), Linux stays paused
  /// until the user turns it back on here.
  Future<void> resume() async {
    final installer = _installer;
    if (installer == null) return;
    state = state.copyWith(clearFailure: true);
    try {
      final status = await installer.resume();
      if (!ref.mounted) return;
      state = state.copyWith(justResumed: !status.suspended);
      _show(status);
    } on PlatformException catch (error) {
      _failed(error);
    }
  }

  void _failed(PlatformException error) {
    if (!ref.mounted) return;
    final code = error.code.replaceFirst('ios_guest_', '');
    state = state.copyWith(failure: code == 'cancelled' ? null : code, clearFailure: code == 'cancelled');
    unawaited(_refresh());
  }
}
