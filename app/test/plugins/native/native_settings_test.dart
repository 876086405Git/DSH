// 设置 › 插件 › 某插件: a switch per place the plugin shows up, and one quiet
// 「原生界面」 line that opens the problems with their paths. Plugins without
// a native part get nothing.

import 'package:dsh_app/plugins/native/native_platform.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/plugins/native/native_model.dart';
import 'package:dsh_app/plugins/native/native_state.dart';
import 'package:dsh_app/ui/plugins/native/native_plugin_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

Future<ProviderContainer> pumpSection(
  WidgetTester tester,
  FakeBridge bridge,
  String package, {
  List<Override> overrides = const [],
}) async {
  usePhoneView(tester);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [NativePluginSection(package: package)],
          ),
        ),
      ),
      overrides: [...overrides, ...nativeOverrides(bridge)],
    ),
  );
  await pumpFrames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(NativePluginSection)));
}

class _Features implements NativeMediaPlatform {
  _Features(this.features);

  final Set<String> features;
  int asked = 0;

  @override
  Future<Set<String>> capabilities() async {
    asked++;
    return features;
  }

  @override
  Future<Object?> call(String method, Map<String, Object?> arguments) async => null;

  @override
  Stream<Object?> get events => const Stream.empty();
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('听你开口', () {
    final voice = {
      ...quickPlugin(),
      'capabilities': ['voice'],
    };
    Switch tile(WidgetTester tester) => tester.widget<Switch>(
      find.descendant(of: find.byKey(const ValueKey('native-switch-voice')), matching: find.byType(Switch)),
    );

    testWidgets('Android: a switch, and nothing asked of the platform for it', (tester) async {
      final platform = _Features(const {});
      await pumpSection(
        tester,
        FakeBridge(contributions([voice])),
        'dsh-go-example-quick',
        overrides: [
          operatingSystemProvider.overrideWithValue('android'),
          nativeMediaPlatformProvider.overrideWithValue(platform),
        ],
      );
      expect(tile(tester).onChanged, isNotNull);
      expect(find.text('这台设备不能听你开口'), findsNothing);
      expect(platform.asked, 0);
    });

    testWidgets('HarmonyOS, a device that can listen: the same switch, and it answers', (tester) async {
      await pumpSection(
        tester,
        FakeBridge(contributions([voice])),
        'dsh-go-example-quick',
        overrides: [
          operatingSystemProvider.overrideWithValue('ohos'),
          nativeMediaPlatformProvider.overrideWithValue(_Features(const {'audio', 'voice'})),
        ],
      );
      expect(find.text('这台设备不能听你开口'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('native-switch-voice')));
      await pumpFrames(tester);
      expect(tile(tester).value, isTrue);
    });

    testWidgets('HarmonyOS, a device that can\'t: it says so, and no dead switch', (tester) async {
      await pumpSection(
        tester,
        FakeBridge(contributions([voice])),
        'dsh-go-example-quick',
        overrides: [
          operatingSystemProvider.overrideWithValue('ohos'),
          nativeMediaPlatformProvider.overrideWithValue(_Features(const {'audio'})),
        ],
      );
      expect(find.text('这台设备不能听你开口'), findsOneWidget);
      expect(tile(tester).onChanged, isNull);
      await tester.tap(find.byKey(const ValueKey('native-switch-voice')));
      await pumpFrames(tester);
      expect(tile(tester).value, isFalse);
    });
  });

  testWidgets('a switch per declared place, then the status line', (tester) async {
    final container = await pumpSection(tester, FakeBridge(contributions([quickPlugin()])), 'dsh-go-example-quick');
    expect(find.text('输入框按钮'), findsOneWidget);
    expect(find.text('消息菜单'), findsOneWidget);
    expect(find.text('状态条'), findsNothing, reason: 'only what the plugin declares');
    expect(find.text('原生界面'), findsOneWidget);
    expect(find.text('正常'), findsOneWidget);

    await tester.tap(find.text('输入框按钮'));
    await pumpFrames(tester);
    expect(container.read(nativeComposerActionsProvider), isEmpty);
    expect(container.read(nativeMessageActionsProvider), isNotEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(NativeSurfacePrefs.prefsKey), contains('composer.actions'));

    await tester.tap(find.byType(Switch).first);
    await pumpFrames(tester);
    expect(container.read(nativeComposerActionsProvider), hasLength(2));
  });

  testWidgets('problems: counted on the line, listed with their paths; the stats when known', (tester) async {
    final bridge = FakeBridge(
      contributions([
        plugin(
          'p',
          title: '示例',
          composer: [
            {'id': 'a', 'label': 'A'},
          ],
          issues: [
            {'path': '/dshGo/contributes/composer.actions/2/label', 'code': 'too-long', 'severity': 'warn'},
            {'path': '/dshGo/contributes/panels/0/view', 'code': 'view-file', 'severity': 'error'},
          ],
        ),
      ]),
    );
    final container = await pumpSection(tester, bridge, 'p');
    container.read(nativeDiagnosticsProvider.notifier)
      ..view('p', 3277)
      ..invoked('p', const Duration(milliseconds: 48))
      ..report('p', '/runtime/a', [const NativeIssue('', '插件没有及时响应', code: 'timeout')]);
    await pumpFrames(tester);
    expect(find.text('3 项有误'), findsOneWidget);
    expect(find.text('视图 3.2 KB · 响应 48 ms'), findsOneWidget);

    await tester.tap(find.text('原生界面'));
    await tester.pumpAndSettle();
    expect(find.text('最近视图'), findsOneWidget);
    expect(find.text('3.2 KB'), findsOneWidget);
    expect(find.text('48 ms'), findsOneWidget);
    expect(find.text('插件没有及时响应'), findsOneWidget);
    expect(find.text('/runtime/a'), findsOneWidget);
    expect(find.text('文字太长，已截断'), findsOneWidget);
    expect(find.text('/dshGo/contributes/composer.actions/2/label'), findsOneWidget);
    expect(find.text('视图文件读不出'), findsOneWidget);
  });

  testWidgets('a plugin for a newer app: no switches, the line says why', (tester) async {
    await pumpSection(
      tester,
      FakeBridge(
        contributions([
          plugin(
            'old',
            state: 'needs-app',
            issues: [
              {'path': '/dshGo/minApp', 'code': 'needs-app', 'severity': 'error'},
            ],
          ),
        ]),
      ),
      'old',
    );
    expect(find.byType(Switch), findsNothing);
    expect(find.text('需要更新 App'), findsOneWidget);
  });

  testWidgets('a plugin without a native part: nothing here', (tester) async {
    await pumpSection(tester, FakeBridge(contributions([quickPlugin()])), 'some-web-plugin');
    expect(tester.getSize(find.byType(NativePluginSection)), const Size(350, 0));
  });
}
