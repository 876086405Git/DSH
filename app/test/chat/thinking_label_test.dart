// The thinking label: a brightness sweep 600 ms in, 1 s long, every 4 s. Between
// sweeps nothing ticks and nothing masks the text; only one sweeps at a time;
// with animations off it is plain still text.

import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/common/think_glyph.dart';
import 'package:dsh_app/ui/fx/orbs/thinking_orb.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Widget _labels(List<Widget> labels, {bool reduced = false}) => MediaQuery(
  data: MediaQueryData(disableAnimations: reduced),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Column(children: labels),
  ),
);

Finder _maskOver(String text) => find.ancestor(of: find.text(text), matching: find.byType(ShaderMask));

Future<void> _advance(WidgetTester tester, Duration by) async {
  await tester.pump(by);
  // A timer fired during that pump: its sweep starts on the next frame.
  await tester.pump();
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('sweeps after the lead, then rests with its ticker stopped', (tester) async {
    await tester.pumpWidget(_labels([const ThinkingLabel('思考中', active: true)]));
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);

    await _advance(tester, const Duration(milliseconds: 599));
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);

    await _advance(tester, const Duration(milliseconds: 2));
    expect(_maskOver('思考中'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 1);

    await tester.pump(const Duration(milliseconds: 500));
    expect(_maskOver('思考中'), findsOneWidget);

    // Sweep over: the 3 s rest asks for no frames, and no layer stays behind.
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pump();
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(milliseconds: 2900));
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);

    // 4 s after the first one, the next.
    await _advance(tester, const Duration(milliseconds: 150));
    expect(_maskOver('思考中'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 1);
  });

  testWidgets('rests in the plain label colour and masks only the label', (tester) async {
    await tester.pumpWidget(testApp(const Scaffold(body: Center(child: ThinkingLabel('思考中', active: true)))));
    final colors = Theme.of(tester.element(find.text('思考中'))).colorScheme;
    expect(tester.widget<Text>(find.text('思考中')).style?.color, colors.onSurfaceVariant);

    await _advance(tester, const Duration(milliseconds: 601));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<ShaderMask>(_maskOver('思考中')).blendMode, BlendMode.srcIn);
    final boundary = find.ancestor(of: find.byType(ShaderMask), matching: find.byType(RepaintBoundary)).first;
    expect(tester.getSize(boundary), tester.getSize(find.text('思考中')));
  });

  testWidgets('animations off: still text, no timer, no mask, no boundary', (tester) async {
    await tester.pumpWidget(_labels([const ThinkingLabel('思考中', active: true)], reduced: true));
    await _advance(tester, const Duration(milliseconds: 601));
    expect(find.byType(ShaderMask), findsNothing);
    expect(find.byType(RepaintBoundary), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 8));
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('turning animations off mid-sweep stops at the plain label', (tester) async {
    await tester.pumpWidget(_labels([const ThinkingLabel('思考中', active: true)]));
    await _advance(tester, const Duration(milliseconds: 601));
    expect(find.byType(ShaderMask), findsOneWidget);
    await tester.pumpWidget(_labels([const ThinkingLabel('思考中', active: true)], reduced: true));
    await tester.pump();
    expect(find.byType(ShaderMask), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('a finished row stops at once and carries nothing', (tester) async {
    await tester.pumpWidget(_labels([const ThinkingLabel('思考中', active: true)]));
    await _advance(tester, const Duration(milliseconds: 601));
    await tester.pumpWidget(_labels([const ThinkingLabel('思考')]));
    await tester.pump();
    expect(find.byType(ShaderMask), findsNothing);
    expect(find.byType(RepaintBoundary), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pump(const Duration(seconds: 8));
    expect(find.byType(ShaderMask), findsNothing);
  });

  testWidgets('only one sweeps at a time: the newest, then the one still thinking', (tester) async {
    await tester.pumpWidget(
      _labels([
        const ThinkingLabel('甲', key: ValueKey('a'), active: true),
        const ThinkingLabel('乙', key: ValueKey('b')),
      ]),
    );
    await _advance(tester, const Duration(milliseconds: 601));
    expect(_maskOver('甲'), findsOneWidget);

    // 乙 starts thinking 300 ms into 甲's sweep and takes over when it first sweeps.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      _labels([
        const ThinkingLabel('甲', key: ValueKey('a'), active: true),
        const ThinkingLabel('乙', key: ValueKey('b'), active: true),
      ]),
    );
    await _advance(tester, const Duration(milliseconds: 601));
    expect(_maskOver('乙'), findsOneWidget);
    expect(_maskOver('甲'), findsNothing);
    expect(find.byType(ShaderMask), findsOneWidget);

    // 甲's next turn comes and goes untouched while 乙 holds it.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(_maskOver('甲'), findsNothing, reason: 'at ${i * 100} ms');
    }

    // 乙 finishes: 甲 sweeps again on its next beat.
    await tester.pumpWidget(
      _labels([
        const ThinkingLabel('甲', key: ValueKey('a'), active: true),
        const ThinkingLabel('乙', key: ValueKey('b')),
      ]),
    );
    var swept = false;
    for (var i = 0; i < 45 && !swept; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      swept = _maskOver('甲').evaluate().isNotEmpty;
    }
    expect(swept, isTrue);
    expect(_maskOver('乙'), findsNothing);
  });

  testWidgets('growing reasoning leaves the header alone and updates the ticker', (tester) async {
    final thought = ValueNotifier('推');
    addTearDown(thought.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: thought,
            builder: (context, text, _) => ThinkingPill(reasoning: text, active: true, streaming: true),
          ),
        ),
      ),
    );
    final labels = {tester.widget<ThinkingLabel>(find.byType(ThinkingLabel))};
    for (var i = 0; i < 20; i++) {
      thought.value += '理';
      await tester.pump(const Duration(milliseconds: 32));
      labels.add(tester.widget<ThinkingLabel>(find.byType(ThinkingLabel)));
    }
    expect(tester.widget<ThinkingTicker>(find.byType(ThinkingTicker)).text, '推${'理' * 20}');
    expect(labels, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'the whole pill: a thinking orb while active, the quiet glyph after; the label sweeps only while active',
    (tester) async {
      Widget pill(bool active) => testApp(
        Scaffold(
          body: ThinkingPill(reasoning: '第一段\n第二段', active: active, streaming: active),
        ),
      );
      await tester.pumpWidget(pill(true));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1800));
      final orb = tester.widget<ThinkingOrb>(
        find.descendant(of: find.byType(ThinkingPill), matching: find.byType(ThinkingOrb)),
      );
      expect(orb.state, OrbState.breathing);
      expect(find.byType(ThinkGlyph), findsNothing);
      expect(find.descendant(of: find.byType(ThinkingPill), matching: find.byType(ThinkingTicker)), findsOneWidget);

      await tester.pumpWidget(pill(false));
      await pumpFrames(tester);
      expect(find.byType(ThinkingOrb), findsNothing);
      expect(find.byType(ThinkGlyph), findsOneWidget);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pump(const Duration(seconds: 8));
      expect(find.descendant(of: find.byType(ThinkingLabel), matching: find.byType(ShaderMask)), findsNothing);
    },
  );
}
