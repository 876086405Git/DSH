import 'package:dsh_app/companion/companion_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('assist page text is a separate block for the submitted turn', () {
    const history = [(role: 'assistant', text: 'Hello'), (role: 'user', text: 'When does this train arrive?')];
    final messages = companionRequestMessages(history, assistantPage: 'Train arrives at 9:30');
    expect(messages.first['content'], 'Hello');
    final blocks = messages.last['content'] as List<Map<String, String>>;
    expect(blocks.first['text'], 'When does this train arrive?');
    expect(blocks.last['text'], contains('"Train arrives at 9:30"'));
    expect(companionRequestMessages(history).last['content'], 'When does this train arrive?');
  });

  test('a full backlog keeps the newest eight, oldest first', () {
    final now = DateTime.utc(2026, 11, 8, 12);
    final events = [
      for (var i = 0; i < 10; i++)
        CompanionContextEvent(
          id: 'e$i',
          kind: 'pet',
          at: now.subtract(Duration(minutes: 10 - i)),
          detail: 'touch $i',
        ),
    ];
    final kept = companionRecentEvents(events, now: now);
    expect(kept.map((e) => e.id), ['e2', 'e3', 'e4', 'e5', 'e6', 'e7', 'e8', 'e9']);
  });
}
