import 'package:dsh_app/companion/companion_reply.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCompanionReply', () {
    test('takes marks out of the words, in order', () {
      const raw = '[表情:开心]今天不错。[动作:点头]你呢？';
      final reply = parseCompanionReply(raw);
      expect(reply.words, '今天不错。你呢？');
      expect(reply.marks, const [
        CompanionMark(CompanionMarkKind.emotion, 'happy'),
        CompanionMark(CompanionMarkKind.action, 'nod'),
      ]);
      final boundary = raw.indexOf('[动作');
      expect(reply.wordRangesFrom(0, boundary), [(start: 0, end: 5)]);
      expect(reply.wordRangesFrom(boundary, raw.length), [(start: 5, end: 8)]);
      expect(reply.wordRangesFrom(0, raw.indexOf('今天')), isEmpty);

      // The complete bubble parser, not an independent parse of each source,
      // decides whether a mark crossing a source boundary contributes words.
      const first = '[表情:';
      const second = '开心]  嗯🙂\t ';
      const third = '[动作:点头]\n好了。';
      const combined = '$first\n$second\n$third';
      final joined = parseCompanionReply(combined);
      expect(joined.words, '嗯🙂 \n\n好了。');
      expect(joined.marks, reply.marks);
      expect(joined.wordRangesFrom(0, first.length), isEmpty);
      final secondStart = first.length + 1;
      expect(joined.wordRangesFrom(secondStart, secondStart + second.length), [(start: 0, end: '嗯🙂'.length)]);
      final thirdStart = secondStart + second.length + 1;
      expect(joined.wordRangesFrom(thirdStart, combined.length), [
        (start: joined.words.indexOf('好了。'), end: joined.words.length),
      ]);
    });

    test('takes the variants models actually write', () {
      expect(parseCompanionReply('【表情：害羞】嗯').marks.single.name, 'shy');
      expect(parseCompanionReply('[表情: 难过 ]嗯').marks.single.name, 'sad');
      expect(parseCompanionReply('[emotion:Happy] hi').marks.single.name, 'happy');
      expect(parseCompanionReply('[ACTION:wave] hi').marks.single.name, 'wave');
    });

    test('an unknown name still disappears from the words', () {
      const raw = '[表情:翻白眼]算了。';
      final reply = parseCompanionReply(raw);
      expect(reply.words, '算了。');
      expect(reply.marks, isEmpty);
      expect(reply.wordRangesFrom(0, raw.indexOf('算了')), isEmpty);
      expect(reply.wordRangesFrom(raw.indexOf('算了'), raw.length), [(start: 0, end: 3)]);
      const blank = '[表情:开心]\n \t ';
      expect(parseCompanionReply(blank).wordRangesFrom(0, blank.length), isEmpty);
      expect(parseCompanionReply('').wordRangesFrom(0, 0), isEmpty);
    });

    test('leaves brackets that are not marks alone', () {
      expect(parseCompanionReply('看 [这里] 和 [1:2]').words, '看 [这里] 和 [1:2]');
      expect(parseCompanionReply('数组 a[0]').words, '数组 a[0]');
    });

    test('holds back a mark still arriving, only while streaming', () {
      for (final partial in ['你好[', '你好[表', '你好[表情', '你好[表情:', '你好[表情:开', '你好【动作：点', '你好[emot']) {
        final reply = parseCompanionReply(partial, streaming: true);
        expect(reply.words, '你好', reason: partial);
        expect(reply.wordRangesFrom(0, 2), [(start: 0, end: 2)], reason: partial);
        expect(reply.wordRangesFrom(2, partial.length), isEmpty, reason: partial);
      }
      expect(parseCompanionReply('你好[表情:开', streaming: false).words, '你好[表情:开');
      // Not the start of a mark: shown straight away.
      expect(parseCompanionReply('看 [这', streaming: true).words, '看 [这');
    });

    test('streamed words, moves and source ranges agree at every saved frame', () {
      final actions = {'拍拍': 'TapBody'};
      final stream = CompanionReplyStream(actions: actions);
      final snapshots = <({String raw, bool streaming, CompanionReply reply})>[];
      var raw = '';
      void capture(bool streaming) {
        snapshots.add((raw: raw, streaming: streaming, reply: stream.read(raw, streaming: streaming)));
      }

      for (final piece in [
        '甲',
        ' [动作:点头]',
        '乙',
        '[表',
        '[动作:拍拍]',
        '情:',
        '未',
        '】',
        '【EmOtIoN',
        ' ' * 80,
        '：',
        'Happy',
        '\t' * 80,
        ']',
        '  ',
        '丙\t',
        '丁\n',
        '[动作:',
        '\n',
        '拍拍】',
        String.fromCharCode(0xd83d),
        String.fromCharCode(0xde42),
        '【动',
      ]) {
        raw += piece;
        capture(true);
      }
      capture(false);
      capture(true);

      // Frame acknowledgements can outlive the notification that created them.
      for (final snapshot in snapshots) {
        final expected = parseCompanionReply(snapshot.raw, streaming: snapshot.streaming, actions: actions);
        expect(snapshot.reply.words, expected.words);
        expect(snapshot.reply.marks, expected.marks);
        for (var i = 0; i < snapshot.raw.length; i++) {
          expect(snapshot.reply.wordRangesFrom(i, i + 1), expected.wordRangesFrom(i, i + 1));
        }
      }
    });

    test('the same text gives the same marks on every streaming update', () {
      const text = '[表情:开心]你好呀[动作:挥手]，今天';
      final seen = <CompanionMark>[];
      for (var i = 1; i <= text.length; i++) {
        final reply = parseCompanionReply(text.substring(0, i), streaming: true);
        expect(reply.words, isNot(contains('[')), reason: text.substring(0, i));
        seen
          ..clear()
          ..addAll(reply.marks);
      }
      expect(seen.map((m) => m.name), ['happy', 'wave']);
    });
  });

  group('companionAside', () {
    test('says the time and what just happened', () {
      expect(
        companionAside(now: DateTime(2026, 11, 6, 9, 5), notes: const ['对方刚才摸了摸你的头']),
        '〔11月6日 周五 09:05，对方刚才摸了摸你的头〕',
      );
    });

    test('nothing to say, no aside', () {
      expect(companionAside(), isNull);
    });
  });

  group('companionSaidText', () {
    final aside = companionAside(now: DateTime(2026, 11, 8, 13, 20), notes: const ['对方刚才摸了摸你的头'])!;

    test('what the person typed, without what the page put in front', () {
      expect(companionSaidText('$aside\n今天好累'), '今天好累');
      expect(
        companionSaidText(
          ['（你现在的名字是「小鲸」，是对方给你起的。自称时用这个名字。）', '（对方给你改了设定。从现在起按下面这份来：\n多说点话）', aside, '第一行\n第二行'].join('\n'),
        ),
        '第一行\n第二行',
      );
    });

    test('a message without an aside is all theirs, brackets and all', () {
      expect(companionSaidText('〔笑〕早上好'), '〔笑〕早上好');
      expect(companionSaidText('（小声）在吗'), '（小声）在吗');
    });
  });

  group('companionGreeting', () {
    final evening = DateTime(2026, 11, 6, 21);

    test('first time', () {
      expect(companionGreeting(evening, null), CompanionGreeting.firstTime);
    });

    test('just left', () {
      expect(companionGreeting(evening, evening.subtract(const Duration(minutes: 5))), CompanionGreeting.justNow);
    });

    test('follows the clock', () {
      final before = DateTime(2026, 11, 5, 21);
      expect(companionGreeting(DateTime(2026, 11, 6, 8), before), CompanionGreeting.morning);
      expect(companionGreeting(DateTime(2026, 11, 6, 12), before), CompanionGreeting.noon);
      expect(companionGreeting(DateTime(2026, 11, 6, 15), before), CompanionGreeting.afternoon);
      expect(companionGreeting(evening, before), CompanionGreeting.evening);
      expect(companionGreeting(DateTime(2026, 11, 6, 2), before), CompanionGreeting.lateNight);
      expect(companionGreeting(DateTime(2026, 11, 6, 23, 30), before), CompanionGreeting.lateNight);
    });

    test('a long time away is news, whatever the hour', () {
      expect(companionGreeting(evening, evening.subtract(const Duration(days: 4))), CompanionGreeting.longAbsence);
    });
  });

  test('a note with a line break keeps the aside on one line', () {
    final aside = companionAside(now: DateTime(2026, 11, 8, 9, 0), notes: const ['「整理\n照片」那边跑完了'])!;
    expect(aside, isNot(contains('\n')));
    expect(companionSaidText('$aside\n在吗'), '在吗');
  });
}
