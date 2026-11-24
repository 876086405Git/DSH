// Code streaming into a reply's code block is highlighted again at most every
// 250 ms; what came since shows plain until then, and the end result is the
// whole block highlighted.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Iterable<TextSpan> _leaves(InlineSpan span) sync* {
  if (span is! TextSpan) return;
  if (span.text != null) yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    yield* _leaves(child);
  }
}

void main() {
  setUpAll(loadTestFonts);

  testWidgets('the copy label stays built while code grows and still gives tap feedback', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final code = ValueNotifier('a');
    addTearDown(code.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: code,
            builder: (_, text, _) => CodeBlock(code: text, language: 'text', replyActions: true),
          ),
        ),
      ),
    );
    final label = find.text(appL10n.commonCopy);
    final first = tester.widget<Text>(label);
    code.value += 'b';
    await tester.pump();
    expect(tester.widget<Text>(label), same(first));

    await tester.tap(label);
    await tester.pumpAndSettle();
    expect(copied, 'ab');
    expect(find.text(appL10n.commonCopied), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    expect(label, findsOneWidget);
  });

  testWidgets('diff rows stay put when a syntax highlight would have cooled down', (tester) async {
    final code = ValueNotifier(('-old', false));
    addTearDown(code.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<(String, bool)>(
            valueListenable: code,
            builder: (_, value, _) => CodeBlock(code: value.$1, language: 'patch', showLineNumbers: value.$2),
          ),
        ),
      ),
    );
    code.value = ('-old\n+new', false);
    await tester.pump();
    code.value = ('-old\n+new\n+more', false);
    await tester.pump(const Duration(milliseconds: 32));
    final row = tester.widget<Text>(find.text('+more'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<Text>(find.text('+more')), same(row));

    code.value = (code.value.$1, true);
    await tester.pump();
    expect(find.text(code.value.$1, findRichText: true), findsOneWidget);
  });

  testWidgets('streaming code is highlighted at most every 250 ms, and whole at the end', (tester) async {
    final code = ValueNotifier('final a = 1;\n');
    addTearDown(code.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: code,
            builder: (_, value, _) => CodeBlock(code: value, language: 'dart', replyActions: true),
          ),
        ),
      ),
    );
    List<TextSpan> leaves() => _leaves(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byType(CodeBlock),
              matching: find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
            ),
          )
          .textSpan!,
    ).toList();
    int keywords() => leaves().where((leaf) => leaf.text == 'final' && leaf.style?.color != null).length;
    expect(keywords(), 1);

    // The first growth is highlighted at once.
    code.value += 'final b = 2;\n';
    await tester.pump();
    expect(keywords(), 2);

    // More within 250 ms: drawn, plain, after what was highlighted.
    code.value += 'final c = 3;\n';
    await tester.pump(const Duration(milliseconds: 32));
    code.value += 'final d = 4;';
    await tester.pump(const Duration(milliseconds: 32));
    expect(keywords(), 2);
    // The block drops the code's last newline, so the plain tail starts with it.
    expect(leaves().last.text, '\nfinal c = 3;\nfinal d = 4;');
    expect(leaves().map((leaf) => leaf.text).join(), code.value.trimRight());

    // Then the rest is highlighted, with no more input.
    await tester.pump(const Duration(milliseconds: 250));
    expect(keywords(), 4);
    expect(leaves().map((leaf) => leaf.text).join(), code.value.trimRight());
    expect(tester.takeException(), isNull);
  });

  testWidgets('code that goes back to what was highlighted drops the plain tail', (tester) async {
    final code = ValueNotifier('final a = 1;\n');
    addTearDown(code.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: code,
            builder: (_, value, _) => CodeBlock(code: value, language: 'dart', replyActions: true),
          ),
        ),
      ),
    );
    List<TextSpan> leaves() => _leaves(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byType(CodeBlock),
              matching: find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
            ),
          )
          .textSpan!,
    ).toList();
    int keywords() => leaves().where((leaf) => leaf.text == 'final' && leaf.style?.color != null).length;

    code.value += 'final b = 2;\n';
    await tester.pump();
    final highlighted = code.value;
    expect(keywords(), 2);

    // Within the cooldown more arrives: plain tail.
    code.value += 'final c = 3;';
    await tester.pump(const Duration(milliseconds: 32));
    expect(leaves().last.text, '\nfinal c = 3;');

    // Then the code is exactly what was highlighted again (a resync).
    code.value = highlighted;
    await tester.pump(const Duration(milliseconds: 32));
    expect(leaves().map((leaf) => leaf.text).join(), highlighted.trimRight());
    expect(keywords(), 2);
    await tester.pump(const Duration(milliseconds: 300));
    expect(leaves().map((leaf) => leaf.text).join(), highlighted.trimRight());
    expect(keywords(), 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('code that changes rather than grows is highlighted at once', (tester) async {
    final code = ValueNotifier('final a = 1;\n');
    addTearDown(code.dispose);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ValueListenableBuilder<String>(
            valueListenable: code,
            builder: (_, value, _) => CodeBlock(code: value, language: 'dart'),
          ),
        ),
      ),
    );
    code.value += 'final b = 2;\n';
    await tester.pump();
    code.value = 'final x = 9;\nfinal y = 8;';
    await tester.pump(const Duration(milliseconds: 16));
    final leaves = _leaves(
      tester
          .widget<Text>(
            find.descendant(
              of: find.byType(CodeBlock),
              matching: find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
            ),
          )
          .textSpan!,
    ).toList();
    expect(leaves.where((leaf) => leaf.text == 'final' && leaf.style?.color != null), hasLength(2));
    await tester.pump(const Duration(milliseconds: 300));
  });
}
