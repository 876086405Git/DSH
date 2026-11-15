// 提示词增强按钮的交互：空输入不可点、生成中可取消、可撤回只在草稿等于结果时出现。

import 'package:dsh_app/state/prompt_enhance_state.dart';
import 'package:dsh_app/ui/chat/prompt_enhance_button.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_fonts.dart';

Widget _app(Widget child, {Brightness brightness = Brightness.light, bool disableAnimations = false}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: withTestFonts(buildLightTheme()),
    darkTheme: withTestFonts(buildDarkTheme()),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: disableAnimations),
      child: child!,
    ),
    home: Scaffold(body: Center(child: child)),
  );
}

class _Counters {
  int enhance = 0;
  int cancel = 0;
  int undo = 0;
}

Future<_Counters> _pump(
  WidgetTester tester, {
  required TextEditingController controller,
  required PromptEnhancePhase phase,
  String? undoResult,
  bool connected = true,
  bool ready = true,
  bool disableAnimations = false,
}) async {
  final counters = _Counters();
  await tester.pumpWidget(
    _app(
      PromptEnhanceButton(
        controller: controller,
        phase: phase,
        undoResult: undoResult,
        connected: connected,
        ready: ready,
        onEnhance: () => counters.enhance++,
        onCancel: () => counters.cancel++,
        onUndo: () => counters.undo++,
      ),
      disableAnimations: disableAnimations,
    ),
  );
  await tester.pump();
  return counters;
}

void main() {
  testWidgets('空输入：按钮不可点，只显示 ✨', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final counters = await _pump(tester, controller: controller, phase: PromptEnhancePhase.idle);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined), warnIfMissed: false);
    await tester.pump();
    expect(counters.enhance, 0, reason: '空输入不发起请求');
  });

  testWidgets('有内容：点 ✨ 发起增强', (tester) async {
    final controller = TextEditingController(text: '加个删除按钮');
    addTearDown(controller.dispose);
    final counters = await _pump(tester, controller: controller, phase: PromptEnhancePhase.idle);
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await tester.pump();
    expect(counters.enhance, 1);
    expect(counters.cancel, 0);
    expect(counters.undo, 0);
  });

  testWidgets('生成中：再点一次取消，图标仍是 ✨', (tester) async {
    final controller = TextEditingController(text: '加个删除按钮');
    addTearDown(controller.dispose);
    final counters = await _pump(tester, controller: controller, phase: PromptEnhancePhase.busy);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await tester.pump();
    expect(counters.cancel, 1);
    expect(counters.enhance, 0);
  });

  testWidgets('生成中会闪烁（不透明度在变化）', (tester) async {
    final controller = TextEditingController(text: '加个删除按钮');
    addTearDown(controller.dispose);
    await _pump(tester, controller: controller, phase: PromptEnhancePhase.busy);
    final fade = tester.widget<FadeTransition>(
      find.ancestor(of: find.byIcon(Icons.auto_awesome_outlined), matching: find.byType(FadeTransition)).first,
    );
    final before = fade.opacity.value;
    await tester.pump(const Duration(milliseconds: 400));
    final after = fade.opacity.value;
    expect(before, isNot(equals(after)), reason: '闪烁应在 1.6s 周期内改变不透明度');
  });

  testWidgets('减少动态效果时静止显示 ✨', (tester) async {
    final controller = TextEditingController(text: '加个删除按钮');
    addTearDown(controller.dispose);
    await _pump(
      tester,
      controller: controller,
      phase: PromptEnhancePhase.busy,
      disableAnimations: true,
    );
    final fade = tester.widget<FadeTransition>(
      find.ancestor(of: find.byIcon(Icons.auto_awesome_outlined), matching: find.byType(FadeTransition)).first,
    );
    final before = fade.opacity.value;
    await tester.pump(const Duration(milliseconds: 400));
    expect(fade.opacity.value, before);
  });

  testWidgets('草稿等于结果：显示 ↺ 并恢复原文', (tester) async {
    final controller = TextEditingController(text: '请给会话列表加删除按钮');
    addTearDown(controller.dispose);
    final counters = await _pump(
      tester,
      controller: controller,
      phase: PromptEnhancePhase.undo,
      undoResult: '请给会话列表加删除按钮',
    );
    expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.undo_rounded));
    await tester.pump();
    expect(counters.undo, 1);
  });

  testWidgets('草稿被改过：撤回按钮消失，回到 ✨', (tester) async {
    final controller = TextEditingController(text: '请给会话列表加删除按钮（我自己改的）');
    addTearDown(controller.dispose);
    final counters = await _pump(
      tester,
      controller: controller,
      phase: PromptEnhancePhase.undo,
      undoResult: '请给会话列表加删除按钮',
    );
    expect(find.byIcon(Icons.undo_rounded), findsNothing);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined));
    await tester.pump();
    expect(counters.undo, 0);
    expect(counters.enhance, 1, reason: '改了内容后应该能再次增强');
  });

  testWidgets('没连上时不可点', (tester) async {
    final controller = TextEditingController(text: '加个删除按钮');
    addTearDown(controller.dispose);
    final counters = await _pump(
      tester,
      controller: controller,
      phase: PromptEnhancePhase.idle,
      connected: false,
    );
    await tester.tap(find.byIcon(Icons.auto_awesome_outlined), warnIfMissed: false);
    await tester.pump();
    expect(counters.enhance, 0);
  });
}
