// 「选择消息」: a tap picks one message; a long press picks the stretch from
// the nearest picked message, and sliding stretches it; picked neighbours
// are joined by a rail; a pictures-only prompt reads as one. Goldens of the
// picker in light and dark.
//
//   flutter test --update-goldens test/share/share_picker_test.dart

import 'dart:collection';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/share/share_content.dart';
import 'package:dsh_app/ui/share/share_picker.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../chat/support/harness.dart';

class _ReadCountingItems extends ListBase<ChatItem> {
  _ReadCountingItems(this.items);

  final List<ChatItem> items;
  int reads = 0;

  @override
  int get length => items.length;
  @override
  set length(int value) => throw UnsupportedError('read-only');
  @override
  ChatItem operator [](int index) {
    reads++;
    return items[index];
  }

  @override
  void operator []=(int index, ChatItem value) => throw UnsupportedError('read-only');
}

/// Six exchanges, the third prompt a picture only.
List<ChatItem> _items() {
  final t = DateTime(2026, 10, 25);
  return shareableItems([
    for (var i = 0; i < 6; i++) ...[
      UserChatItem(
        seq: i * 10 + 1,
        time: t,
        text: i == 2 ? '' : '第 ${i + 1} 个问题：帮我看看这一步',
        images: i == 2 ? const [ImageAttachment(attachmentId: 'x', mediaType: 'image/png')] : const [],
        files: const [],
      ),
      AssistantChatItem(id: 'a$i', seq: i * 10 + 5, text: '第 ${i + 1} 个回答：这样改就好。', reasoning: ''),
    ],
  ]);
}

Future<Set<String>?> Function() _open(
  WidgetTester tester, {
  Set<String> selected = const {},
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) {
  Set<String>? result;
  var done = false;
  return () async {
    await tester.runAsync(loadTestFonts);
    usePhoneView(tester);
    final items = _items();
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: GestureDetector(
                  key: const ValueKey('open'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () async {
                    result = await showMessagePicker(context, items: items, selected: selected);
                    done = true;
                  },
                  child: const SizedBox.square(dimension: 48),
                ),
              ),
            ),
          ),
        ),
        brightness: brightness,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    return done ? result : null;
  };
}

Set<String> _picked(WidgetTester tester) => {
  for (final row in tester.widgetList<MessagePickRow>(find.byType(MessagePickRow)))
    if (row.picked) row.item.key,
};

