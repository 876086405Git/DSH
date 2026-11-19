// What a bundle (tool/bundle_tests.py) does around each test file it runs: the
// file used to have a process to itself, so it gets back what a fresh process
// gave it. This half is for files that never use the widget binding;
// `bundle_widgets.dart` is for the rest.

import 'dart:io';

import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/method_channel_shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'test_defaults.dart';

void bundled(String path, void Function() body, {void Function()? fresh}) {
  group(path, () {
    setUpAll(() {
      // Goldens are looked up next to the test file, not next to the bundle.
      goldenFileComparator = LocalFileComparator(File(path).absolute.uri);
      applyTestDefaults();
      // A future cached by a widget test of the file before never completes
      // outside that test: nothing an earlier file loaded is kept.
      rootBundle.clear();
      WhaleSprites.reset();
      // No preferences until the file sets its own, as in a new process.
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = MethodChannelSharedPreferencesStore();
      SharedPreferencesAsyncPlatform.instance = null;
      fresh?.call();
    });
    body();
  });
}
