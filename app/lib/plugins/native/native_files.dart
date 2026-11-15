import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'native_effects.dart';
import 'native_file_platform.dart';
import 'native_state.dart';

abstract interface class NativeFileTransport {
  Future<void> upload(String request, String stream, NativeSelectedFile file, Uint8List bytes);
  Future<DshGoInvokeResult> complete(String request, String stream, String status);
}

class ClientNativeFileTransport implements NativeFileTransport {
  ClientNativeFileTransport(this.client);
  final DshClient client;
  @override
  Future<void> upload(String request, String stream, NativeSelectedFile file, Uint8List bytes) =>
      client.uploadDshGoPickedFile(request, bytes, stream: stream, name: file.name, mediaType: file.mediaType);
  @override
  Future<DshGoInvokeResult> complete(String request, String stream, String status) =>
      client.completeDshGoFileSelection(request, stream: stream, status: status);
}

/// App-wide, including a previous host whose chooser is still returning.
class NativeFileGate {
  bool _busy = false;
  bool claim() {
    if (_busy) return false;
    return _busy = true;
  }

  void release() => _busy = false;
}

final nativeFileGateProvider = Provider<NativeFileGate>((ref) => NativeFileGate());

enum NativeFileProblem { unavailable, busy, limit, failed }

class NativeFileException implements Exception {
  const NativeFileException(this.problem);
  final NativeFileProblem problem;
}

/// A deadline is independent of the provider's asynchronous stream cleanup.
/// In particular, cancelling an async* subscription cannot interrupt its await
/// of a MethodChannel read. Revoke this owner first, observe source cleanup
/// without awaiting it, and settle once so a late read cannot upload bytes.
class _NativeFileRead {
  _NativeFileRead(this._bytes, {required this.cancelNative, required this.isCurrent});

  final Future<void> Function() cancelNative;
  final bool Function() isCurrent;
  final _result = Completer<int?>();
  Uint8List? _bytes;
  StreamSubscription<List<int>>? _source;
  Timer? _timer;
  var _length = 0;
  var _finished = false;

  Future<int?> read(Stream<List<int>> stream) {
    _arm();
    try {
      _source = stream.listen(_chunk, onError: _error, onDone: _done);
      if (_finished) _cancelSource();
    } catch (error, stack) {
      _error(error, stack);
    }
    return _result.future;
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 10), () => _error(TimeoutException('selected file read made no progress')));
  }

  void _chunk(List<int> chunk) {
    if (_finished) return;
    if (!isCurrent()) return cancel();
    if (chunk.isEmpty) return; // Empty events are not byte progress.
    final bytes = _bytes!;
    if (_length + chunk.length > bytes.length) {
      return _error(const NativeFileException(NativeFileProblem.limit));
    }
    bytes.setRange(_length, _length + chunk.length, chunk);
    _length += chunk.length;
    _arm();
  }

  void cancel() => _finish(cancel: true);
  void _done() => _finish();
  void _error(Object error, [StackTrace? stack]) => _finish(error: error, stack: stack, cancel: true);

  void _finish({Object? error, StackTrace? stack, bool cancel = false}) {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    _timer = null;
    _bytes = null;
    if (cancel) {
      // This function captures the original request, never the coordinator's
      // later owner. Native ioBusy/closing remains authoritative after the App
      // gate is released if a provider has not actually stopped its worker yet.
      unawaited(cancelNative().catchError((Object _) {}));
      _cancelSource();
    } else {
      _source = null;
    }
    if (error == null) {
      _result.complete(cancel ? null : _length);
    } else {
      _result.completeError(error, stack);
    }
  }

  void _cancelSource() {
    final source = _source;
    _source = null;
    if (source != null) unawaited(Future<void>.sync(source.cancel).catchError((Object _) {}));
  }
}

/// Owns a single immediate selection through upload and its one-shot callback.
/// The bridge rechecks the same limits; a device claim never grants extra authority.
class NativeFileCoordinator {
  NativeFileCoordinator({
    required this.platform,
    required this.transport,
    required this.gate,
    this.holdSystemSelection,
  });
  final NativeFilePlatform platform;
  final NativeFileTransport transport;
  final NativeFileGate gate;
  final void Function() Function()? holdSystemSelection;
  String? _owner;
  String? package;
  bool _cancelled = false;
  Completer<void>? _cancelSignal;
  Future<void> Function()? _cancelNative;
  _NativeFileRead? _reader;

  Future<void> cancel() async {
    _cancelled = true;
    if (_cancelSignal?.isCompleted == false) _cancelSignal!.complete();
    final cancelNative = _cancelNative;
    _reader?.cancel();
    if (cancelNative != null) await cancelNative();
  }

