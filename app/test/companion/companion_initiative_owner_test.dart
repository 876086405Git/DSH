import 'dart:convert';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_app/companion/companion_elapsed_clock.dart';
import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Both clocks, moved by the test together with the fake timers.
class _Clock {
  int wall = DateTime.utc(2026, 11, 5, 10, 30).millisecondsSinceEpoch;
  int mono = 0;
  int offset = 0;
  int Function()? elapsed;

  CompanionInitiativeClock call() =>
      CompanionInitiativeClock(wallMs: wall, monoMs: elapsed?.call() ?? mono, offsetMinutes: offset);
}

class _Room implements CompanionInitiativeRoom {
  bool presentable = true;
  final offered = <CompanionInitiativeTicket>[];
  final shown = <CompanionInitiativeDisplay>[];
  final hidden = <String>[];
  final rests = <CompanionInitiativeEffect>[];
  final retimed = <int?>[];

  /// Offered invitations; a welcome is offered too on a new visit, and dropped.
  Iterable<CompanionInitiativeTicket> get invites => offered.where((t) => t.kind == CompanionPromptKind.invite);

  @override
  bool canPresent(CompanionInitiativeTicket ticket) {
    offered.add(ticket);
    return presentable && ticket.kind == CompanionPromptKind.invite;
  }

  @override
  void show(CompanionInitiativeDisplay display) => shown.add(display);

  @override
  void hide(String ticketId) => hidden.add(ticketId);

  @override
  void retime(String ticketId, int? expiresAtMono) => retimed.add(expiresAtMono);

  @override
  void rest(CompanionInitiativeEffect intent) => rests.add(intent);
}

CompanionInitiativeView _view({
  bool visible = true,
  bool resumed = true,
  bool blocked = false,
  bool enabled = true,
  bool accessible = false,
  String key = 'room-a',
}) => CompanionInitiativeView(
  visible: visible,
  resumed: resumed,
  blocked: blocked,
  enabled: enabled,
  accessible: accessible,
  contextKey: key,
);

late CompanionMemoryStore _memory;

Future<CompanionInitiative> _owner(WidgetTester tester, _Clock clock) async {
  final container = ProviderContainer(overrides: [companionInitiativeClockProvider.overrideWithValue(clock.call)]);
  addTearDown(container.dispose);
  final owner = container.read(companionInitiativeProvider);
  _memory = CompanionMemoryStore(sqlite3.openInMemory(), nowMilliseconds: () => clock.wall);
  addTearDown(_memory.close);
  await tester.runAsync(() => owner.attachMemory(_memory));
  return owner;
}

/// Time passes for the clocks and the timers alike, a second at a time.
Future<void> _pass(
  WidgetTester tester,
  _Clock clock,
  Duration time, {
  Duration step = const Duration(seconds: 1),
}) async {
  var left = time;
  while (left > Duration.zero) {
    final d = left < step ? left : step;
    clock
      ..wall += d.inMilliseconds
      ..mono += d.inMilliseconds;
    await tester.pump(d);
    left -= d;
  }
}

