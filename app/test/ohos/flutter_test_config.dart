// Non-visual platform-channel and file-consumer tests. These do not load or
// render product fonts/assets. Visual tests keep test/flutter_test_config.dart.
import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/state/locale_state.dart';

import '../support/quiet_performance.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  PerformanceChannel.create = QuietPerformanceChannel.new;
  AppLanguageController.initial = AppLanguage.zh;
  AppLocale.use(AppLocale.zhCN);
  await testMain();
}
