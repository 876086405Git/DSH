import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// A document chooser belongs to the document that requested it. Navigation,
/// a renderer loss or disposal retires it even if Android returns a file later.
/// The platform returns temporary content URIs (on HarmonyOS the system
/// picker's `file://docs/…` and `file://media/…`), without copying file contents
/// into Dart or granting the page access to app-private filesystem paths.
class WebFileChooser {
  WebFileChooser({MethodChannel? channel, bool? ohos, this._canChoose})
    : _channel = channel ?? const MethodChannel('dsh/web-files'),
      _ohos = ohos ?? Platform.operatingSystem == 'ohos';

  final MethodChannel _channel;
  final bool _ohos;
  final bool Function()? _canChoose;
  int _generation = 0;
  bool _disposed = false;
  bool _busy = false;
  String? _owner;

  Future<void> attach(WebViewController controller) async {
    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setOnShowFileSelector(
        (params) => choose(params, webViewId: platform.webViewIdentifier, currentUrl: controller.currentUrl),
      );
    } else if (_ohos) {
      // oh-flutter's controller has the same method and fields, but its package
      // is only in the HarmonyOS build.
      final dynamic ohos = platform;
      await ohos.setOnShowFileSelector(
        (dynamic params) => choose(
          FileSelectorParams(
            isCaptureEnabled: params.isCaptureEnabled as bool,
            acceptTypes: List<String>.from(params.acceptTypes as List),
            filenameHint: params.filenameHint as String?,
            mode: FileSelectorMode.values.byName((params.mode as Enum).name),
          ),
          webViewId: ohos.webViewIdentifier as int,
          currentUrl: controller.currentUrl,
        ),
      );
    }
  }

  @visibleForTesting
  Future<List<String>> choose(
    FileSelectorParams params, {
    required int webViewId,
    required Future<String?> Function() currentUrl,
  }) async {
    // A file upload never creates/overwrites a local file. Capture is a hint:
    // use the system document UI without silently acquiring camera/mic access.
    if (_disposed || _busy || _canChoose?.call() == false || params.mode == FileSelectorMode.save) return const [];
    _busy = true;
    final generation = _generation;
    final owner = '$webViewId:$generation';
    bool current() => !_disposed && generation == _generation && _canChoose?.call() != false;
    try {
      final url = await currentUrl();
      final uri = Uri.tryParse(url ?? '');
      if (!current() || uri == null || !['http', 'https'].contains(uri.scheme)) {
        return const [];
      }
      _owner = owner;
      final files = await _channel.invokeListMethod<String>('pick', {
        'owner': owner,
        'webViewId': webViewId,
        'url': url,
        'acceptTypes': params.acceptTypes,
        'multiple': params.mode == FileSelectorMode.openMultiple,
      });
      if (!current()) return const [];
      final after = await currentUrl();
      if (!current() || after != url) return const [];
      if (files == null || files.isEmpty) return const [];
      // Native also validates grants/providers. Never hand an app-private path
      // or a malformed plugin response to the WebView.
      if (!files.every(_grantedUri)) return const [];
      if (params.mode == FileSelectorMode.open && files.length != 1) return const [];
      return files;
    } on Object {
      // The WebChromeClient must always receive an answer, including when a
      // renderer/platform disappears while either URL or chooser is pending.
      return const [];
    } finally {
      if (_owner == owner) _owner = null;
      _busy = false;
    }
  }

  bool _grantedUri(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    if (_ohos) return uri.scheme == 'file' && const {'docs', 'media'}.contains(uri.authority);
    return uri.scheme == 'content' && uri.authority.isNotEmpty;
  }

  void invalidate() {
    _generation++;
    final owner = _owner;
    _owner = null;
    if (owner != null) {
      unawaited(_channel.invokeMethod<void>('cancel', {'owner': owner}).catchError((Object _) {}));
    }
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }
}