Map<String, Object?>? _ledger() => _memory.initiativeRecord();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('C907 a 06:59 quiet room wakes at 07:00 without another observation', (tester) async {
    final clock = _Clock()..wall = DateTime.utc(2026, 11, 5, 6, 59).millisecondsSinceEpoch;
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 59));
    expect(room.invites, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 1));
    expect(owner.fault, isNull);
    expect(room.invites, hasLength(1));
    await _pass(tester, clock, const Duration(minutes: 1));
    expect(room.invites, hasLength(1));
    owner.dispose();
  });

  testWidgets('C907 activation before 07:00 still cancels the quiet invitation', (tester) async {
    final clock = _Clock()..wall = DateTime.utc(2026, 11, 5, 6, 59).millisecondsSinceEpoch;
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 50));
    owner.activate(room);
    await _pass(tester, clock, const Duration(minutes: 2));
    expect(room.invites, isEmpty);
    owner.dispose();
  });

  testWidgets('C907 quiet time that completes after 23:00 waits until next 07:00', (tester) async {
    final clock = _Clock()..wall = DateTime.utc(2026, 11, 5, 22, 59, 30).millisecondsSinceEpoch;
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 60));
    expect(room.invites, isEmpty);
    await _pass(tester, clock, const Duration(hours: 7, minutes: 59, seconds: 29), step: const Duration(minutes: 30));
    expect(room.invites, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 1));
    expect(owner.fault, isNull);
    expect(room.invites, hasLength(1));
    owner.dispose();
  });

  testWidgets('C907 dawn follows the observed local offset', (tester) async {
    final clock = _Clock()
      ..wall = DateTime.utc(2026, 11, 4, 22, 59).millisecondsSinceEpoch
      ..offset = 480;
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 59));
    expect(room.invites, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 1));
    expect(owner.fault, isNull);
    expect(room.invites, hasLength(1));
    owner.dispose();
  });

  testWidgets('C907 a quota that reopens at night waits until daytime', (tester) async {
    final clock = _Clock()..wall = DateTime.utc(2026, 11, 5, 22, 30).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      companionInitiativeKey: jsonEncode({
        'v': 1,
        'lastGreetingAtMs': null,
        'inviteAtMs': [DateTime.utc(2026, 11, 5, 17, 30).millisecondsSinceEpoch],
        'declinedUntilMs': 0,
      }),
    });
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(hours: 8, minutes: 29, seconds: 59), step: const Duration(minutes: 30));
    expect(room.invites, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 1));
    expect(owner.fault, isNull);
    expect(room.invites, hasLength(1));
    owner.dispose();
  });

  testWidgets('C907 an unrepresentable future quota stays closed without calendar overflow', (tester) async {
    SharedPreferences.setMockInitialValues({
      companionInitiativeKey: jsonEncode({
        'v': 1,
        'lastGreetingAtMs': null,
        'inviteAtMs': [],
        'declinedUntilMs': 9007199254740991,
      }),
    });
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(minutes: 1));
    expect(owner.fault, isNull);
    expect(room.invites, isEmpty);
    owner.dispose();
  });

  testWidgets('C907 injected Android boot time survives sleep while uptime stops', (tester) async {
    final clock = _Clock();
    var uptimeReads = 0;
    final elapsed = CompanionElapsedClock(
      android: true,
      bootTimeMilliseconds: () => clock.mono,
      stopwatchMilliseconds: () {
        uptimeReads++;
        return 0;
      },
    );
    clock.elapsed = elapsed.readMilliseconds;
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    owner.observe(room, _view(resumed: false));
    // Model Android deep sleep: wall and BOOTTIME advance, uptime remains zero.
    // This is an injected lifecycle test, not a hardware suspend measurement.
    clock
      ..wall += 120000
      ..mono += 120000;
    await tester.pump(const Duration(minutes: 2));
    owner.observe(room, _view());
    expect(owner.fault, isNull);
    expect(room.invites, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 45));
    expect(room.invites, hasLength(1));
    expect(uptimeReads, 0);
    owner.dispose();
  });

  for (final jump in [-2000, 2000]) {
    testWidgets('C907 a real wall jump of $jump ms remains permanently closed', (tester) async {
      final clock = _Clock();
      final elapsed = CompanionElapsedClock(android: true, bootTimeMilliseconds: () => clock.mono);
      clock.elapsed = elapsed.readMilliseconds;
      final owner = await _owner(tester, clock);
      final room = _Room();
      owner.enter(room, _view());
      clock.wall += jump;
      owner.observe(room, _view());
      expect(owner.fault, 'clock-invalid-or-regressed');
      await _pass(tester, clock, const Duration(minutes: 1));
      owner.observe(room, _view());
      expect(owner.fault, 'clock-invalid-or-regressed');
      expect(room.invites, isEmpty);
      owner.dispose();
    });
  }

  testWidgets('C907 initial native clock failure closes owner and completes ready', (tester) async {
    final clock = _Clock()..elapsed = () => -1;
    final owner = await _owner(tester, clock);
    expect(owner.fault, 'clock-unavailable');
    final room = _Room();
    owner.enter(room, _view());
    clock.elapsed = null;
    await _pass(tester, clock, const Duration(minutes: 1));
    expect(owner.fault, 'clock-unavailable');
    expect(room.offered, isEmpty);
  });

  testWidgets('C907 native failure after display retires it without fallback', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    expect(room.shown, hasLength(1));
    clock.elapsed = () => throw StateError('native read unavailable');
    owner.observe(room, _view());
    expect(owner.fault, 'clock-unavailable');
    expect(room.hidden, [room.shown.single.ticket.id]);
    clock.elapsed = null;
    await _pass(tester, clock, const Duration(minutes: 1));
    owner.observe(room, _view());
    expect(room.shown, hasLength(1));
  });

  testWidgets('C907 native failure in quiet wake closes without rearming', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 44));
    clock.elapsed = () => -1;
    await _pass(tester, clock, const Duration(seconds: 1));
    expect(owner.fault, 'clock-unavailable');
    expect(room.invites, isEmpty);
    await _pass(tester, clock, const Duration(minutes: 1));
    expect(room.invites, isEmpty);
  });

  testWidgets('after 45 s of quiet she invites once; it goes by itself after 8 s and is kept', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    expect(owner.fault, isNull);
    final room = _Room();
    owner.enter(room, _view());

    await _pass(tester, clock, const Duration(seconds: 44));
    expect(room.shown, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 2));
    expect(room.shown, hasLength(1));
    final display = room.shown.single;
    expect(display.ticket.kind, CompanionPromptKind.invite);
    expect(display.expiresAtMono, isNotNull);

    final ledger = _ledger();
    expect(ledger?['inviteAtMs'], [display.committedAtWallMs]);

    await _pass(tester, clock, const Duration(seconds: 9));
    expect(room.hidden, [display.ticket.id]);
    // One per visit: a long quiet afterwards brings no second one.
    await _pass(tester, clock, const Duration(minutes: 5), step: const Duration(seconds: 30));
    expect(room.shown, hasLength(1));
    owner.dispose();
  });

  testWidgets('anything the person does first means no invitation this visit', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 30));
    owner.activate(room);
    await _pass(tester, clock, const Duration(minutes: 3), step: const Duration(seconds: 5));
    expect(room.invites, isEmpty);
    expect(room.shown, isEmpty);
    owner.dispose();
  });

  testWidgets('only an unbroken quiet stretch counts', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 40));
    // Her words on screen for a while: the stretch starts over after them.
    owner.observe(room, _view(blocked: true));
    await _pass(tester, clock, const Duration(seconds: 10));
    owner.observe(room, _view());
    await _pass(tester, clock, const Duration(seconds: 40));
    expect(room.shown, isEmpty);
    await _pass(tester, clock, const Duration(seconds: 6));
    expect(room.shown, hasLength(1));
    owner.dispose();
  });

  testWidgets('a room that can not show it drops it; nothing is spent', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room()..presentable = false;
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 50));
    expect(room.invites, hasLength(1));
    expect(room.shown, isEmpty);
    final unspent = _ledger();
    expect(unspent?['inviteAtMs'], isEmpty);
    expect(unspent?['signalAtMs'], isEmpty);
    expect(unspent?['lastGreetingAtMs'], isNull);
    expect(unspent?['night'], isNotNull); // First observed offset is durable.
    owner.dispose();
  });

  testWidgets('switched off: none; a screen reader holds it until answered', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view(enabled: false));
    await _pass(tester, clock, const Duration(seconds: 50));
    expect(room.invites, isEmpty);

    owner.observe(room, _view(accessible: true));
    await _pass(tester, clock, const Duration(seconds: 46));
    expect(room.shown, hasLength(1));
    expect(room.shown.single.expiresAtMono, isNull);
    await _pass(tester, clock, const Duration(seconds: 30));
    expect(room.hidden, isEmpty);

    // The reader goes away: from now, the usual few seconds.
    owner.observe(room, _view());
    expect(room.retimed.single, isNotNull);
    await _pass(tester, clock, const Duration(seconds: 9));
    expect(room.hidden, hasLength(1));
    owner.dispose();
  });

  testWidgets('not now: hidden, and six quiet hours are kept on the phone', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    final id = room.shown.single.ticket.id;

    expect(owner.decline(room, id, _view()), isTrue);
    expect(room.hidden, [id]);
    expect(room.rests, isEmpty);
    final ledger = _ledger();
    expect(ledger?['declinedUntilMs'], clock.wall + CompanionInitiativeRules.inviteGapMs);
    // A second tap on a button already gone answers nothing.
    expect(owner.decline(room, id, _view()), isFalse);
    owner.dispose();
  });

  testWidgets('yes: one rest for the room, however often it is tapped', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    final display = room.shown.single;

    expect(owner.accept(room, display.ticket.id, _view()), isTrue);
    expect(owner.accept(room, display.ticket.id, _view()), isFalse);
    expect(room.rests, hasLength(1));
    expect(room.rests.single.ticketId, display.ticket.id);
    expect(room.rests.single.contextKey, 'room-a');
    expect(room.hidden, [display.ticket.id]);
    owner.dispose();
  });

  testWidgets('a yes after the room changed reaches nothing', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    final id = room.shown.single.ticket.id;

    // Light → full: the button belongs to the room before.
    expect(owner.accept(room, id, _view(key: 'room-b')), isFalse);
    expect(room.rests, isEmpty);
    expect(room.hidden, [id]);
    owner.dispose();
  });

  testWidgets('after a no, the next visit waits out the six hours before asking again', (tester) async {
    final clock = _Clock();
    final owner = await _owner(tester, clock);
    final room = _Room();
    owner.enter(room, _view());
    await _pass(tester, clock, const Duration(seconds: 46));
    owner.decline(room, room.shown.single.ticket.id, _view());
    owner.leave(room);

    // Back after an hour: a new visit, but still inside the six hours.
    await _pass(tester, clock, const Duration(hours: 1), step: const Duration(minutes: 10));
    final again = _Room();
    owner.enter(again, _view(key: 'room-c'));
    await _pass(tester, clock, const Duration(hours: 4), step: const Duration(minutes: 10));
    expect(again.shown, isEmpty);
    // The wakeup lands when the six hours are up, not before.
    await _pass(tester, clock, const Duration(hours: 1, minutes: 10), step: const Duration(minutes: 10));
    expect(again.shown, hasLength(1));
    owner.dispose();
  });

  testWidgets('a ledger it can not read closes invitations and is left as it was', (tester) async {
    for (final saved in ['not json', '{"v":1,"lastGreetingAtMs":null,"inviteAtMs":[],"declinedUntilMs":0,"x":1}']) {
      SharedPreferences.setMockInitialValues({companionInitiativeKey: saved});
      final clock = _Clock();
      final owner = await _owner(tester, clock);
      expect(owner.fault, isNotNull, reason: saved);
      final room = _Room();
      owner.enter(room, _view());
      await _pass(tester, clock, const Duration(seconds: 50));
      expect(room.invites, isEmpty, reason: saved);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(companionInitiativeKey), saved);
      owner.leave(room);
      owner.dispose();
    }
  });

  testWidgets('the switch is on until turned off, and stays as set', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(companionInitiativeEnabledProvider), isNull);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(container.read(companionInitiativeEnabledProvider), isTrue);
    await tester.runAsync(() => container.read(companionInitiativeEnabledProvider.notifier).set(false));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('companion_initiative_enabled'), isFalse);
  });

  testWidgets('the pace is the original one until another is picked, and stays as picked', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(companionInitiativePaceProvider), CompanionInitiativePace.rare);
    await tester.runAsync(
      () => container.read(companionInitiativePaceProvider.notifier).set(CompanionInitiativePace.chatty),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('companion_initiative_pace'), 'chatty');
    final again = ProviderContainer();
    addTearDown(again.dispose);
    again.read(companionInitiativePaceProvider);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    expect(again.read(companionInitiativePaceProvider), CompanionInitiativePace.chatty);
  });
}
