// On iOS a tap on the status bar goes to the top of the conversation.

import 'package:dsh_app/ui/chat/chat_list.dart' show StatusBarTop;
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/whale_tail.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

void main() {
  setUpAll(() async {
    await loadTestFonts();
    await WhaleSprites.load();
  });

  Future<void> open(WidgetTester tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final harness = ChatHarness(session: 's1', states: {'s1': conversationState()});
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await pumpFrames(tester, 10);
  }

  /// The conversation's list: the vertical scroller with the most to scroll.
  ScrollPosition list(WidgetTester tester) {
    final positions = [
      for (final element in find.byType(Scrollable).evaluate())
        ((element as StatefulElement).state as ScrollableState).position,
    ].where((position) => position.axis == Axis.vertical).toList();
    positions.sort((a, b) => (b.maxScrollExtent - b.minScrollExtent).compareTo(a.maxScrollExtent - a.minScrollExtent));
    return positions.first;
  }

  testWidgets('goes to the first message', (tester) async {
    await open(tester);
    final before = list(tester);
    expect(before.pixels, closeTo(before.maxScrollExtent, 1), reason: 'opens at the latest message');
    expect(before.minScrollExtent, lessThan(0), reason: 'with earlier messages above');

    tester.simulateStatusBarTap();
    await pumpFrames(tester, 24);

    final after = list(tester);
    expect(after.pixels, closeTo(after.minScrollExtent, 1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android keeps its own controller', (tester) async {
    await open(tester);
    final scaffold = find.byType(Scaffold).evaluate().first;
    expect(PrimaryScrollController.maybeOf(scaffold), isNot(isA<StatusBarTop>()));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
