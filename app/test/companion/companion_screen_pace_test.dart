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
  test('glances follow the chosen frequency; only quiet backs off, and a newer user reply resets it', () {
    final beforeAnyScreenLine = CompanionScreenPace()
      ..cheapStarted(0)
      ..userSpoke(1000);
    expect(beforeAnyScreenLine.cheapDue(15999), isFalse);
    expect(
      beforeAnyScreenLine.cheapDue(16000),
      isTrue,
      reason: 'any recent real user reply applies, without a prior screen line',
    );
    beforeAnyScreenLine.cheapStarted(120000);
    expect(beforeAnyScreenLine.cheapDue(136000), isFalse, reason: 'the recent-user factor expires after two minutes');
    expect(beforeAnyScreenLine.cheapDue(140000), isTrue);
    final pace = CompanionScreenPace()..frequency = 'quiet';
    expect(pace.cheapDue(1000), isTrue);
    pace.cheapStarted(1000);
    expect(pace.unanswered, 0);
    expect(pace.cheapDue(60999), isFalse);
    expect(pace.cheapDue(61000), isTrue);
    pace.shown(1000, reading(), quip: true);
    pace.shown(2000, reading(), quip: true);
    expect(pace.unanswered, 2);
    expect(pace.cheapDue(75999), isFalse);
    expect(pace.cheapDue(76000), isTrue);
    for (final at in [3000, 4000, 5000, 6000]) {
      pace.shown(at, reading(), quip: true);
    }
    expect(pace.cheapDue(120999), isFalse);
    expect(pace.cheapDue(121000), isTrue, reason: 'unanswered lines slow her to twice at most');
    pace.frequency = 'live';
    expect(pace.cheapDue(5999), isFalse);
    expect(pace.cheapDue(6000), isTrue, reason: 'only quiet backs off');
    pace.frequency = 'quiet';
    pace.userSpoke(7000);
    expect(pace.unanswered, 0);
    pace.cheapStarted(7000);
    expect(pace.cheapDue(54999), isFalse);
    expect(pace.cheapDue(55000), isTrue, reason: 'recent genuine reply applies the 0.8 factor');
    pace.shown(8000, reading(), quip: true);
    pace.userSpoke(7000);
    expect(pace.unanswered, 1, reason: 'the same old user timestamp is not a new reply');
  });

  test('each frequency sets its aside gap and salience, and whether busy matters', () {
    final pace = CompanionScreenPace();
    expect(pace.seriousDue(100000, reading(salience: .69), userBusy: false), isFalse);
    expect(pace.seriousDue(100000, reading(salience: .7), userBusy: false), isTrue);
    expect(pace.seriousDue(100000, reading(salience: .84), userBusy: true), isFalse);
    expect(pace.seriousDue(100000, reading(salience: .85), userBusy: true), isTrue);
    expect(pace.seriousDue(100000, reading(salience: .8, busy: true), userBusy: false), isFalse);
    expect(pace.waitsForIdle(reading(salience: .8)), isTrue);
    pace.userSpoke(100000);
    expect(pace.seriousDue(102999, reading(salience: 1), userBusy: false), isFalse);
    expect(pace.seriousDue(103000, reading(), userBusy: false), isTrue);
    pace.seriousStarted(103000);
    expect(pace.seriousDue(150999, reading(), userBusy: false), isFalse);
    expect(pace.seriousDue(151000, reading(), userBusy: false), isTrue, reason: 'a recent reply applies 0.8');

    final live = CompanionScreenPace()..frequency = 'live';
    expect(live.seriousDue(0, reading(salience: .49), userBusy: false), isFalse);
    expect(live.seriousDue(0, reading(salience: .5, busy: true), userBusy: true), isTrue, reason: 'live never waits');
    expect(live.waitsForIdle(reading(salience: .5)), isFalse);
    live.seriousStarted(0);
    for (final (frequency, gap) in [('live', 12000), ('chatty', 30000), ('normal', 60000), ('quiet', 180000)]) {
      live.frequency = frequency;
      expect(live.seriousDue(gap - 1, reading(salience: 1), userBusy: false), isFalse, reason: frequency);
      expect(live.seriousDue(gap, reading(salience: 1), userBusy: false), isTrue, reason: frequency);
    }
    live.frequency = 'quiet';
    expect(live.seriousDue(180000, reading(salience: .79), userBusy: false), isFalse);
    live.frequency = 'chatty';
    expect(live.seriousDue(180000, reading(salience: .6, busy: true), userBusy: true), isTrue);
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
    final long = CompanionScreenReading.parse({...value, 'quip': List.filled(31, '字').join()})!;
    expect(long.quip, isEmpty, reason: 'only the quip too long for her bubble is dropped');
    expect(long.scene, 'coding');
    expect(CompanionScreenReading.parse({...value, 'quip': List.filled(30, '字').join()})!.quip.runes, hasLength(30));
    final pace = CompanionScreenPace();
    expect(pace.quipIsNew(decoded.quip), isTrue);
    pace.shown(1000, decoded, quip: true);
    expect(pace.quipIsNew('这一步，很稳！'), isFalse);
    expect(pace.quipIsNew('这一步很稳呀'), isFalse);
    expect(pace.quipIsNew('等这一局结束再聊'), isTrue);
  });
}
