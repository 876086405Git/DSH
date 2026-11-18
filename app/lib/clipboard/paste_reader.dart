import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../state/android_features.dart';

enum PasteStatus { text, empty, denied, cancelled, readFailed, unavailable, busy }

class PasteResult {
  const PasteResult(this.status, {this.text, this.shown = false});
  final PasteStatus status;
  final String? text;

  /// The native window already put up a toast saying what happened.
  final bool shown;
}

/// What to say about a read that brought no text: nothing when it was backed
/// out of, or when the native toast has said it already.
String? pasteFailureText(PasteResult result) {
  if (result.shown) return null;
  return switch (result.status) {
    PasteStatus.text || PasteStatus.cancelled => null,
    PasteStatus.empty => appL10n.statePasteEmpty,
    PasteStatus.denied => appL10n.statePasteDenied,
    PasteStatus.busy => appL10n.statePasteBusy,
    PasteStatus.readFailed || PasteStatus.unavailable => appL10n.statePasteFailed,
  };
}

/// Keep this operation with the target field; cancel it when that target is
/// disposed/replaced. A late native reply cannot deliver text to a cancelled read.
class PasteRead {
  PasteRead._(this.result, this.cancel);
  final Future<PasteResult> result;
  final void Function() cancel;

  /// [result], with the native window closed behind it. On a text result too:
  /// that only tidies up, it never reads again.
  Future<PasteResult> finish() async {
    try {
      return await result;
    } finally {
      cancel();
    }
  }
}

final pasteReaderProvider = Provider<PasteReader>((ref) {
  final reader = PasteReader(ohos: ref.watch(operatingSystemProvider) == 'ohos');
  ref.onDispose(reader.dispose);
  return reader;
});

/// OH opens a genuine native PasteButton. Calling begin() does not authorize a
/// clipboard read. Other platforms retain Flutter's existing clipboard API.
class PasteReader {
  PasteReader({required this.ohos});
  final bool ohos;
  static const _channel = MethodChannel('dsh/paste');
  static int _sequence = 0;
  final _active = <void Function()>{};
  bool _disposed = false;

  PasteRead begin() {
    final done = Completer<PasteResult>();
    final id = 'paste-${++_sequence}';
    late void Function() cancel;
    void finish(PasteResult value) {
      if (done.isCompleted) return;
      _active.remove(cancel);
      done.complete(value);
    }

    cancel = () {
      if (!done.isCompleted) finish(const PasteResult(PasteStatus.cancelled));
      if (ohos) {
        unawaited(_channel.invokeMethod<bool>('cancel', {'requestId': id}).catchError((Object _) => false));
      }
    };
    if (_disposed) {
      done.complete(const PasteResult(PasteStatus.cancelled));
    } else {
      _active.add(cancel);
      _read(id).then(finish);
    }
    return PasteRead._(done.future, cancel);
  }

  Future<PasteResult> _read(String id) async {
    try {
      if (!ohos) {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text;
        return text == null || text.isEmpty
            ? const PasteResult(PasteStatus.empty)
            : PasteResult(PasteStatus.text, text: text);
      }
      final value = await _channel.invokeMapMethod<String, Object?>('readText', {'requestId': id});
      final status = value?['status'];
      for (final candidate in PasteStatus.values) {
        if (candidate.name != status) continue;
        if (candidate != PasteStatus.text) return PasteResult(candidate, shown: value?['shown'] == true);
        final text = value?['text'];
        if (text is String && text.isNotEmpty) return PasteResult(candidate, text: text);
        return const PasteResult(PasteStatus.readFailed);
      }
      return const PasteResult(PasteStatus.readFailed);
    } on MissingPluginException {
      return const PasteResult(PasteStatus.unavailable);
    } on PlatformException {
      return const PasteResult(PasteStatus.readFailed);
    } catch (_) {
      return const PasteResult(PasteStatus.readFailed);
    }
  }

  void dispose() {
    _disposed = true;
    for (final cancel in _active.toList()) {
      cancel();
    }
  }
}
