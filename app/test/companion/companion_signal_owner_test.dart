import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_initiative_owner.dart';
import 'package:dsh_client/companion.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Clock {
  int wall = DateTime.utc(2026, 11, 5, 8).millisecondsSinceEpoch;
  int mono = 0;
  CompanionInitiativeClock call() => CompanionInitiativeClock(wallMs: wall, monoMs: mono);
}

class Room implements CompanionInitiativeRoom {
  bool Function(CompanionInitiativeTicket)? onCan;
  void Function(CompanionInitiativeDisplay)? onShow;
  final shown = <CompanionInitiativeDisplay>[];
  final hidden = <String>[];
  @override
  bool canPresent(CompanionInitiativeTicket t) => t.kind != CompanionPromptKind.greeting && (onCan?.call(t) ?? true);
  @override
  void show(CompanionInitiativeDisplay d) {
    shown.add(d);
    onShow?.call(d);
  }

  @override
  void hide(String id) => hidden.add(id);
  @override
  void retime(String id, int? at) {}
  @override
  void rest(CompanionInitiativeEffect effect) {}
}

CompanionInitiativeView view({String key = 'room', bool blocked = false, bool accessible = false}) =>
    CompanionInitiativeView(
      visible: true,
      resumed: true,
      blocked: blocked,
      enabled: true,
      accessible: accessible,
      contextKey: key,
    );
CompanionInitiativeSignal candidate(Clock clock, {String id = 'signal', int ttl = 120000}) =>
    CompanionInitiativeSignal(id: id, contextKey: 'room', expiresAtMonoMs: clock.mono + ttl);
Database? _database;
CompanionMemoryStore? _memory;

Future<CompanionInitiative> make(WidgetTester tester, Clock clock) async {
  final owner = CompanionInitiative(clock.call);
  _database ??= sqlite3.openInMemory();
  _memory ??= CompanionMemoryStore(_database!, nowMilliseconds: () => clock.wall);
  await tester.runAsync(() => owner.attachMemory(_memory!));
  return owner;
}

Future<void> pass(WidgetTester tester, Clock clock, int ms) async {
  var remaining = ms;
  while (remaining > 0) {
    final amount = remaining > 1000 ? 1000 : remaining;
    clock.wall += amount;
    clock.mono += amount;
    await tester.pump(Duration(milliseconds: amount));
    remaining -= amount;
  }
}

