import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

final choose = jsonEncode({
  'type': 'stack',
  'title': '选一个方案',
  'children': [
    {
      'type': 'options',
      'id': 'plan',
      'options': [
        {'label': '方案 A'},
        {'label': '方案 B'},
      ],
    },
  ],
});

final parts = jsonEncode({
  'type': 'stack',
  'title': '要装哪些组件',
  'children': [
    {
      'type': 'options',
      'multi': true,
      'options': ['Node.js 22', 'Python 3.12', 'Rust 工具链'],
    },
  ],
});

final deploy = jsonEncode({'type': 'confirm', 'confirmLabel': '开始部署', 'cancelLabel': '再等等'});

final spending = jsonEncode({
  'type': 'chart',
  'categories': ['7月', '8月', '9月'],
  'series': [
    {
      'values': [3650, 5920, 4010],
    },
  ],
  'unit': '元',
});

/// Records what the view sends; [result] decides whether it got out.
class Outbox {
  final sent = <String>[];
  final resent = <String>[];
  Completer<bool>? gate;
  bool result = true;

  Future<bool> reply(String text) {
    sent.add(text);
    final g = gate;
    return g == null ? Future.value(result) : g.future;
  }

  Future<bool> resend(String text) async {
    resent.add(text);
    return result;
  }
}

