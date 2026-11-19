// `bundle.dart` for files that use the widget binding. The binding outlives
// the file here, so what one file left on it is put back before the next.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'bundle.dart';

void bundledWidgets(String path, void Function() body) => bundled(path, body, fresh: _freshBinding);

HttpOverrides? _http;

void _freshBinding() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _http ??= _WidgetTestHttp(HttpOverrides.current!);
  binding.platformDispatcher.clearAllTestValues();
  for (final view in binding.platformDispatcher.views) {
    view.reset();
  }
  binding.resetInternalState();
  imageCache.clear();
  imageCache.clearLiveImages();
}

/// The binding answers every HTTP request with 400 from the moment it exists.
/// A file on its own got that only after its first widget test; its plain
/// tests before then reached their local servers. Here the binding is already
/// there, so the 400s are kept to widget tests.
class _WidgetTestHttp extends HttpOverrides {
  _WidgetTestHttp(this.refusing);

  final HttpOverrides refusing;

  @override
  HttpClient createHttpClient(SecurityContext? context) => TestWidgetsFlutterBinding.instance.inTest
      ? refusing.createHttpClient(context)
      : super.createHttpClient(context);
}
