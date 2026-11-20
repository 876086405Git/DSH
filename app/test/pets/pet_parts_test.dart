// The pieces around the pet: the run strip giving up its whale tail
// (symmetric insets once it is gone), the bubble's capsule, the alert routing
// (the pet's bubble replaces the glass banner while it is on screen), the
// empty state's whale, and 宠物设置.

import 'package:dsh_app/pets/pet_prefs.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/pets/pet_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/notify_state.dart';
import 'package:dsh_app/ui/chat/widgets/activity_strip.dart';
import 'package:dsh_app/ui/chat/widgets/live_clock.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:dsh_app/ui/pets/pet_bubble.dart';
import 'package:dsh_app/ui/pets/pet_picker.dart';
import 'package:dsh_app/ui/pets/pet_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/english_preview.dart';
import 'support.dart';

ChatAlert alert(AlertKind kind, String id) =>
    ChatAlert(host: HostRef.local, sessionId: id, kind: kind, key: turnKey, title: '标题', text: '这一轮已完成');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the run strip without its whale tail', () {
    Future<void> strip(WidgetTester tester, {required bool whale}) async {
      usePhoneView(tester);
      final clock = TestClock();
      runClock = clock.call;
      addTearDown(() => runClock = DateTime.now);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ActivityStrip(activity: stripActivity, todoProgress: false, whale: whale),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('with the tail: the tail leads, 9 from the edge', (tester) async {
      await strip(tester, whale: true);
      expect(find.byType(WhaleTail), findsOneWidget);
      final glass = tester.getRect(find.byType(ActivityStrip));
      expect(tester.getRect(find.byType(WhaleTail)).left - glass.left, closeTo(9, 0.01));
    });

    testWidgets('without: no tail, the text starts 14 in, and ends 14 from the other end', (tester) async {
      await strip(tester, whale: false);
      expect(find.byType(WhaleTail), findsNothing, reason: 'unmounted: its ticker stops');
      final glass = tester.getRect(find.byType(ActivityStrip));
      final title = tester.getRect(find.text('跑'));
      final clock = tester.getRect(find.text('0:47'));
      expect(title.left - glass.left, closeTo(14, 0.01));
      expect(glass.right - clock.right, closeTo(14, 0.01));
    });

    testWidgets('the tail folds away smoothly (no jump)', (tester) async {
      await strip(tester, whale: true);
      final before = tester.getRect(find.text('跑')).left;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ActivityStrip(activity: stripActivity, todoProgress: false, whale: false),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final mid = tester.getRect(find.text('跑')).left;
      await tester.pump(const Duration(milliseconds: 400));
      final after = tester.getRect(find.text('跑')).left;
      expect(mid, lessThan(before));
      expect(mid, greaterThan(after));
    });
  });

  group('bubble capsule', () {
    testWidgets('32 high, 12 in on both sides, one tone dot', (tester) async {
      usePhoneView(tester);
      final bubble = PetBubble(
        id: 'b',
        kind: PetBubbleKind.done,
        title: '修复登录重复提交',
        target: target('s'),
        until: DateTime(2030),
      );
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Center(
              child: PetBubbleView(bubble: bubble, onTap: () {}),
            ),
          ),
        ),
      );
      final capsule = tester.getRect(find.byType(PetBubbleView));
      final dot = tester.getRect(find.byKey(const ValueKey('pet-bubble-dot')));
      final verb = tester.getRect(find.byKey(const ValueKey('pet-bubble-verb')));
      expect(capsule.height, PetBubbleMetrics.height);
      expect(dot.left - capsule.left, closeTo(PetBubbleMetrics.pad, 0.01));
      expect(capsule.right - verb.right, closeTo(PetBubbleMetrics.pad, 0.01));
      expect(dot.center.dy, closeTo(capsule.center.dy, 0.5));
    });

    testWidgets('a live region the screen reader reads and can tap', (tester) async {
      usePhoneView(tester);
      final handle = tester.ensureSemantics();
      var taps = 0;
      final bubble = PetBubble(
        id: 'b',
        kind: PetBubbleKind.question,
        target: target('s'),
        until: DateTime(2030),
        title: '标题',
      );
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Center(
              child: PetBubbleView(bubble: bubble, onTap: () => taps++),
            ),
          ),
        ),
      );
      final node = tester.getSemantics(find.byType(PetBubbleView));
      expect(node.label, '标题 · 等你回答');
      expect(node.flagsCollection.isLiveRegion, isTrue);
      tester.semantics.tap(find.semantics.byLabel('标题 · 等你回答'));
      expect(taps, 1);
      handle.dispose();
    });
  });

  group('alerts: the bubble replaces the banner while the pet is on screen', () {
    const prefs = NotifyPrefs();

    test('foreground, another conversation, pet on screen: the pet', () {
      expect(
        deliveryFor(alert(AlertKind.done, 'b'), prefs: prefs, foreground: true, petOnScreen: true),
        AlertDelivery.pet,
      );
      expect(deliveryFor(alert(AlertKind.done, 'b'), prefs: prefs, foreground: true), AlertDelivery.banner);
    });

    test('the conversation on screen: nothing either way (the pet only moves)', () {
      expect(
        deliveryFor(
          alert(AlertKind.done, 'a'),
          prefs: prefs,
          foreground: true,
          viewed: (host: HostRef.local, sessionId: 'a'),
          petOnScreen: true,
        ),
        AlertDelivery.none,
      );
    });

    test('background: the system notification as before', () {
      expect(
        deliveryFor(alert(AlertKind.failed, 'b'), prefs: prefs, foreground: false, petOnScreen: true),
        AlertDelivery.system,
      );
    });

    test('quiet, hidden or off the chat page: not on screen (the banner comes back)', () {
      final c = ProviderContainer(
        overrides: [petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(loaded: true)))],
      );
      addTearDown(c.dispose);
      c.read(petLayerShownProvider.notifier).set(true);
      expect(c.read(petOnScreenProvider), isTrue);
      c.read(petPrefsProvider.notifier).setQuiet(true);
      expect(c.read(petOnScreenProvider), isFalse);
      c.read(petPrefsProvider.notifier).setQuiet(false);
      c.read(chatOnScreenProvider.notifier).set(false);
      expect(c.read(petOnScreenProvider), isFalse);
      c.read(chatOnScreenProvider.notifier).set(true);
      c.read(petLayerShownProvider.notifier).set(false);
      expect(c.read(petOnScreenProvider), isFalse);
    });
  });

  group('one mascot a screen', () {
    test('the empty state’s whale fades while the pet is drawn (hidden, 不显示, 网页模式: back)', () {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      expect(c.read(petTakesWhaleProvider), isFalse);
      c.read(petLayerShownProvider.notifier).set(true);
      expect(c.read(petTakesWhaleProvider), isTrue);
      c.read(petLayerShownProvider.notifier).set(false);
      expect(c.read(petTakesWhaleProvider), isFalse);
    });
  });

  group('宠物设置', () {
    Future<ProviderContainer> page(WidgetTester tester) async {
      usePhoneView(tester);
      final clock = TestClock();
      await tester.pumpWidget(
        testApp(
          const PetSettingsPage(),
          overrides: [
            petClockProvider.overrideWithValue(clock.call),
            petPackProvider.overrideWith((ref, id) async => diskPack(id)),
            petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(loaded: true))),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return ProviderScope.containerOf(tester.element(find.byType(PetSettingsPage)));
    }

    for (final brightness in Brightness.values) {
      testWidgets('golden (${brightness.name})', (tester) async {
        await warmSheets(tester, deepy, [deepy.animFor(PetStateName.idle)]);
        await warmSheets(tester, girl, [girl.animFor(PetStateName.idle)]);
        usePhoneView(tester);
        await tester.pumpWidget(
          testApp(
            const PetSettingsPage(),
            brightness: brightness,
            overrides: [
              petClockProvider.overrideWithValue(TestClock().call),
              petPackProvider.overrideWith((ref, id) async => diskPack(id)),
              petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(loaded: true))),
            ],
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final image = await tester.runAsync(() {
          final view = RendererBinding.instance.renderViews.first;
          return (view.debugLayer! as OffsetLayer).toImage(view.paintBounds);
        });
        await expectLater(image, matchesGoldenFile('goldens/pet_settings_${brightness.name}.png'));
        image!.dispose();
      });
    }

    // English smoke golden (i18n), light.
    testWidgets('golden (en)', (tester) async {
      useEnglish();
      await warmSheets(tester, deepy, [deepy.animFor(PetStateName.idle)]);
      await warmSheets(tester, girl, [girl.animFor(PetStateName.idle)]);
      usePhoneView(tester);
      await tester.pumpWidget(
        testApp(
          inEnglish(const PetSettingsPage()),
          overrides: [
            petClockProvider.overrideWithValue(TestClock().call),
            petPackProvider.overrideWith((ref, id) async => diskPack(id)),
            petPrefsProvider.overrideWith(() => FixedPetPrefs(const PetPrefs(loaded: true))),
          ],
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final image = await tester.runAsync(() {
        final view = RendererBinding.instance.renderViews.first;
        return (view.debugLayer! as OffsetLayer).toImage(view.paintBounds);
      });
      await expectLater(image, matchesGoldenFile('goldens/en_pet_settings_light.png'));
      image!.dispose();
    });

    testWidgets('three choices with names, the source line, size and quiet mode', (tester) async {
      await page(tester);
      expect(find.text('Deepy 小鲸鱼'), findsOneWidget);
      expect(find.text('鲸娘'), findsOneWidget);
      expect(find.text('不显示'), findsOneWidget);
      expect(find.textContaining('来自 DSH-TUI'), findsOneWidget);
      expect(find.text('大小'), findsOneWidget);
      for (final s in ['小', '标准', '大', '自定义']) {
        expect(find.text(s), findsOneWidget);
      }
      expect(find.text('安静模式'), findsOneWidget);
      expect(find.text('只做动作，不冒气泡'), findsOneWidget);
    });

    testWidgets('choosing: the pet, its size, quiet; 不显示 folds the rest away', (tester) async {
      final c = await page(tester);
      await tester.tap(find.text('鲸娘'));
      await tester.pump();
      expect(c.read(petPrefsProvider).packId, 'whale-girl');
      await tester.ensureVisible(find.text('大'));
      await tester.tap(find.text('大'));
      await tester.pump();
      expect(c.read(petPrefsProvider).size, PetSize.large);
      await tester.ensureVisible(find.text('安静模式'));
      await tester.tap(find.text('安静模式'));
      await tester.pump();
      expect(c.read(petPrefsProvider).quiet, isTrue);
      await tester.ensureVisible(find.text('不显示'));
      await tester.tap(find.text('不显示'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.read(petPrefsProvider).packId, noPetId);
      expect(find.text('安静模式'), findsNothing);
      expect(find.byType(PetPreview), findsNWidgets(builtInPets.length + 1));
    });

    testWidgets('自定义: a slider under the sizes, saved on release, the pet at that height', (tester) async {
      final c = await page(tester);
      expect(find.byKey(const ValueKey('pet-custom-size')), findsNothing);
      await tester.tap(find.text('自定义'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.read(petPrefsProvider).size, PetSize.custom);
      expect(find.text('100%'), findsOneWidget);
      final slider = find.byKey(const ValueKey('pet-custom-size'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, Offset(tester.getSize(slider).width, 0));
      await tester.pump();
      expect(c.read(petPrefsProvider).customHeight, PetSize.customMax);
      expect(c.read(petPrefsProvider).bodyHeight, PetSize.customMax);
      expect(find.text('300%'), findsOneWidget);
      await tester.tap(find.text('标准'));
      await tester.pump();
      expect(c.read(petPrefsProvider).bodyHeight, 30);
      expect(c.read(petPrefsProvider).customHeight, PetSize.customMax, reason: 'kept for the next 自定义');
    });
  });
}
