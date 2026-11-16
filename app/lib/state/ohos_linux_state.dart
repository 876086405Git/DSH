import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../runtime/ohos_linux_runtime.dart';
import '../secrets/secure_storage.dart';

/// The in-app Linux on HarmonyOS: the switch, its install progress and the
/// proxy its jobs use.
///
/// The engine forgets both the switch and the proxy every time it restarts, so
/// the app keeps the user's choice and hands it back once the engine runs
/// again ([restore]). The proxy can carry a password, so it lives in secure
/// storage, never SharedPreferences.
class OhosLinuxView {
  const OhosLinuxView({this.snapshot, this.error, this.busy = false, this.proxy = const OhosLinuxProxyConfiguration.inherit()});

  final OhosLinuxSnapshot? snapshot;
  final Object? error;
  final bool busy;
  final OhosLinuxProxyConfiguration proxy;

  OhosLinuxState get state => snapshot?.state ?? OhosLinuxState.unknown;

  /// Installing, switching off or stopping: worth asking again shortly.
  bool get moving => const {OhosLinuxState.installing, OhosLinuxState.disabling, OhosLinuxState.stopping}.contains(state);

  OhosLinuxView copyWith({OhosLinuxSnapshot? snapshot, Object? error, bool clearError = false, bool? busy, OhosLinuxProxyConfiguration? proxy}) =>
      OhosLinuxView(
        snapshot: snapshot ?? this.snapshot,
        error: clearError ? null : (error ?? this.error),
        busy: busy ?? this.busy,
        proxy: proxy ?? this.proxy,
      );
}

/// [OhosLinuxController.reinstall] did not go through; [code] is the engine's.
class OhosLinuxReinstallFailure implements Exception {
  const OhosLinuxReinstallFailure(this.code);
  final String code;

  /// Linux created a VM in this app process, which may still hold the data.
  bool get needsRestart => code == 'ERR_OHOS_LINUX_RESTART_REQUIRED';

  @override
  String toString() => 'OhosLinuxReinstallFailure($code)';
}

final ohosLinuxRuntimeProvider = Provider<OhosLinuxRuntime>((ref) => const OhosLinuxRuntime());
final ohosLinuxSecretsProvider = Provider<AppSecureStorage>((ref) => const AppSecureStorage());

class OhosLinuxController extends Notifier<OhosLinuxView> {
  static const wantedKey = 'ohos_linux_wanted';
  static const proxyKey = 'ohos.linux.proxy';
  static const _poll = Duration(seconds: 1);

  Timer? _timer;

  @override
  OhosLinuxView build() {
    ref.onDispose(() => _timer?.cancel());
    unawaited(_loadProxy());
    return const OhosLinuxView();
  }

  OhosLinuxRuntime get _runtime => ref.read(ohosLinuxRuntimeProvider);

  Future<void> _loadProxy() async {
    final saved = await _readProxy();
    if (ref.mounted) state = state.copyWith(proxy: saved);
  }

  Future<OhosLinuxProxyConfiguration> _readProxy() async {
    try {
      final raw = await ref.read(ohosLinuxSecretsProvider).read(key: proxyKey);
      return raw == null ? const OhosLinuxProxyConfiguration.inherit() : proxyFromJson(raw);
    } catch (_) {
      return const OhosLinuxProxyConfiguration.inherit();
    }
  }

  /// Asks the engine where Linux stands; keeps asking while it is on the move.
  Future<void> refresh() => _run(_runtime.getStatus);

  /// The switch. Turning on applies the saved proxy first, so the first job
  /// already uses it.
  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(wantedKey, enabled);
    if (enabled) await _run(() => _runtime.setProxy(state.proxy));
    await _run(() => _runtime.setEnabled(enabled));
  }

  /// 重新安装 Linux, after the page's confirmation: everything inside Linux
  /// goes, the switch stays off and the next switch-on installs afresh. It
  /// never switches Linux on, even when the user's saved wish is on.
  Future<void> reinstall() => _run(() async {
    try {
      await _runtime.discardRetained();
    } on PlatformException catch (error) {
      throw OhosLinuxReinstallFailure(error.code);
    }
    return _runtime.getStatus();
  });

  /// Saves the proxy and gives it to the engine now.
  Future<void> setProxy(OhosLinuxProxyConfiguration proxy) async {
    final secrets = ref.read(ohosLinuxSecretsProvider);
    if (proxy.mode == OhosLinuxProxyMode.inherit) {
      await secrets.delete(key: proxyKey);
    } else {
      await secrets.write(key: proxyKey, value: proxyToJson(proxy));
    }
    state = state.copyWith(proxy: proxy);
    await _run(() => _runtime.setProxy(proxy));
  }

  /// The engine is running again: give back the proxy and, if the user left
  /// Linux on, switch it back on (a retained install resumes in seconds).
  Future<void> restore() async {
    final proxy = await _readProxy();
    if (!ref.mounted) return;
    state = state.copyWith(proxy: proxy);
    final prefs = await SharedPreferences.getInstance();
    final wanted = prefs.getBool(wantedKey) ?? false;
    if (proxy.mode != OhosLinuxProxyMode.inherit) await _run(() => _runtime.setProxy(proxy));
    if (wanted) {
      await _run(() => _runtime.setEnabled(true));
    } else {
      await refresh();
    }
  }

  Future<void> _run(Future<OhosLinuxSnapshot> Function() call) async {
    if (!ref.mounted) return;
    state = state.copyWith(busy: true);
    try {
      final snapshot = await call();
      if (!ref.mounted) return;
      state = state.copyWith(snapshot: snapshot, busy: false, clearError: true);
    } catch (error) {
      if (!ref.mounted) return;
      state = state.copyWith(error: error, busy: false);
    }
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (state.moving && ref.mounted) _timer = Timer(_poll, () => unawaited(refresh()));
  }
}

final ohosLinuxProvider = NotifierProvider<OhosLinuxController, OhosLinuxView>(OhosLinuxController.new);

String proxyToJson(OhosLinuxProxyConfiguration proxy) => jsonEncode(proxy.toMap());

OhosLinuxProxyConfiguration proxyFromJson(String raw) {
  final value = jsonDecode(raw);
  if (value is! Map) return const OhosLinuxProxyConfiguration.inherit();
  String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
  return switch (value['mode']) {
    'direct' => const OhosLinuxProxyConfiguration.direct(),
    'manual' => OhosLinuxProxyConfiguration.manual(
      httpProxy: text(value['httpProxy']),
      httpsProxy: text(value['httpsProxy']),
      noProxy: text(value['noProxy']),
    ),
    _ => const OhosLinuxProxyConfiguration.inherit(),
  };
}