Map<String, Object?> saved() => _memory!.initiativeRecord()!;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _database = null;
    _memory = null;
  });
  tearDown(() => _memory?.close());

  testWidgets('B03 preparation waits for the real quiet offer and reserves only after a fresh observation', (
    tester,
  ) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final ready = Completer<bool>();
    var preparations = 0;
    var renders = 0;
    Object? stateBeforeRender;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      prepare: () {
        preparations++;
        return ready.future;
      },
      present: (_) {
        stateBeforeRender = _database!.select('SELECT state FROM memory_initiative_spends').single['state'];
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 44000);
    expect(preparations, 0);
    await pass(tester, clock, 2000);
    expect(preparations, 1);
    expect(_database!.select('SELECT * FROM memory_initiative_spends'), isEmpty);
    owner.observe(room, view());
    owner.observe(room, view());
    expect(preparations, 1);
    ready.complete(true);
    await tester.pump();
    expect(renders, 1);
    expect(stateBeforeRender, 'reserved');
    expect(saved()['signalAtMs'], hasLength(1));
    owner.dispose();
  });

  testWidgets('B03 failed preparation retires its offer so another real signal can present', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final ready = Completer<bool>();
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      prepare: () => ready.future,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 46000);
    ready.complete(false);
    await tester.pump();
    expect(renders, 0);
    expect(saved()['signalAtMs'], isEmpty);
    owner.requestSignal(
      room,
      view(),
      candidate(clock, id: 'other'),
      isCurrent: () => true,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await tester.pump();
    expect(renders, 1);
    expect(saved()['signalAtMs'], hasLength(1));
    owner.dispose();
  });

  testWidgets('B03 leaving during preparation discards the completed wording without a reservation', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final ready = Completer<bool>();
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      prepare: () => ready.future,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 46000);
    owner.leave(room);
    ready.complete(true);
    await tester.pump();
    expect(renders, 0);
    expect(_database!.select('SELECT * FROM memory_initiative_spends'), isEmpty);
    owner.dispose();
  });

  testWidgets('signal cannot accept an invitation but can decline into the shared refusal', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final shown = <CompanionInitiativeDisplay>[];
    final hidden = <String>[];
    MemoryRow? beforeRender;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (d) {
        beforeRender = Map<String, Object?>.from(
          _database!.select('SELECT kind,state FROM memory_initiative_spends').single,
        );
        shown.add(d);
        return true;
      },
      hide: hidden.add,
    );
    await pass(tester, clock, 46000);
    expect(
      beforeRender,
      containsPair('state', 'reserved'),
      reason: 'the actual render happens after the durable reservation',
    );
    final id = shown.single.ticket.id;
    expect(owner.accept(room, id, view()), isFalse);
    expect(hidden, isEmpty);
    expect(owner.decline(room, id, view()), isTrue);
    expect(hidden, [id]);
    expect(owner.decline(room, id, view()), isFalse);
    final ledger = saved();
    expect(ledger['declinedUntilMs'], clock.wall + CompanionInitiativeRules.inviteGapMs);
    expect(ledger['signalAtMs'], [shown.single.committedAtWallMs]);
    owner.requestSignal(
      room,
      view(),
      candidate(clock, id: 'next'),
      isCurrent: () => true,
      present: (d) {
        shown.add(d);
        return true;
      },
      hide: hidden.add,
    );
    await pass(tester, clock, 46000);
    expect(shown, hasLength(1));
    owner.dispose();
  });

  testWidgets('last current callback crosses 23:00 and fresh staging rejects the ordinary signal', (tester) async {
    final clock = Clock()..wall = DateTime.utc(2026, 11, 5, 22, 59, 14).millisecondsSinceEpoch;
    final owner = await make(tester, clock);
    final room = Room();
    var cross = false;
    var renders = 0;
    room.onCan = (ticket) {
      cross = ticket.kind == CompanionPromptKind.signal;
      return true;
    };
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () {
        if (cross) {
          cross = false;
          clock.wall += 2000;
          clock.mono += 2000;
        }
        return true;
      },
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 46000);
    expect(renders, 0);
    expect(saved()['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('metadata failure after rendering hides the display and keeps its shared spend', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    room.onShow = (_) => _database!.execute("""
        CREATE TRIGGER fail_metadata BEFORE UPDATE ON memory_initiative_state
        BEGIN SELECT RAISE(ABORT,'fixture'); END
      """);
    try {
      owner.enter(room, view());
      await pass(tester, clock, 46000);
      expect(room.shown, hasLength(1));
      expect(room.hidden, [room.shown.single.ticket.id]);
      expect(saved()['inviteAtMs'], hasLength(1));
      expect(_database!.select('SELECT state FROM memory_initiative_spends').single['state'], 'shown');
      expect(owner.fault, 'storage-failed');
      _database!.execute('DROP TRIGGER fail_metadata');
      owner.observe(room, view());
      await pass(tester, clock, 46000);
      expect(room.shown, hasLength(1));
      expect(owner.fault, 'storage-failed');
    } finally {
      owner.dispose();
    }
  });

  testWidgets('unbounded observer reentrancy closes after a bounded queue drain', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    var checks = 0;
    room.onCan = (_) {
      checks++;
      owner.observe(room, view());
      return true;
    };
    owner.enter(room, view());
    await pass(tester, clock, 46000);
    expect(checks, inInclusiveRange(1, 64));
    expect(owner.fault, 'storage-failed');
    expect(room.shown, isEmpty);
    owner.dispose();
  });

  testWidgets('actual local signal display commits exactly once without inviting too', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final displays = <CompanionInitiativeDisplay>[];
    final hides = <String>[];
    owner.enter(room, view());
    expect(
      owner.requestSignal(
        room,
        view(),
        candidate(clock),
        isCurrent: () => true,
        present: (d) {
          displays.add(d);
          return true;
        },
        hide: hides.add,
      ),
      isTrue,
    );
    await pass(tester, clock, 46000);
    expect(displays, hasLength(1));
    expect(room.shown, isEmpty);
    final ledger = saved();
    expect(ledger['signalAtMs'], [displays.single.committedAtWallMs]);
    expect(ledger['inviteAtMs'], isEmpty);
    await pass(tester, clock, 8000);
    expect(hides, [displays.single.ticket.id]);
    owner.dispose();
  });

  for (final throws in [false, true]) {
    testWidgets('actual presentation ${throws ? 'throw retains an unknown spend' : 'false releases its reservation'}', (
      tester,
    ) async {
      final clock = Clock();
      final owner = await make(tester, clock);
      final room = Room();
      var attempts = 0;
      final hides = <String>[];
      owner.enter(room, view());
      owner.requestSignal(
        room,
        view(),
        candidate(clock),
        isCurrent: () => true,
        present: (_) {
          attempts++;
          if (throws) throw StateError('partial render');
          return false;
        },
        hide: hides.add,
      );
      await pass(tester, clock, 46000);
      expect(attempts, 1);
      expect(hides, hasLength(1));
      final ledger = saved();
      expect(ledger['signalAtMs'], throws ? hasLength(1) : isEmpty);
      expect(ledger['inviteAtMs'], isEmpty);
      expect(
        _database!.select('SELECT state FROM memory_initiative_spends').single['state'],
        throws ? 'unknown' : 'released',
      );
      expect(owner.fault, isNull);
      owner.dispose();
    });
  }

  testWidgets('source withdrawn while waiting is retired before rendering', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    var current = true;
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => current,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 30000);
    current = false;
    owner.observe(room, view());
    await pass(tester, clock, 16000);
    expect(renders, 0);
    expect(saved()['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('isCurrent reentrant room replacement cannot resurrect the old recipient', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final newer = Room();
    var replace = false;
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () {
        if (replace) {
          replace = false;
          owner.enter(newer, view(key: 'new'));
        }
        return true;
      },
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    replace = true;
    await pass(tester, clock, 46000);
    expect(renders, 0);
    expect(saved()['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('canPresent reentrant source cancellation is checked again before presentation', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    var renders = 0;
    room.onCan = (ticket) {
      if (ticket.kind == CompanionPromptKind.signal) owner.cancelSignal('signal');
      return true;
    };
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 46000);
    expect(renders, 0);
    expect(saved()['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('true display followed by reentrant leave remains charged and hides captured receiver', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final signalHides = <String>[];
    final displayed = <CompanionInitiativeDisplay>[];
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (d) {
        displayed.add(d);
        owner.leave(room);
        return true;
      },
      hide: signalHides.add,
    );
    await pass(tester, clock, 46000);
    expect(displayed, hasLength(1));
    expect(signalHides, [displayed.single.ticket.id]);
    expect(room.hidden, isEmpty);
    expect(saved()['signalAtMs'], [displayed.single.committedAtWallMs]);
    owner.dispose();
  });

  testWidgets('original gate expiry is retained across repeated observations', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock, ttl: 30000),
      isCurrent: () => true,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 20000);
    owner.observe(room, view());
    await pass(tester, clock, 26000);
    expect(renders, 0);
    expect(saved()['signalAtMs'], isEmpty);
    owner.dispose();
  });

  testWidgets('a restored invitation consumes the signal gap and survives owner restart', (tester) async {
    final clock = Clock();
    SharedPreferences.setMockInitialValues({
      companionInitiativeKey: jsonEncode({
        'v': 1,
        'lastGreetingAtMs': clock.wall,
        'inviteAtMs': [clock.wall - 1000],
        'declinedUntilMs': 0,
      }),
    });
    for (var attempt = 0; attempt < 2; attempt++) {
      final owner = await make(tester, clock);
      final room = Room();
      var renders = 0;
      owner.enter(room, view());
      owner.requestSignal(
        room,
        view(),
        candidate(clock),
        isCurrent: () => true,
        present: (_) {
          renders++;
          return true;
        },
        hide: (_) {},
      );
      await pass(tester, clock, 46000);
      expect(renders, 0);
      final ledger = saved();
      expect(ledger['inviteAtMs'], hasLength(1));
      expect(ledger['signalAtMs'], isEmpty);
      expect(owner.fault, isNull);
      owner.dispose();
      SharedPreferences.setMockInitialValues({companionInitiativeKey: 'stale corrupt key after migration'});
    }
  });

  testWidgets('an invitation render that throws keeps an unknown shared spend', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    room.onShow = (_) => throw StateError('invitation render failed');
    owner.enter(room, view());
    await pass(tester, clock, 46000);
    expect(room.shown, hasLength(1));
    expect(room.hidden, hasLength(1));
    expect(saved()['inviteAtMs'], hasLength(1));
    expect(_database!.select('SELECT state FROM memory_initiative_spends').single['state'], 'unknown');
    owner.dispose();
  });

  testWidgets('a settlement write failure hides a real display and retains the reserved debit', (tester) async {
    final clock = Clock();
    final owner = await make(tester, clock);
    final room = Room();
    final shown = <CompanionInitiativeDisplay>[];
    final hidden = <String>[];
    _database!.execute("""
      CREATE TRIGGER fail_settlement BEFORE UPDATE ON memory_initiative_spends
      BEGIN SELECT RAISE(ABORT,'fixture'); END
    """);
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (display) {
        shown.add(display);
        return true;
      },
      hide: hidden.add,
    );
    await pass(tester, clock, 46000);
    expect(shown, hasLength(1));
    expect(hidden, [shown.single.ticket.id]);
    expect(owner.fault, 'storage-failed');
    expect(_database!.select('SELECT state FROM memory_initiative_spends').single['state'], 'reserved');
    expect(saved()['signalAtMs'], hasLength(1));
    owner.dispose();
  });

  testWidgets('default local night blocks ordinary signal presentation', (tester) async {
    final clock = Clock()..wall = DateTime.utc(2026, 11, 5, 23).millisecondsSinceEpoch;
    final owner = await make(tester, clock);
    final room = Room();
    var renders = 0;
    owner.enter(room, view());
    owner.requestSignal(
      room,
      view(),
      candidate(clock),
      isCurrent: () => true,
      present: (_) {
        renders++;
        return true;
      },
      hide: (_) {},
    );
    await pass(tester, clock, 46000);
    expect(renders, 0);
    expect(saved()['signalAtMs'], isEmpty);
    owner.dispose();
  });
}
