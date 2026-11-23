import 'dart:async';
import 'dart:io';

import 'package:dsh_app/companion/companion_notice_triage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// In-memory replacement for the native owner, including destructive take and
/// epoch rejection. Tests can replace companionNoticesProvider with this object.
class FakeCompanionNotices implements CompanionNotices {
  final events = StreamController<int>.broadcast(sync: true);
  final levels = {'a': CompanionNoticeLevel.remember, 'b': CompanionNoticeLevel.glance};
  final inbox = <({String pkg, String key, int atMs, String text})>[];
  bool enabled = true, granted = true, unlocked = true;
  int consentEpoch = 1, epoch = 1, judged = 0, said = 0, received = 0;

  void post(String pkg, String key, DateTime at, String text) {
    inbox.add((pkg: pkg, key: key, atMs: at.millisecondsSinceEpoch, text: text));
    received++;
    events.add(epoch);
  }

  void lock() {
    unlocked = false;
    inbox.clear();
    events.add(++epoch);
  }

  @override
  Stream<int> get signals => events.stream;
  @override
  Future<CompanionNoticeStatus> status() async => CompanionNoticeStatus(
    enabled: enabled,
    granted: granted,
    unlocked: unlocked,
    levels: Map.of(levels),
    received: received,
    judged: judged,
    said: said,
    epoch: epoch,
    consentEpoch: consentEpoch,
  );
  @override
  Future<CompanionNoticeStatus> setEnabled(bool value) async {
    enabled = value;
    consentEpoch++;
    events.add(++epoch);
    return status();
  }

  @override
  Future<CompanionNoticeStatus> setLevel(String pkg, CompanionNoticeLevel level) async {
    levels[pkg] = level;
    consentEpoch++;
    events.add(++epoch);
    return status();
  }

  @override
  Future<List<CompanionNoticeApp>> recentApps() async => [];
  @override
  Future<List<CompanionNoticePending>> pending() async => [
    for (final p in inbox) (pkg: p.pkg, key: p.key, atMs: p.atMs),
  ];
  @override
  Future<CompanionNoticeBatch?> takeBatch(String pkg, List<String> keys, int expected) async {
    if (expected != epoch || !unlocked || !enabled || !granted) return null;
    final selected = inbox.where((p) => p.pkg == pkg && keys.contains(p.key)).toList();
    inbox.removeWhere(selected.contains);
    return CompanionNoticeBatch(
      pkg: pkg,
      appName: pkg,
      level: levels[pkg]!,
      epoch: epoch,
      consentEpoch: consentEpoch,
      items: [
        for (final p in selected) (key: p.key, segments: [(text: p.text, atMs: p.atMs, personId: null)]),
      ],
    );
  }

  @override
  Future<bool> record(int expected, {int judged = 0, int said = 0}) async {
    if (expected != epoch || !unlocked || !enabled || !granted) return false;
    this.judged += judged;
    this.said += said;
    return true;
  }
}

class _Model implements CompanionNoticeModelTransport {
  final calls = <CompanionNoticeBatch>[];
  Completer<void>? block;
  bool fail = false;
  int cancellations = 0;
  @override
  bool configured = true;

  @override
  void cancel() => cancellations++;
  @override
  Future<List<CompanionNoticeDecision>> classify(
    CompanionNoticeBatch batch, {
    required bool Function() current,
    required Future<bool> Function() authorize,
    required bool Function() reserve,
    required String Function(String kind, String value) fingerprint,
  }) async {
    if (!await authorize() || !reserve()) {
      throw const CompanionNoticeFailure('cancelled');
    }
    calls.add(batch);
    if (block != null) await block!.future;
    if (fail) throw const CompanionNoticeFailure('model_network');
    return [
      CompanionNoticeDecision(
        action: CompanionNoticeAction.say,
        pkg: batch.pkg,
        appName: batch.appName,
        text: '稍后取件。',
        key: batch.items.first.key,
        eventId: 'event',
        personId: null,
        atMs: batch.items.first.segments.first.atMs,
        epoch: batch.epoch,
        consentEpoch: batch.consentEpoch,
        offerReply: false,
      ),
    ];
  }
}

