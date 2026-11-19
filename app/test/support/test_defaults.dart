// The app-wide switches every test file starts from. Set by
// `test/flutter_test_config.dart` when a file has a process to itself, and
// again before each file of a bundle (`support/bundle.dart`).

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/pets/pet_sheets.dart';
import 'package:dsh_app/state/locale_state.dart';
import 'package:dsh_app/ui/chat/empty_actions.dart' show tipStart;
import 'package:dsh_app/ui_config/ui_config_state.dart';

import 'english_preview.dart';
import 'quiet_performance.dart';

void applyTestDefaults() {
  // The chat page's pet is drawn only where a test asks for it
  // (test/pets/): elsewhere a sheet decoding in a stray real-async window
  // would make screens flicker between with and without a pet.
  PetSheets.enabled = false;
  // The new-chat tip line starts on a random tip in the app; tests (and the
  // goldens that show the new-chat page) start on the first one.
  tipStart = (_) => 0;
  // No device facts in tests: the app reads "unavailable" at once.
  PerformanceChannel.create = QuietPerformanceChannel.new;
  defaultUiConfigSourceBuilder = (_, _) => null;
  // Tests run in Chinese (goldens and finders were made in it); English
  // tests opt in with AppLocale.use(AppLocale.en) + an English MaterialApp.
  AppLanguageController.initial = AppLanguage.zh;
  AppLocale.use(AppLocale.zhCN);
  setUpEnglishPreview();
}
