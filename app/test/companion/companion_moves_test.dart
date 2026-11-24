import 'package:dsh_app/companion/companion_moves.dart';
import 'package:dsh_app/companion/companion_reply.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Names the way her own model (and others like it) ships them.
const _info = CompanionModelInfo(
  expressions: ['04 脸红', '03 脸黑', '05 》《', '11 尾巴消失', '13 水印消除', '01 口型切换', '02 3嘴'],
  motions: ['Idle_1', 'TapBody', 'Wave'],
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a readable name: no folder, no extension, no numbering', () {
    expect(companionMoveLabel('04 脸红'), '脸红');
    expect(companionMoveLabel('expressions/F01.exp3.json'), 'F01');
    expect(companionMoveLabel('motions/02_tap_body.motion3.json'), 'tap_body');
    expect(companionMoveLabel('TapBody'), 'TapBody');
    // Nothing left after the numbering: keep what there was.
    expect(companionMoveLabel('07'), '07');
  });

  test('what the stage reports, with anything odd left out', () {
    final info = CompanionModelInfo.fromMessage({
      'expressions': ['04 脸红', 3, '', null],
      'motions': 'Wave',
    });
    expect(info.expressions, ['04 脸红']);
    expect(info.motions, isEmpty);
  });

  group('offered to the AI by default', () {
    final moves = CompanionMoves.from(_info, const {});
    bool ai(String raw) => [...moves.expressions, ...moves.motions].firstWhere((m) => m.raw == raw).ai;

    test('feelings and gestures, not parts switched on and off, idles or glyphs', () {
      expect(ai('03 脸黑'), isTrue);
      expect(ai('TapBody'), isTrue);
      expect(ai('11 尾巴消失'), isFalse);
      expect(ai('13 水印消除'), isFalse);
      expect(ai('01 口型切换'), isFalse);
      expect(ai('Idle_1'), isFalse);
      expect(ai('05 》《'), isFalse);
      expect(ai('02 3嘴'), isFalse);
    });

    test('a name one of her own marks answers to stays hers', () {
      // 脸红 and Wave are allowed, but her 脸红 and 挥手 carry her pose too.
      expect(ai('04 脸红'), isTrue);
      expect(moves.emotionLabels, {'脸黑': '03 脸黑'});
      expect(moves.actionLabels, {'TapBody': 'TapBody'});
      final rules = moves.rules()!;
      expect(rules, contains('[表情:脸黑]'));
      expect(rules, contains('[动作:TapBody]'));
      expect(rules, isNot(contains('脸红')));
      expect(rules, isNot(contains('Wave')));
      expect(rules, isNot(contains('尾巴')));
    });
  });

  test('what the person changed wins, and survives a round trip', () {
    final saved = {
      'e:04 脸红': {'label': '红脸蛋', 'ai': true},
      'm:TapBody': {'ai': false},
      'e:05 》《': {'label': '  ', 'ai': true},
    };
    final moves = CompanionMoves.from(_info, saved);
    expect(moves.emotionLabels, {'红脸蛋': '04 脸红', '脸黑': '03 脸黑', '》《': '05 》《'});
    expect(moves.actionLabels, isEmpty);
    expect(moves.rules(), isNot(contains('[动作:')));

    final again = CompanionMoves.from(_info, moves.toJson());
    expect(again.emotionLabels, moves.emotionLabels);
    expect(again.fingerprint, moves.fingerprint);
  });

  test('a change tells the AI again; nothing offered says nothing', () {
    final moves = CompanionMoves.from(_info, const {});
    final tap = moves.motions.firstWhere((m) => m.raw == 'TapBody');
    final quieter = moves.replaced(tap.copyWith(ai: false));
    expect(quieter.fingerprint, isNot(moves.fingerprint));
    expect(quieter.motions.firstWhere((m) => m.raw == 'TapBody').ai, isFalse);
    expect(const CompanionMoves().rules(), isNull);
    expect(CompanionMoves.from(const CompanionModelInfo(expressions: ['11 尾巴消失']), const {}).rules(), isNull);
  });

  test('kept per character, whatever its name', () async {
    final moves = CompanionMoves.from(_info, const {});
    final renamed = moves.replaced(moves.motions.firstWhere((m) => m.raw == 'TapBody').copyWith(label: '拍拍'));
    await companionMovesSave('鲸鱼娘 / 2', renamed);
    final back = CompanionMoves.from(_info, await companionMovesSaved('鲸鱼娘 / 2'));
    expect(back.actionLabels, {'拍拍': 'TapBody'});
    expect(await companionMovesSaved('别人'), isEmpty);
  });

  test('the AI writes the labels; the stage gets the raw names', () {
    final reply = parseCompanionReply(
      '[表情:脸黑]哼。[动作:拍拍][表情:脸红]',
      emotions: const {'脸黑': '03 脸黑', '脸红': '04 脸红'},
      actions: const {'拍拍': 'TapBody'},
    );
    expect(reply.words, '哼。');
    expect(reply.marks, const [
      // The model's own, marked as such so the stage plays exactly those.
      CompanionMark(CompanionMarkKind.emotion, '03 脸黑', native: true),
      CompanionMark(CompanionMarkKind.action, 'TapBody', native: true),
      // Hers, not the model's.
      CompanionMark(CompanionMarkKind.emotion, 'shy'),
    ]);
    expect(companionMarkKnown(CompanionMarkKind.action, 'Wave'), isTrue);
    expect(companionMarkKnown(CompanionMarkKind.action, 'TapBody'), isFalse);
  });

  test('her persona lists them after her own marks', () {
    final rules = CompanionMoves.from(_info, const {}).rules();
    final persona = companionPersona(moves: rules);
    expect(persona.indexOf('[动作:TapBody]'), greaterThan(persona.indexOf('[表情:开心]')));
    expect(persona, contains('用不上工具'));
    expect(persona.indexOf('用不上工具'), greaterThan(persona.indexOf('[动作:TapBody]')));
    final withTools = companionPersona(moves: rules, tools: true);
    expect(withTools, isNot(contains('用不上工具')));
    expect(withTools.indexOf('直接用手上的工具'), greaterThan(withTools.indexOf('[动作:TapBody]')));
    expect(companionPersona(moves: '  '), companionPersonaCore);
  });

  test('two moves of a kind never answer to one label, renamed or not', () {
    final moves = CompanionMoves.from(
      const CompanionModelInfo(expressions: ['01 星星眼.exp3.json', '02 星星眼.exp3.json', '转圈圈']),
      const {},
    );
    expect(moves.expressions.map((m) => m.label), ['星星眼', '星星眼 2', '转圈圈']);
    expect(moves.emotionLabels, {'星星眼': '01 星星眼.exp3.json', '星星眼 2': '02 星星眼.exp3.json', '转圈圈': '转圈圈'});
    final renamed = moves.replaced(moves.expressions.last.copyWith(label: '星星眼'));
    expect(renamed.expressions.last.label, '星星眼 3');
  });

  test('the AI may write exactly what it was told: the first 24, labels a mark can carry', () {
    final many = [for (var i = 0; i < 30; i++) '表情$i号'];
    final moves = CompanionMoves.from(
      CompanionModelInfo(expressions: [...many, '一个非常非常非常非常非常非常非常非常非常非常非常非常非常非常非常长的名字啊啊啊啊']),
      const {},
    );
    expect(moves.emotionLabels.keys, hasLength(CompanionMoves.most));
    expect(moves.emotionLabels.keys, isNot(contains('表情29号')));
    expect(moves.rules(), isNot(contains('表情29号')));
  });

  test('her own marks parse whatever the case, and up to 40 characters', () {
    final labels = {'TapBody': 'TapBody', '摇摇晃晃转一圈然后跳起来再落下来挥挥手': 'Long'};
    expect(parseCompanionReply('[动作:tapbody]好。', actions: labels).marks.single.name, 'TapBody');
    expect(parseCompanionReply('[动作:摇摇晃晃转一圈然后跳起来再落下来挥挥手]', actions: labels).marks.single.name, 'Long');
    expect(companionMarkLabelFits('x' * 41), isFalse);
    expect(companionMarkLabelFits('a]b'), isFalse);
  });

  test('a numbered label still fits in a mark', () {
    final long = '好' * 40;
    final moves = CompanionMoves.from(CompanionModelInfo(expressions: ['a/$long', 'b/$long']), const {});
    final second = moves.expressions.last.label;
    expect(second, endsWith(' 2'));
    expect(second.length, lessThanOrEqualTo(40));
    expect(companionMarkLabelFits(second), isTrue);
  });
}
