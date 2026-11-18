// 粘贴 on a field. Android reads Flutter's clipboard as ever. A plain HarmonyOS
// package can't: the system's own paste button has to say yes first, in a window
// of its own ([PasteReader]), so a read can come back with nothing for several
// reasons, and can outlive what it was for.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../clipboard/paste_reader.dart';
import '../../state/android_features.dart';
import 'brief_notice.dart';

mixin FieldPaste<T extends StatefulWidget> on State<T> {
  PasteRead? _pasteRead;

  /// The clipboard's text as it is; the field keeps its own trimming and checks,
  /// [mounted] among them. Null when there is none. On HarmonyOS that includes
  /// backing out, or a read that failed, which has been said by the time this
  /// returns: by [say], for a field a brief notice wouldn't show over (a sheet
  /// covers them), or else as a brief notice.
  @protected
  Future<String?> readClipboard({void Function(String message)? say}) async {
    final scope = ProviderScope.containerOf(context, listen: false);
    if (scope.read(operatingSystemProvider) != 'ohos') {
      return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    }
    if (_pasteRead != null) return null;
    final read = _pasteRead = scope.read(pasteReaderProvider).begin();
    final result = await read.finish();
    _pasteRead = null;
    if (!mounted) return null;
    if (pasteFailureText(result) case final message?) {
      if (say != null) {
        say(message);
      } else {
        ScaffoldMessenger.maybeOf(context)?.showBriefNotice(message);
      }
    }
    return result.text;
  }

  /// Gives up on a read under way, because what it was for has changed.
  @protected
  void cancelPaste() => _pasteRead?.cancel();

  @override
  void dispose() {
    _pasteRead?.cancel();
    super.dispose();
  }
}
