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

  test('her line about the screen is a valid event, on one line and within bounds', () {
    final now = DateTime.utc(2026, 11, 8, 12);
    final note = companionScreenNote('又在刷\n短视频\t呀', app: 'tv.danmaku.bili', scene: 'video');
    expect(note, '你看着对方的屏幕（tv.danmaku.bili，video）主动说了：「又在刷 短视频 呀」');
    expect(companionScreenNote('早点睡'), '你看着对方的屏幕主动说了：「早点睡」');
    final long = companionScreenNote('话' * 400, app: 'example.app');
    expect(long.runes, hasLength(160));
    expect(long, endsWith('…」'));
    for (final detail in [note, long]) {
      expect(CompanionContextEvent(id: 's', kind: 'screen', at: now, detail: detail).toJson()['detail'], detail);
    }
  });
}
