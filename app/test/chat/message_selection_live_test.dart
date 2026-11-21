// A message still being written selects like a finished one (long-press,
// double tap), though what streams in reaches the selection only once a
// finger comes down on it or the writing stops: each delta would otherwise
// make the region sort the whole reply's pieces again.

import 'package:dsh_app/ui/chat/widgets/message_selection.dart';
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _words = 'alpha beta gamma';

Widget _message(String text, {required bool live}) => testApp(
  Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: MessageSelection(
        text: text,
        live: live,
        onMore: () {},
        child: Text(text, key: const ValueKey('text')),
      ),
    ),
  ),
);

List<String> _clipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
    return null;
  });
  return copied;
}

/// A reply being written: it grows over a few deltas, nobody touching it.
Future<void> _stream(WidgetTester tester) async {
  for (final text in ['alpha', 'alpha beta', _words]) {
    await tester.pumpWidget(_message(text, live: true));
    await tester.pump(const Duration(milliseconds: 32));
  }
}

/// Everything the region would select and copy now (its select-all and
/// copy shortcuts).
Future<void> _copyAll(WidgetTester tester) async {
  final inside = tester.element(find.byKey(const ValueKey('text')));
  Actions.invoke(inside, const SelectAllTextIntent(SelectionChangedCause.keyboard));
  await tester.pump();
  Actions.invoke(inside, CopySelectionTextIntent.copy);
  await tester.pump();
}

/// A finger held down, frames coming at the display's pace as on a phone
/// (`tester.longPress` jumps the clock past the long-press in one frame).
Future<void> _hold(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(at);
  for (var held = Duration.zero; held < kLongPressTimeout * 1.2; held += const Duration(milliseconds: 16)) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
}

Future<void> _copyFromToolbar(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '复制'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('a long-press on a reply being written selects the word under the finger', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    await _hold(tester, tester.getCenter(find.byKey(const ValueKey('text'))));
    await _copyFromToolbar(tester);
    expect(copied, ['beta']);
  });

  testWidgets('so does a double tap', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    final at = tester.getCenter(find.byKey(const ValueKey('text')));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(at);
    await _copyFromToolbar(tester);
    expect(copied, ['beta']);
  });

  testWidgets('what streams in reaches the selection once a finger comes down', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    await _copyAll(tester);
    expect(copied, isEmpty, reason: 'nobody has touched it: the deltas were held back');

    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const ValueKey('text'))));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 400));
    await _copyAll(tester);
    expect(copied, [_words]);

    // From then on, what streams in goes straight through.
    await tester.pumpWidget(_message('$_words delta', live: true));
    await tester.pump();
    await _copyAll(tester);
    expect(copied.last, '$_words delta');
  });

  testWidgets('or once the writing stops', (tester) async {
    final copied = _clipboard(tester);
    await _stream(tester);
    await tester.pumpWidget(_message(_words, live: false));
    await tester.pump();
    await _copyAll(tester);
    expect(copied, [_words]);
  });

  testWidgets('a finished message is selectable from the start', (tester) async {
    final copied = _clipboard(tester);
    await tester.pumpWidget(_message(_words, live: false));
    await tester.pump();
    await _copyAll(tester);
    expect(copied, [_words]);
  });
}