void main() {
  testWidgets('a tap picks one; a long press picks the stretch from the nearest picked', (tester) async {
    await _open(tester, selected: {'u1'})();
    await tester.tap(find.text('第 2 个回答：这样改就好。'));
    await tester.pumpAndSettle();
    expect(_picked(tester), {'u1', 'a1'});

    // Long-press the third answer: everything from the second answer to it.
    await tester.longPress(find.text('第 3 个回答：这样改就好。'));
    await tester.pumpAndSettle();
    expect(_picked(tester), {'u1', 'a1', 'u21', 'a2'});
    expect(find.text('完成（4）'), findsOneWidget);
  });

  testWidgets('long-press and slide stretches the pick over the rows passed', (tester) async {
    await _open(tester)();
    final start = tester.getCenter(find.text('第 1 个问题：帮我看看这一步'));
    final gesture = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    expect(_picked(tester), {'u1'}, reason: 'nothing picked yet: the stretch starts where it was pressed');
    await gesture.moveTo(tester.getCenter(find.text('第 2 个回答：这样改就好。')));
    await tester.pump();
    expect(_picked(tester), {'u1', 'a0', 'u11', 'a1'});
    // Back up a row: the stretch shrinks with the finger.
    await gesture.moveTo(tester.getCenter(find.text('第 2 个问题：帮我看看这一步')));
    await tester.pump();
    expect(_picked(tester), {'u1', 'a0', 'u11'});
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('完成（3）'), findsOneWidget);
  });

  testWidgets('a drag near the last message visits mounted rows only', (tester) async {
    usePhoneView(tester);
    final items = _ReadCountingItems([
      for (var i = 0; i < 1000; i++) AssistantChatItem(id: 'a$i', text: 'Reply $i', reasoning: ''),
    ]);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: MessagePicker(items: items, selected: const {'a999'}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final visible = find.byType(MessagePickRow).hitTestable();
    final middle = visible.at(visible.evaluate().length ~/ 2);
    final row = tester.widget<MessagePickRow>(middle);
    expect(int.parse(row.item.key.substring(1)), greaterThan(500));
    final gesture = await tester.startGesture(tester.getCenter(middle));
    await tester.pump(const Duration(milliseconds: 600));
    items.reads = 0;
    await gesture.moveBy(const Offset(0, 5));
    expect(items.reads, inInclusiveRange(1, 99));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a row\'s line follows its pictures and the language', (tester) async {
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    final images = <ImageAttachment>[];
    final prompt = UserChatItem(seq: 1, time: DateTime(2026), text: '帮我调一下', images: images, files: const []);
    Future<void> show() => tester.pumpWidget(
      testApp(
        Scaffold(
          body: MessagePicker(items: [prompt], selected: const {}),
        ),
      ),
    );

    await show();
    expect(find.text('帮我调一下'), findsOneWidget);
    images.add(const ImageAttachment(attachmentId: 'x', mediaType: 'image/png'));
    await tester.tap(find.byType(MessagePickRow));
    await tester.pump();
    expect(find.text('〔图片〕 帮我调一下'), findsOneWidget);
    AppLocale.use(AppLocale.en);
    await show();
    expect(find.text('[Image] 帮我调一下'), findsOneWidget);
  });

  testWidgets('picked neighbours share a rail through their checks', (tester) async {
    await _open(tester, selected: {'u1', 'a0', 'a1'})();
    MessagePickRow row(String key) =>
        tester.widgetList<MessagePickRow>(find.byType(MessagePickRow)).firstWhere((r) => r.item.key == key);
    expect(row('u1').joinAbove, isFalse);
    expect(row('u1').joinBelow, isTrue);
    expect(row('a0').joinAbove, isTrue);
    expect(row('a0').joinBelow, isFalse, reason: 'the next one is not picked');
    expect(row('a1').joinAbove, isFalse);

    // The rail runs from the bottom of one check to the top of the next, centred on both.
    final dots = find.byKey(const ValueKey('pick-dot'));
    final first = tester.getRect(dots.at(0));
    final second = tester.getRect(dots.at(1));
    final below = tester.getRect(find.byKey(const ValueKey('pick-rail-below')).at(0));
    final above = tester.getRect(find.byKey(const ValueKey('pick-rail-above')).at(1));
    expect(below.top, closeTo(first.bottom, 0.01));
    expect(above.bottom, closeTo(second.top, 0.01));
    expect(below.bottom, closeTo(above.top, 0.01), reason: 'no gap between the rows');
    expect(below.center.dx, closeTo(first.center.dx, 0.01));
    expect(below.width, MessagePickRow.rail);
  });

  testWidgets('a pictures-only prompt reads as one', (tester) async {
    await _open(tester)();
    expect(find.text('〔图片〕'), findsOneWidget);
    expect(
      MessagePickRow.preview(
        UserChatItem(
          seq: 1,
          time: DateTime(2026),
          text: '帮我调一下',
          images: const [
            ImageAttachment(attachmentId: 'a', mediaType: 'image/png'),
            ImageAttachment(attachmentId: 'b', mediaType: 'image/png'),
          ],
          files: const [],
        ),
      ),
      '〔2 张图片〕 帮我调一下',
    );
  });

  testWidgets('at 130 % text the rows grow instead of clipping', (tester) async {
    await _open(tester, textScale: 1.3)();
    expect(tester.takeException(), isNull);
    final row = tester.getRect(find.byType(MessagePickRow).first);
    final dot = tester.getRect(find.byKey(const ValueKey('pick-dot')).first);
    expect(row.height, greaterThanOrEqualTo(MessagePickRow.minHeight));
    expect(dot.center.dy, closeTo(row.center.dy, 0.5), reason: 'the check stays centred on its row');
  });

  for (final brightness in Brightness.values) {
    final mode = brightness == Brightness.dark ? 'dark' : 'light';
    testWidgets('picker golden ($mode)', (tester) async {
      await _open(tester, selected: {'u11', 'a1', 'u21', 'a2'}, brightness: brightness)();
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/picker_$mode.png'));
    });
  }

  test('the long image needs no more than a stretch of exchanges', () {
    final state = ChatState(items: _items(), title: '对话', loading: false);
    final content = shareContentForItems(state, {'u11', 'a1', 'u21', 'a2'});
    expect(content.blocks.map((b) => b.runtimeType), [ShareQuestion, ShareAnswer, ShareQuestion, ShareAnswer]);
    expect((content.blocks[2] as ShareQuestion).images, hasLength(1));
  });
}