Widget host(
  String source, {
  Outbox? outbox,
  DshUiState state = DshUiState.live,
  bool scope = true,
  bool streaming = false,
  bool closed = true,
}) {
  Widget block = DshUiBlock(source: source, streaming: streaming, closed: closed);
  if (scope) {
    block = DshUiScope(
      sessionId: 's',
      messageId: 'a1',
      state: state,
      onReply: outbox?.reply,
      onAskResend: outbox?.resend,
      child: block,
    );
  }
  return testApp(
    Scaffold(
      body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: block),
    ),
  );
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('an open visual card reuses its skeleton while the inferred shape stays the same', (tester) async {
    final source = ValueNotifier('{"type":"stack","title":"比较","children":[{"type":"metric","label":"');
    addTearDown(source.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: source,
            builder: (_, text, _) => DshUiBlock(source: text, streaming: true, closed: false),
          ),
        ),
      ),
    );
    final skeleton = find.byType(DshUiSkeleton);
    final first = tester.widget<DshUiSkeleton>(skeleton);
    source.value += '数量","value":10';
    await tester.pump();
    expect(tester.widget<DshUiSkeleton>(skeleton), same(first));
    source.value += '},{"type":"chart"';
    await tester.pump();
    final next = tester.widget<DshUiSkeleton>(skeleton);
    expect(next, isNot(same(first)));
    expect(next.shape.parts.length, 2);
  });

  testWidgets('dragging away cancels option press; busy send stays unscaled', (tester) async {
    final outbox = Outbox()..gate = Completer<bool>();
    await tester.pumpWidget(host(parts, outbox: outbox));
    final option = find.text('Node.js 22');
    final scales = find.ancestor(of: option, matching: find.byType(ScaleTransition));
    final gesture = await tester.startGesture(tester.getCenter(option));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.widget<ScaleTransition>(scales.first).scale.value, lessThan(1));
    await gesture.moveBy(const Offset(kTouchSlop + 4, 0));
    await pumpFrames(tester, 4);
    expect(tester.widget<ScaleTransition>(scales.first).scale.value, 1);
    await gesture.up();
    await tester.tap(option);
    await tester.pump();
    await tester.tap(find.text('发送'));
    await pumpFrames(tester, 4);
    final send = find.byType(FilledButton);
    final busy = await tester.startGesture(tester.getCenter(send));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    for (final scale in tester.widgetList<ScaleTransition>(
      find.ancestor(of: send, matching: find.byType(ScaleTransition)),
    )) {
      expect(scale.scale.value, 1);
    }
    await busy.up();
    outbox.gate!.complete(true);
    await tester.pump();
  });

  testWidgets('a single choice sends the visible label at once', (tester) async {
    final outbox = Outbox()..gate = Completer<bool>();
    await tester.pumpWidget(host(choose, outbox: outbox));
    await tester.tap(find.text('方案 B'));
    await tester.pump();
    expect(outbox.sent, ['[dsh-ui reply] 选一个方案\n选择：方案 B']);
    // Sending: a ring in the tapped row, and no second send.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('方案 A'));
    await tester.pump();
    expect(outbox.sent, hasLength(1));
    outbox.gate!.complete(true);
    await pumpFrames(tester, 4);
    // Shown as answered until the transcript catches up.
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byIcon(AppIcons.radioOn), findsOneWidget);
    await tester.tap(find.text('方案 A'));
    await tester.pump();
    expect(outbox.sent, hasLength(1));
  });

  testWidgets('a send that fails puts the view back', (tester) async {
    final outbox = Outbox()..result = false;
    await tester.pumpWidget(host(choose, outbox: outbox));
    await tester.tap(find.text('方案 A'));
    await pumpFrames(tester, 4);
    expect(find.byIcon(AppIcons.radioOn), findsNothing);
    outbox.result = true;
    await tester.tap(find.text('方案 A'));
    await pumpFrames(tester, 4);
    expect(outbox.sent, hasLength(2));
    expect(find.byIcon(AppIcons.radioOn), findsOneWidget);
  });

  testWidgets('multiple choice sends once, in option order', (tester) async {
    final outbox = Outbox();
    await tester.pumpWidget(host(parts, outbox: outbox));
    expect(find.text('可多选'), findsOneWidget);
    await tester.tap(find.text('Rust 工具链'));
    await tester.tap(find.text('Node.js 22'));
    await tester.pump();
    expect(outbox.sent, isEmpty);
    await tester.tap(find.text('发送'));
    await pumpFrames(tester, 4);
    expect(outbox.sent, ['[dsh-ui reply] 要装哪些组件\n选择：Node.js 22、Rust 工具链']);
  });

  testWidgets('confirm and cancel send their button text', (tester) async {
    final outbox = Outbox();
    await tester.pumpWidget(host(deploy, outbox: outbox));
    await tester.tap(find.text('再等等'));
    await pumpFrames(tester, 4);
    expect(outbox.sent, ['[dsh-ui reply]\n取消：再等等']);
    expect(find.byIcon(AppIcons.selected), findsOneWidget);

    final second = Outbox();
    await tester.pumpWidget(host('$deploy ', outbox: second));
    await tester.tap(find.text('开始部署'));
    await pumpFrames(tester, 4);
    expect(second.sent, ['[dsh-ui reply]\n确认：开始部署']);
  });

  testWidgets('while the turn runs, nothing can be picked', (tester) async {
    final outbox = Outbox();
    await tester.pumpWidget(host(choose, outbox: outbox, state: DshUiState.running));
    await tester.tap(find.text('方案 A'));
    await tester.pump();
    expect(outbox.sent, isEmpty);
    expect(find.text('回复结束后可选'), findsOneWidget);
  });

  testWidgets('answered views highlight the choice; others expire', (tester) async {
    final outbox = Outbox();
    final answered = DshUiState(DshUiInteraction.answered, reply: parseDshUiReply('[dsh-ui reply] 选一个方案\n选择：方案 B'));
    await tester.pumpWidget(host(choose, outbox: outbox, state: answered));
    expect(find.byIcon(AppIcons.radioOn), findsOneWidget);
    expect(find.text('已失效'), findsNothing);
    await tester.tap(find.text('方案 A'));
    expect(outbox.sent, isEmpty);

    // A reply to another card does not mark this one.
    final other = DshUiState(DshUiInteraction.answered, reply: parseDshUiReply('[dsh-ui reply] 别的卡\n选择：方案 B'));
    await tester.pumpWidget(host(choose, outbox: outbox, state: other));
    await pumpFrames(tester, 12);
    expect(find.byIcon(AppIcons.radioOn), findsNothing);
    expect(find.text('已失效'), findsOneWidget);

    await tester.pumpWidget(host(choose, outbox: outbox, state: DshUiState.expired));
    expect(find.text('已失效'), findsOneWidget);
  });

  testWidgets('without a scope the view is read-only', (tester) async {
    await tester.pumpWidget(host(choose, scope: false));
    await tester.tap(find.text('方案 A'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('已失效'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a broken view falls back to code with a resend button', (tester) async {
    final outbox = Outbox();
    await tester.pumpWidget(host('{"type":"chart",', outbox: outbox));
    expect(find.text('这个视图格式有误'), findsOneWidget);
    expect(find.text('json'), findsOneWidget);
    await tester.tap(find.text('让它重发'));
    await pumpFrames(tester, 4);
    expect(outbox.resent.single, startsWith('上一个 dsh-ui 视图无法显示：view：不是合法的 JSON'));
    expect(find.text('让它重发'), findsNothing, reason: 'asked once');

    await tester.pumpWidget(host('{"type":"nope"}', outbox: outbox, state: DshUiState.running));
    expect(find.text('这个视图格式有误'), findsOneWidget);
    expect(find.text('让它重发'), findsNothing);
    await tester.pumpWidget(host('{"type":"nope"}', scope: false));
    expect(find.text('让它重发'), findsNothing);
  });

  testWidgets('streaming shows a skeleton; an interrupted block falls back', (tester) async {
    final handle = tester.ensureSemantics();
    const partial = '{"type":"stack","title":"近 6 个月支出","children":[{"type":"chart"';
    await tester.pumpWidget(host(partial, outbox: Outbox(), streaming: true, closed: false));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.bySemanticsLabel(RegExp('正在生成视图')), findsOneWidget);
    expect(find.text('近 6 个月支出'), findsOneWidget);
    expect(find.text('这个视图格式有误'), findsNothing);

    await tester.pumpWidget(host(partial, outbox: Outbox(), closed: false));
    await pumpFrames(tester, 20);
    expect(find.text('视图没有生成完'), findsOneWidget);
    expect(find.text('让它重发'), findsNothing);
    handle.dispose();
  });

  testWidgets('the skeleton turns into the view when the fence closes', (tester) async {
    await tester.pumpWidget(host(choose.substring(0, 60), outbox: Outbox(), streaming: true, closed: false));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(host(choose, outbox: Outbox()));
    await pumpFrames(tester, 20);
    expect(find.text('方案 A'), findsOneWidget);
  });

  testWidgets('touching a chart shows the value', (tester) async {
    await tester.pumpWidget(host(spending, outbox: Outbox()));
    final chart = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_XYPainter');
    final box = tester.getRect(chart);
    await tester.tapAt(Offset(box.right - 20, box.center.dy));
    await tester.pump();
    expect(find.text('9月'), findsNWidgets(1));
    // Tap the middle bar: 8月.
    await tester.tapAt(box.center + const Offset(16, 0));
    await tester.pump();
    expect(find.textContaining('5,920', findRichText: true), findsOneWidget);
    // Tapping it again hides the tooltip.
    await tester.tapAt(box.center + const Offset(16, 0));
    await tester.pump();
    expect(find.textContaining('5,920', findRichText: true), findsNothing);
  });

  testWidgets('odd numbers draw without throwing', (tester) async {
    final odd = jsonEncode({
      'type': 'stack',
      'children': [
        {
          'type': 'chart',
          'categories': ['a', 'b', 'c'],
          'series': [
            {
              'values': [1e300, -1e300, 0],
            },
          ],
        },
        {
          'type': 'chart',
          'kind': 'line',
          'categories': ['a', 'b', 'c', 'd'],
          'series': [
            {
              'values': [null, 5, null, 5],
            },
            {
              'values': [0.000001, 0.000002, 0.000001, 0],
            },
          ],
        },
        {
          'type': 'chart',
          'kind': 'hbar',
          'categories': ['a', 'b'],
          'series': [
            {
              'values': [-40, 12],
            },
          ],
          'unit': '%',
        },
        {
          'type': 'chart',
          'kind': 'donut',
          'categories': ['a', 'b', 'c'],
          'series': [
            {
              'values': [0, -3, null],
            },
          ],
        },
        {
          'type': 'chart',
          'categories': [for (var i = 0; i < 60; i++) '很长很长的类别名字$i'],
          'series': [
            for (var s = 0; s < 6; s++)
              {
                'values': [for (var i = 0; i < 60; i++) i * s - 30],
              },
          ],
        },
      ],
    });
    await tester.pumpWidget(host(odd, outbox: Outbox()));
    await pumpFrames(tester, 4);
    expect(tester.takeException(), isNull);
    final charts = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_XYPainter');
    for (var i = 0; i < charts.evaluate().length; i++) {
      final box = tester.getRect(charts.at(i));
      await tester.tapAt(box.center);
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirm buttons are mirror images', (tester) async {
    await tester.pumpWidget(host(deploy, outbox: Outbox()));
    final cancel = tester.getRect(find.ancestor(of: find.text('再等等'), matching: find.byType(InkWell)));
    final go = tester.getRect(find.ancestor(of: find.text('开始部署'), matching: find.byType(InkWell)));
    final card = tester.getRect(find.byType(DshUiCard));
    expect(cancel.width, moreOrLessEquals(go.width));
    expect(cancel.height, 44);
    expect(go.left - cancel.right, 12);
    expect(cancel.left - card.left, 16);
    expect(card.right - go.right, 16);
  });

  testWidgets('option rows sit 16 in from the card on both sides', (tester) async {
    await tester.pumpWidget(host(choose, outbox: Outbox()));
    final card = tester.getRect(find.byType(DshUiCard));
    final row = tester.getRect(find.ancestor(of: find.text('方案 A'), matching: find.byType(InkWell)));
    expect(row.left - card.left, 16);
    expect(card.right - row.right, 16);
    expect(row.height, greaterThanOrEqualTo(48));
    final icon = tester.getRect(find.byIcon(AppIcons.radioOff).first);
    // The radio sits as far from the row's top as from its bottom.
    expect(icon.top - row.top, moreOrLessEquals(row.bottom - icon.bottom));
    expect(icon.left - row.left, 16);
  });
}
