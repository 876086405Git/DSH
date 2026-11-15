import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/onboarding_state.dart';
import 'package:dsh_app/ui/engine/engine_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../onboarding/local_optional_support.dart';
import '../shell/golden_harness.dart';

class _Runtime extends RecordingLocalRuntime {
  _Runtime() : super(const LocalRuntimeState(loaded: true, status: stoppedStatus));
  @override
  Future<void> resetKeeping(ResetKeep keep) async {
    throw PlatformException(code: 'reset_busy', message: 'synthetic stop deadline');
  }
}

Future<void> frames(WidgetTester tester) async {
  for (var n = 0; n < 6; n++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final os in ['ios', 'android']) {
    for (final declined in [false, true]) {
      testWidgets('$os failed uninstall preserves prior local decline=$declined', (tester) async {
        usePhoneSurface(tester);
        await tester.pumpWidget(
          goldenApp(
            home: const EngineScreen(),
            brightness: Brightness.light,
            prefs: OnboardingPrefs(loaded: true, welcomeSeen: true, localDeclined: declined),
            overrides: [
              operatingSystemProvider.overrideWithValue(os),
              localRuntimeProvider.overrideWith(_Runtime.new),
              localRuntimeLogsProvider.overrideWithBuild((ref, notifier) => const []),
            ],
          ),
        );
        await frames(tester);
        final container = ProviderScope.containerOf(tester.element(find.byType(EngineScreen)));
        await tester.scrollUntilVisible(find.text('卸载运行环境'), 500, scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(find.text('卸载运行环境'));
        await frames(tester);
        await tester.tap(find.text('卸载运行环境'));
        await frames(tester);
        await tester.tap(find.widgetWithText(FilledButton, '卸载'));
        await frames(tester);
        expect(container.read(localRuntimeProvider).status.phase, RuntimePhase.installed);
        expect(container.read(onboardingPrefsProvider).localDeclined, os == 'ios' ? declined : false);
        await tester.pumpWidget(const SizedBox());
        await frames(tester);
      });
    }
  }
}
