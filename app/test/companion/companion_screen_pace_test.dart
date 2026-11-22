import 'package:dsh_app/companion/companion_screen_pace.dart';
import 'package:flutter_test/flutter_test.dart';

// These exercise the real local policy with explicit display/user events.
// They do not assert a real overlay acknowledgement, model call, or device capture.
CompanionScreenReading reading({
  double salience = .9,
  bool busy = false,
  String scene = 'other',
  String quip = '这一步很稳',
}) =>
    CompanionScreenReading(scene: scene, mood: 'calm', salience: salience, busy: busy, quip: quip, emotion: 'neutral');

void main() {
  test('only acknowledged lines back off and a newer user reply resets them', () {
    final beforeAnyScreenLine = CompanionScreenPace()
      ..cheapStarted(0)
      ..userSpoke(1000);
    expect(beforeAnyScreenLine.cheapDue(23999), isFalse);
    expect(
      beforeAnyScreenLine.cheapDue(24000),
      isTrue,
      reason: 'any recent real user reply applies, without a prior screen line',
    );
    beforeAnyScreenLine.cheapStarted(120000);
    expect(beforeAnyScreenLine.cheapDue(144000), isFalse, reason: 'the recent-user factor expires after two minutes');
    expect(beforeAnyScreenLine.cheapDue(150000), isTrue);
    final pace = CompanionScreenPace();
    expect(pace.cheapDue(1000), isTrue);
    pace.cheapStarted(1000);
    expect(pace.unanswered, 0);
    expect(pace.cheapDue(30999), isFalse);
    expect(pace.cheapDue(31000), isTrue);
    pace.shown(1000, reading(), quip: true);
    pace.shown(2000, reading(), quip: true);
    expect(pace.unanswered, 2);
    expect(pace.cheapDue(45999), isFalse);
    expect(pace.cheapDue(46000), isTrue);
    pace.shown(3000, reading(), quip: true);
    expect(pace.cheapDue(60999), isFalse);
    expect(pace.cheapDue(61000), isTrue);
    for (final at in [4000, 5000, 6000]) {
      pace.shown(at, reading(), quip: true);
    }
    expect(pace.cheapDue(90999), isFalse);
    expect(pace.cheapDue(91000), isTrue);
    pace.userSpoke(7000);
    expect(pace.unanswered, 0);
    pace.cheapStarted(7000);
    expect(pace.cheapDue(30999), isFalse);
    expect(pace.cheapDue(31000), isTrue, reason: 'recent genuine reply applies the 0.8 factor');
    pace.shown(8000, reading(), quip: true);
    pace.userSpoke(7000);
    expect(pace.unanswered, 1, reason: 'the same old user timestamp is not a new reply');
  });

  test('serious turns respect salience, busy, recent user and three-minute gates', () {
    final pace = CompanionScreenPace();
    expect(pace.seriousDue(100000, reading(salience: .85), userBusy: false), isFalse);
    expect(pace.seriousDue(100000, reading(salience: .86), userBusy: false), isTrue);
    expect(pace.seriousDue(100000, reading(salience: .94), userBusy: true), isFalse);
    expect(pace.seriousDue(100000, reading(salience: .95), userBusy: true), isTrue);
    expect(pace.seriousDue(100000, reading(busy: true), userBusy: false), isFalse);
    pace.userSpoke(100000);
    expect(pace.seriousDue(109999, reading(salience: 1), userBusy: false), isFalse);
    expect(pace.seriousDue(110000, reading(), userBusy: false), isTrue);
    pace.seriousStarted(110000);
    expect(pace.seriousDue(289999, reading(), userBusy: false), isFalse);
    expect(pace.seriousDue(290000, reading(), userBusy: false), isTrue);
    pace.observed(reading(scene: 'idle'));
    expect(pace.seriousDue(469999, reading(), userBusy: false), isFalse);
    expect(pace.seriousDue(470000, reading(), userBusy: false), isTrue);
  });

  test('short structured readings and recent similar quips are bounded', () {
    final value = <String, Object?>{
      'scene': 'coding',
      'mood': 'calm',
      'salience': .9,
      'busy': false,
      'quip': '这一步很稳',
      'emotion': 'neutral',
    };
    final decoded = CompanionScreenReading.parse(value)!;
    expect(decoded.scene, 'coding');
    expect(CompanionScreenReading.parse({...value, 'salience': double.nan}), isNull);
    expect(CompanionScreenReading.parse({...value, 'busy': 'false'}), isNull);
    expect(CompanionScreenReading.parse({...value, 'quip': List.filled(21, '字').join()}), isNull);
    expect(CompanionScreenReading.parse({...value, 'quip': List.filled(20, '字').join()}), isNotNull);
    final pace = CompanionScreenPace();
    expect(pace.quipIsNew(decoded.quip), isTrue);
    pace.shown(1000, decoded, quip: true);
    expect(pace.quipIsNew('这一步，很稳！'), isFalse);
    expect(pace.quipIsNew('这一步很稳呀'), isFalse);
    expect(pace.quipIsNew('等这一局结束再聊'), isTrue);
  });
}