  Future<DshGoInvokeResult?> execute(
    PickFileEffect effect, {
    required String pkg,
    required String stream,
    required bool userGesture,
    required DateTime tappedAt,
    required DateTime Function() now,
    required bool Function() isCurrent,
  }) async {
    // Reject before any platform call. A late/unsolicited token is still released on its own host.
    if (!userGesture || !nativeTapIsFresh(tappedAt, now()) || !isCurrent()) {
      await _dismiss(effect.request, stream, 'cancelled');
      return null;
    }
    if (_owner != null || !gate.claim()) {
      await _dismiss(effect.request, stream, 'cancelled');
      throw const NativeFileException(NativeFileProblem.busy);
    }
    _owner = effect.request;
    package = pkg;
    _cancelled = false;
    _cancelSignal = Completer<void>();
    Future<void>? nativeCancellation;
    // Deduplicate deadline, external cancel and final cleanup, with an owner
    // captured by this invocation rather than looked up after another await.
    Future<void> cancelNative() => nativeCancellation ??= Future<void>.sync(() => platform.cancel(effect.request));
    _cancelNative = cancelNative;
    var completed = false;
    void Function()? releaseBackground;
    bool current() => !_cancelled && isCurrent();
    try {
      if (!await platform.supported()) throw const NativeFileException(NativeFileProblem.unavailable);
      if (!current() || !nativeTapIsFresh(tappedAt, now())) return null;
      releaseBackground = holdSystemSelection?.call();
      final files = await Future.any([
        platform.pick(effect).timeout(const Duration(minutes: 5)),
        _cancelSignal!.future.then((_) => <NativeSelectedFile>[]),
      ]);
      if (!current()) return null;
      if (files.length > effect.maxFiles) throw const NativeFileException(NativeFileProblem.limit);
      var reported = 0;
      for (final file in files) {
        final size = file.length;
        if (size != null) {
          if (size < 0 || size > effect.maxBytes) throw const NativeFileException(NativeFileProblem.limit);
          reported += size;
          if (reported > effect.maxTotalBytes) throw const NativeFileException(NativeFileProblem.limit);
        }
      }
      var total = 0;
      for (final file in files) {
        if (!current()) return null;
        // Preallocate one bounded buffer, not a growing list of unchecked provider chunks.
        final capacity = effect.maxBytes < effect.maxTotalBytes - total
            ? effect.maxBytes
            : effect.maxTotalBytes - total;
        final bytes = Uint8List(capacity);
        final reader = _NativeFileRead(bytes, cancelNative: cancelNative, isCurrent: current);
        _reader = reader;
        int? length;
        try {
          length = await reader.read(file.openRead());
        } finally {
          if (identical(_reader, reader)) _reader = null;
        }
        if (length == null) return null;
        total += length;
        if (!current()) return null;
        await transport.upload(effect.request, stream, file, Uint8List.sublistView(bytes, 0, length));
      }
      if (!current()) return null;
      final response = await transport.complete(effect.request, stream, files.isEmpty ? 'cancelled' : 'selected');
      // Only once it got there: a complete lost on the way is closed below,
      // or the bridge keeps the request and refuses the next pick.
      completed = true;
      return current() ? response : null;
    } catch (error) {
      if (!completed) {
        completed = true;
        await _dismiss(effect.request, stream, current() ? 'error' : 'cancelled');
      }
      if (!current()) return null;
      if (error is NativeFileException) rethrow;
      if (error is PlatformException && error.code == 'too-large') {
        throw const NativeFileException(NativeFileProblem.limit);
      }
      if (error is PlatformException && error.code == 'busy') throw const NativeFileException(NativeFileProblem.busy);
      throw const NativeFileException(NativeFileProblem.failed);
    } finally {
      try {
        releaseBackground?.call();
        if (!completed) await _dismiss(effect.request, stream, 'cancelled');
      } finally {
        try {
          await cancelNative();
        } finally {
          _owner = null;
          _cancelSignal = null;
          _cancelNative = null;
          _reader = null;
          package = null;
          gate.release();
        }
      }
    }
  }

  Future<void> _dismiss(String request, String stream, String status) async {
    try {
      await transport.complete(request, stream, status);
    } catch (_) {
      // Disconnection/expiry revokes the same request at the bridge.
    }
  }
}

final nativeFileCoordinatorProvider = Provider<NativeFileCoordinator?>((ref) {
  final bridge = ref.watch(nativeBridgeProvider);
  final stream = ref.watch(nativeStreamProvider);
  if (bridge is! ClientNativeBridge || stream == null || !bridge.client.canReachDshGo) return null;
  final runtime = NativeFileCoordinator(
    platform: ref.watch(nativeFilePlatformProvider),
    transport: ClientNativeFileTransport(bridge.client),
    gate: ref.watch(nativeFileGateProvider),
    holdSystemSelection: stream.holdSystemSelection,
  );
  final link = stream.links.listen((state) {
    if (state != DshGoLink.open) unawaited(runtime.cancel());
  });
  ref.listen(nativeContributionsProvider, (_, next) {
    final pkg = runtime.package;
    if (pkg != null && (next.plugin(pkg)?.native != true || next.plugin(pkg)?.capabilities.contains('files') != true)) {
      unawaited(runtime.cancel());
    }
  });
  ref.onDispose(() {
    unawaited(link.cancel());
    unawaited(runtime.cancel());
  });
  return runtime;
});