void main() {
  late DateTime clock;
  late CompanionNoticeRate rate;
  late FakeCompanionNotices channel;
  late _Model model;
  late CompanionNoticeTriage triage;
  late List<String> failures;
  late List<CompanionNoticeDecision> delivered;
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  setUp(() {
    clock = DateTime(2026, 11, 23, 10);
    channel = FakeCompanionNotices();
    model = _Model();
    rate = CompanionNoticeRate(sqlite3.openInMemory());
    failures = [];
    delivered = [];
    triage = CompanionNoticeTriage(
      channel: channel,
      rate: rate,
      model: model,
      now: () => clock,
      deliver: delivered.add,
      onFailure: failures.add,
    );
  });

  tearDown(() async {
    await triage.close();
    await channel.events.close();
  });

  test('first arrival opens a 20 second same-app window and each request takes at most eight keys', () async {
    for (var i = 0; i < 9; i++) {
      channel.post('a', 'a$i', clock, '消息$i');
    }
    triage.start();
    clock = clock.add(const Duration(seconds: 19));
    channel.post('b', 'b0', clock, '稍后来信');
    channel.post('a', 'a9', clock, '同一 App 的晚到消息');
    await flush();
    expect(model.calls, isEmpty);
    clock = clock.add(const Duration(seconds: 1));
    triage.wake();
    await flush();
    expect(model.calls.map((batch) => batch.items.length), [8, 2]);
    expect(model.calls.every((batch) => batch.pkg == 'a'), isTrue);
    expect(channel.judged, 10);
    expect(channel.said, 0);
    expect(channel.inbox.single.pkg, 'b');
  });

  test('failure discards taken originals and delays only new work', () async {
    triage.start();
    channel.post('a', 'old', clock.subtract(const Duration(minutes: 1)), '只尝试一次');
    model.fail = true;
    await flush();
    expect(failures, ['model_network']);
    expect(channel.judged, 0);
    expect(channel.inbox, isEmpty);
    model.fail = false;
    channel.post('a', 'new', clock, '后来的一条');
    clock = clock.add(const Duration(seconds: 119));
    triage.wake();
    await flush();
    expect(model.calls, hasLength(1));
    clock = clock.add(const Duration(seconds: 1));
    triage.wake();
    await flush();
    expect(model.calls.last.items.single.key, 'new');
    expect(channel.judged, 1);
  });

  test('lock during a physical call cancels it and retires even a late successful result', () async {
    model.block = Completer<void>();
    channel.post('a', 'key', clock.subtract(const Duration(minutes: 1)), '测试资料');
    triage.start();
    await flush();
    expect(model.calls, hasLength(1));
    channel.lock();
    model.block!.complete();
    await flush();
    expect(model.cancellations, 1);
    expect(delivered, isEmpty);
    expect(channel.judged, 0);
  });

  test('unconfigured model keeps native custody until the credential changes', () async {
    model.configured = false;
    channel.post('a', 'key', clock.subtract(const Duration(minutes: 1)), '测试资料');
    triage.start();
    await flush();
    expect(channel.inbox, hasLength(1));
    model.configured = true;
    triage.wake();
    await flush();
    expect(channel.judged, 1);
  });

  test('cooldown, backoff, event digest and daily request cap survive reopen', () async {
    final folder = await Directory.systemTemp.createTemp('notice-rate-');
    var ledger = CompanionNoticeRate.open(folder.path);
    try {
      final stable = ledger.fingerprint('event/a', '示例');
      expect(ledger.reserve(clock, ['key']), isTrue);
      expect(ledger.reserve(clock, ['key']), isFalse);
      for (var n = 1; n < 300; n++) {
        expect(ledger.reserve(clock, ['key-$n']), isTrue);
      }
      ledger.close();
      ledger = CompanionNoticeRate.open(folder.path);
      expect(ledger.fingerprint('event/a', '示例'), stable);
      expect(ledger.cooldowns(clock)['key'], clock.add(const Duration(minutes: 2)).millisecondsSinceEpoch);
      expect(ledger.reserve(clock, ['301']), isFalse);
      clock = DateTime(clock.year, clock.month, clock.day + 1);
      expect(ledger.reserve(clock, ['301']), isTrue);
      for (final expected in [2, 5, 15, 30, 30]) {
        final retry = clock.add(Duration(minutes: expected));
        expect(ledger.failed(clock), retry.millisecondsSinceEpoch);
        ledger.close();
        ledger = CompanionNoticeRate.open(folder.path);
        expect(ledger.availableAt(clock), retry.millisecondsSinceEpoch);
        clock = retry;
      }
      ledger.succeeded();
      expect(ledger.failed(clock), clock.add(const Duration(minutes: 2)).millisecondsSinceEpoch);
    } finally {
      ledger.close();
      await folder.delete(recursive: true);
    }
  });
}
