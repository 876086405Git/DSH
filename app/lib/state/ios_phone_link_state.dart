// 手机操控 → 本机连接 (iOS): the pairing record, the developer connection switch, connection
// checks and the developer disk image, through lib/phone/ios_phone_link.dart. The native side
// asks the user every question itself; this only starts each step and shows what came back.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../phone/ios_phone_link.dart';

/// Null where there is none: everywhere but iOS.
final phoneLinkApiProvider = Provider<PhoneLinkApi?>(
  (ref) => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? PhoneLinkChannel() : null,
);

/// A setup step the page can start.
enum PhoneLinkStep { importPairing, migratePairing, clearPairing, enable, disable, xctestOn, xctestOff, check, mount }

class PhoneLinkView {
  const PhoneLinkView({this.status, this.failure, this.failedStep, this.checked = false});

  /// Null until the first answer, and off iOS (or a build without the native side).
  final PhoneLinkStatus? status;

  /// The last step that didn't work, by its `ERR_PHONE_...` code. Saying no isn't one.
  final String? failure;
  final PhoneLinkStep? failedStep;

  /// A connection check passed since the page opened.
  final bool checked;

  bool get busy => status?.operationPending ?? false;
}

final phoneLinkProvider = NotifierProvider<PhoneLinkController, PhoneLinkView>(PhoneLinkController.new);

class PhoneLinkController extends Notifier<PhoneLinkView> {
  PhoneLinkApi? get _api => ref.read(phoneLinkApiProvider);

  @override
  PhoneLinkView build() {
    final api = ref.watch(phoneLinkApiProvider);
    if (api == null) return const PhoneLinkView();
    final sub = api.events.listen(_show, onError: (_) {});
    ref.onDispose(sub.cancel);
    unawaited(refresh());
    return const PhoneLinkView();
  }

  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    try {
      _show(await api.status());
    } on Object {
      // No native side (an app built without it): the section stays away.
    }
  }

  void _show(PhoneLinkStatus status) {
    if (!ref.mounted) return;
    state = PhoneLinkView(status: status, failure: state.failure, failedStep: state.failedStep, checked: state.checked);
  }

  /// Starts [step]; the native side asks whatever it needs to. One at a time.
  Future<void> run(PhoneLinkStep step) async {
    final api = _api;
    if (api == null || state.busy) return;
    state = PhoneLinkView(status: state.status, checked: state.checked && step != PhoneLinkStep.clearPairing);
    PhoneLinkResult result;
    try {
      result = await switch (step) {
        PhoneLinkStep.importPairing => api.importPairing(),
        PhoneLinkStep.migratePairing => api.migrateLegacyPairing(),
        PhoneLinkStep.clearPairing => api.clearPairing(),
        PhoneLinkStep.enable => api.setEnabled(true),
        PhoneLinkStep.disable => api.setEnabled(false),
        PhoneLinkStep.xctestOn => api.setXCTestEnabled(true),
        PhoneLinkStep.xctestOff => api.setXCTestEnabled(false),
        PhoneLinkStep.check => api.checkConnection(),
        PhoneLinkStep.mount => api.mountDDI(),
      };
    } on PlatformException catch (error) {
      result = PhoneLinkResult(false, error.code, null);
    } on MissingPluginException {
      result = const PhoneLinkResult(false, 'ERR_PHONE_NATIVE_UNAVAILABLE', null);
    }
    if (!ref.mounted) return;
    final failed = !result.ok && !result.cancelled;
    state = PhoneLinkView(
      status: result.status ?? state.status,
      failure: failed ? result.code : null,
      failedStep: failed ? step : null,
      checked: (step == PhoneLinkStep.check || step == PhoneLinkStep.mount) ? result.ok : state.checked,
    );
    if (result.status == null) unawaited(refresh());
  }

  Future<void> cancel() async {
    try {
      await _api?.cancelPreparation();
    } on Object {
      // Nothing under way any more.
    }
  }

  /// The clipboard as it was before text was typed through it. The native side asks first.
  Future<void> restoreClipboard({bool overwriteChanged = false}) =>
      _clipboard(() => _api!.restoreClipboard(overwriteChanged: overwriteChanged));

  Future<void> discardClipboard() => _clipboard(() => _api!.discardSavedClipboard());

  Future<void> _clipboard(Future<PhoneLinkResult> Function() call) async {
    if (_api == null || state.busy) return;
    PhoneLinkResult result;
    try {
      result = await call();
    } on PlatformException catch (error) {
      result = PhoneLinkResult(false, error.code, null);
    }
    if (!ref.mounted) return;
    final failed = !result.ok && !result.cancelled;
    state = PhoneLinkView(
      status: result.status ?? state.status,
      failure: failed ? result.code : null,
      checked: state.checked,
    );
  }
}
