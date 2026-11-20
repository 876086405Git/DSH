// 长按自己发的消息可以「引用」，只引正文；引用条和气泡一样遮住密钥。

import 'package:dsh_app/ui/chat/widgets/quote_chip.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

const _sk = 'sk-4c1f0e7b9a2d4e6f8a1b3c5d7e9fa3f9';

void main() {
  testWidgets('quoting your own message quotes its words, not the quote it opened with', (tester) async {
    usePhoneView(tester);
    final quoted = <String>[];
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: UserBubble(text: '> 旧的引文\n\n我的问题', onQuote: quoted.add),
          ),
        ),
      ),
    );
    await tester.longPress(find.text('我的问题'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextSelectionToolbarTextButton, '更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用'));
    await tester.pumpAndSettle();
    expect(quoted, ['我的问题']);
  });

  testWidgets('the quote chip masks a credential', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Center(
            child: QuoteChip(quote: 'key $_sk', onRemove: () {}),
          ),
        ),
      ),
    );
    expect(find.textContaining(_sk), findsNothing);
  });
}
