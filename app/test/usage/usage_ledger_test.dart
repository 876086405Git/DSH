// The usage ledger on its own: which days are due, how far back, how many
// tries, and a request body with exactly the contract's fields.

import 'dart:convert';
import 'dart:math';

import 'package:dsh_app/usage/usage_ledger.dart';
import 'package:flutter_test/flutter_test.dart';

// Fixed UTC fixtures keep the host retention boundary independent of the test machine's zone.
DateTime _at(int day, [int hour = 12]) => DateTime.utc(2026, 10, day, hour);

void main() {
  test('a day is the local date, zero-padded', () {
    expect(usageDay(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
    expect(usageDay(DateTime(2026, 10, 30)), '2026-10-30');
  });

  test('counts go to the day they happen on; today is never due', () {
    final ledger = UsageLedger()
      ..count(UsageCount.turns, _at(28))
      ..count(UsageCount.turns, _at(28, 23))
      ..count(UsageCount.voice, _at(29, 0));
    expect(ledger.days['2026-10-28']![UsageCount.turns], 2);
    expect(ledger.days['2026-10-29']![UsageCount.voice], 1);
    expect(ledger.due(_at(29)), ['2026-10-28']);
    expect(ledger.due(_at(30)), ['2026-10-28', '2026-10-29']);
  });

  test('a day in use with nothing counted is still a day (daily actives)', () {
    final ledger = UsageLedger()..touch(_at(28));
    expect(ledger.due(_at(29)), ['2026-10-28']);
    expect(ledger.days['2026-10-28']![UsageCount.turns], 0);
  });

  test('back 7 days at most, oldest first; older days are dropped', () {
    final ledger = UsageLedger();
    for (var d = 10; d <= 27; d++) {
      ledger.touch(_at(d));
    }
    // Keep this seven-day case on the same date as the UTC+8 share host.
    final due = ledger.due(DateTime.utc(2026, 10, 28));
    expect(due, [for (var d = 21; d <= 27; d++) '2026-10-$d']);
    expect(ledger.days.keys.toSet(), due.toSet());
  });

  test('the 7 days are calendar days across a month end', () {
    final ledger = UsageLedger()
      ..touch(DateTime(2026, 10, 25))
      ..touch(DateTime(2026, 10, 26));
    expect(ledger.due(DateTime(2026, 11, 2)), ['2026-10-26']);
  });

  test('sent is gone for good; a failure costs one of 3 tries', () {
    final ledger = UsageLedger()
      ..touch(_at(27))
      ..touch(_at(28));
    ledger.sent('2026-10-27');
    expect(ledger.due(_at(29)), ['2026-10-28']);
    ledger.failed('2026-10-28');
    ledger.failed('2026-10-28');
    expect(ledger.due(_at(29)), ['2026-10-28']);
    ledger.failed('2026-10-28');
    expect(ledger.due(_at(29)), isEmpty);
    expect(ledger.days, isEmpty);
  });

  test('plugins: the last count of the day; a new day starts from it', () {
    final ledger = UsageLedger()
      ..plugins(3, _at(27))
      ..plugins(2, _at(27, 18))
      ..touch(_at(28));
    expect(ledger.days['2026-10-27']!.plugins, 2);
    expect(ledger.days['2026-10-28']!.plugins, 2);
  });

  test('engine: only direct or proot, the last one seen that day', () {
    final ledger = UsageLedger()
      ..engine('proot', _at(27))
      ..engine('direct', _at(27, 13))
      ..engine('weird', _at(27, 14))
      ..touch(_at(28));
    expect(ledger.days['2026-10-27']!.engine, 'direct');
    expect(ledger.days['2026-10-28']!.engine, isNull);
  });

  test('survives a round trip, and garbage reads as empty', () {
    final ledger = UsageLedger()
      ..count(UsageCount.share, _at(27))
      ..engine('proot', _at(27))
      ..plugins(4, _at(27))
      ..failed('2026-10-27');
    ledger.failed('2026-10-27');
    final back = UsageLedger.decode(ledger.encode());
    expect(back.days['2026-10-27']![UsageCount.share], 1);
    expect(back.days['2026-10-27']!.engine, 'proot');
    expect(back.days['2026-10-27']!.plugins, 4);
    expect(back.days['2026-10-27']!.tries, 2);
    expect(back.lastPlugins, 4);
    for (final bad in [null, '', '{', '[]', '{"days": {"x": {}}}', '{"days": {"2026-10-27": 3}}']) {
      expect(UsageLedger.decode(bad).days, isEmpty, reason: '$bad');
    }
  });

  test('an install id is 128 random bits in base64url, no padding', () {
    final ids = {for (var i = 0; i < 50; i++) newUsageIid()};
    expect(ids, hasLength(50));
    for (final id in ids) {
      expect(id, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(base64Url.decode('$id=='), hasLength(16));
    }
    expect(newUsageIid(Random(1)), newUsageIid(Random(1)));
  });

  test('the body: exactly the contract fields, counts included', () {
    final record = UsageDayRecord(counts: {UsageCount.turns: 5, UsageCount.gen: 1}, plugins: 2, engine: 'direct');
    final body = usagePayload(
      iid: 'AAAAAAAAAAAAAAAAAAAAAA',
      day: '2026-10-30',
      record: record,
      device: const UsageDevice(app: '0.9.9', build: 10301000, sdk: 34, abi: 'arm64-v8a', maker: 'vivo'),
      lang: 'zh',
    );
    expect(body.keys.toSet(), usagePayloadKeys);
    expect((body['counts']! as Map).keys.toSet(), usageCountKeys);
    expect(jsonDecode(jsonEncode(body)), {
      'v': 1,
      'iid': 'AAAAAAAAAAAAAAAAAAAAAA',
      'day': '2026-10-30',
      'app': '0.9.9',
      'build': 10301000,
      'sdk': 34,
      'abi': 'arm64-v8a',
      'maker': 'vivo',
      'lang': 'zh',
      'engine': 'direct',
      'counts': {'turns': 5, 'voice': 0, 'phone': 0, 'share': 0, 'gen': 1, 'plugins': 2},
    });
    expect(
      usagePayload(iid: 'x', day: 'd', record: UsageDayRecord(), device: const UsageDevice(), lang: 'en')['engine'],
      'none',
    );
  });

  test('a count over the share host\'s ceiling goes as the ceiling', () {
    final record = UsageDayRecord(counts: {UsageCount.turns: 9000, UsageCount.share: 1200}, plugins: 700);
    final body = usagePayload(iid: 'x', day: 'd', record: record, device: const UsageDevice(), lang: 'zh');
    expect(body['counts'], {'turns': 5000, 'voice': 0, 'phone': 0, 'share': 1000, 'gen': 0, 'plugins': 500});
  });

  test('a phone behind UTC+8 never sends a day the share host thinks too old', () {
    // 20:00 UTC on the 28th is the 29th in UTC+8: the host takes the 22nd on.
    final now = DateTime.utc(2026, 10, 28, 20);
    final ledger = UsageLedger();
    for (var d = 20; d <= 27; d++) {
      ledger.touch(DateTime.utc(2026, 10, d, 12));
    }
    expect(ledger.due(now), [for (var d = 22; d <= 27; d++) '2026-10-$d']);
  });

  group('the share host\'s rules (docs/design/share-links.md §15)', () {
    // 09:00 on the 30th in UTC+8, whatever zone the test runs in.
    final now = DateTime.utc(2026, 10, 30, 1);
    Map<String, Object?> good() => usagePayload(
      iid: newUsageIid(),
      day: '2026-10-29',
      record: UsageDayRecord(counts: {UsageCount.turns: 3}, plugins: 1, engine: 'proot'),
      device: const UsageDevice(app: '0.9.9', build: 10301000, sdk: 34, abi: 'arm64-v8a', maker: 'vivo'),
      lang: 'zh',
    );
    Map<String, Object?> with_(String key, Object? value) => {...good(), key: value};
    Map<String, Object?> counts(String key, Object? value) => {
      ...good(),
      'counts': {...(good()['counts']! as Map<String, Object?>), key: value},
    };

    test('a body the app builds passes', () {
      for (var i = 0; i < 50; i++) {
        expect(usageProblem(good(), now), isNull);
      }
      for (final engine in ['direct', 'proot', 'none']) {
        expect(usageProblem(with_('engine', engine), now), isNull);
      }
      for (final abi in usageAbis) {
        expect(usageProblem(with_('abi', abi), now), isNull);
      }
      expect(usageProblem(with_('app', '1.0.0-rc.1'), now), isNull);
      expect(usageProblem(with_('lang', 'zh-Hant'), now), isNull);
      expect(usageProblem(with_('maker', 'hmd global'), now), isNull);
    });

    test('one field more or less is refused', () {
      expect(usageProblem({...good(), 'model': 'V2309A'}, now), 'model');
      for (final key in usagePayloadKeys) {
        expect(usageProblem({...good()}..remove(key), now), key);
      }
      expect(usageProblem(counts('tokens', 1), now), 'counts.tokens');
      final missing = {...(good()['counts']! as Map<String, Object?>)}..remove('gen');
      expect(usageProblem({...good(), 'counts': missing}, now), 'counts.gen');
    });

    test('each field by its rule', () {
      final cases = <String, List<Object?>>{
        'v': [4, 0, '1', null],
        'iid': ['short', 'AAAAAAAAAAAAAAAAAAAAAB', 'AAAAAAAAAAAAAAAAAAAA+A', 7],
        'day': ['2026-10-30x', '2026-02-30', '2026-10-21', '2026-11-01', 20261029],
        'app': ['0.9.9+10301000', 'v0.9.9', '0.9', ''],
        'build': [0, -1, 2100000001, 1.5, '10301000'],
        'sdk': [25, 61, '34'],
        'abi': ['arm64', 'mips', ''],
        'maker': ['', ' vivo', '-vivo', 'vivo!', 'x' * 33, '华为'],
        'lang': ['zh_CN', 'Z', 'english', ''],
        'engine': ['Direct', 'chroot', ''],
      };
      for (final MapEntry(:key, value: bad) in cases.entries) {
        for (final v in bad) {
          expect(usageProblem(with_(key, v), now), key, reason: '$key = $v');
        }
      }
      // From 7 days back (UTC+8) to tomorrow.
      expect(usageProblem(with_('day', '2026-10-23'), now), isNull);
      expect(usageProblem(with_('day', '2026-10-31'), now), isNull);
      for (final MapEntry(:key, value: limit) in usageCountLimits.entries) {
        expect(usageProblem(counts(key, limit), now), isNull, reason: key);
        expect(usageProblem(counts(key, limit + 1), now), 'counts.$key');
        expect(usageProblem(counts(key, -1), now), 'counts.$key');
        expect(usageProblem(counts(key, 1.5), now), 'counts.$key');
      }
    });

    test('v2 and v3: the model and system, both or neither; v3 adds its counts', () {
      const phone = UsageDevice(
        app: '0.9.9',
        build: 10301000,
        sdk: 34,
        abi: 'arm64-v8a',
        maker: 'vivo',
        model: 'v2405a',
        rom: 'originos 5.0',
      );
      final record = UsageDayRecord(
        counts: {UsageCount.turns: 2, UsageCount.tavern: 9000, UsageCount.room: 2, UsageCount.call: 1},
        tokensIn: 3000000000,
        tokensOut: 4567,
      );
      Map<String, Object> body({int version = usageContract, UsageDevice device = phone}) => usagePayload(
        iid: 'AAAAAAAAAAAAAAAAAAAAAA',
        day: '2026-10-29',
        record: record,
        device: device,
        lang: 'zh',
        version: version,
      );
      final v3 = body();
      expect(v3['v'], 3);
      expect(v3.keys.toSet(), usagePayloadKeysV2);
      expect(usageProblem(v3, now), isNull);
      // Each at most its ceiling.
      expect(v3['counts'], {
        'turns': 2,
        'voice': 0,
        'phone': 0,
        'share': 0,
        'gen': 0,
        'plugins': 0,
        'tavern': 5000,
        'room': 2,
        'call': 1,
        'tok_in': 2000000000,
        'tok_out': 4567,
      });
      final v2 = body(version: 2);
      expect(v2['v'], 2);
      expect(v2.keys.toSet(), usagePayloadKeysV2);
      expect((v2['counts']! as Map).keys.toSet(), usageCountKeys);
      expect([v2['model'], v2['rom']], ['v2405a', 'originos 5.0']);
      expect(usageProblem(v2, now), isNull);
      // Asked for v1, or no facts from the native side: v1 exactly.
      for (final v1 in [
        body(version: 1),
        body(
          device: const UsageDevice(app: '0.9.9', build: 1, sdk: 34, abi: 'x86', maker: 'vivo'),
        ),
      ]) {
        expect(v1['v'], 1);
        expect(v1.keys.toSet(), usagePayloadKeys);
        expect((v1['counts']! as Map).keys.toSet(), usageCountKeys);
      }
      expect(usageProblem({...v3}..remove('rom'), now), 'rom');
      expect(usageProblem({...v3, 'model': '华为'}, now), 'model');
      expect(usageProblem({...v3, 'rom': ''}, now), 'rom');
      expect(usageProblem({...body(version: 1), 'v': 2}, now), 'model');
      // v3's counts only in v3, and all of them there.
      expect(usageProblem({...v2, 'v': 3}, now), 'counts.tavern');
      expect(usageProblem({...v3, 'v': 2}, now), 'counts.tavern');
      Map<String, Object?> v3Counts(String key, Object? value) => {
        ...v3,
        'counts': {...(v3['counts']! as Map<String, Object?>), key: value},
      };
      for (final MapEntry(:key, value: limit) in {...usageCountLimits, ...usageCountLimitsV3}.entries) {
        expect(usageProblem(v3Counts(key, limit), now), isNull, reason: key);
        expect(usageProblem(v3Counts(key, limit + 1), now), 'counts.$key');
        expect(usageProblem(v3Counts(key, -1), now), 'counts.$key');
      }
    });

    test('tokens add up, from reported numbers only', () {
      final ledger = UsageLedger()
        ..tokens(1200, 300, _at(28))
        ..tokens(0, 0, _at(28))
        ..tokens(-5, 10, _at(28))
        ..tokens(800, 0, _at(28, 23));
      final day = ledger.days['2026-10-28']!;
      expect([day.tokensIn, day.tokensOut], [2000, 310]);
      // Kept across a restart.
      final back = UsageLedger.decode(ledger.encode()).days['2026-10-28']!;
      expect([back.tokensIn, back.tokensOut], [2000, 310]);
      // Nothing reported: no day is made for it.
      expect((UsageLedger()..tokens(0, 0, _at(28))).days, isEmpty);
    });

    test('makers are cut to what the host takes, as UsagePlugin.kt does', () {
      expect(usageMaker('vivo'), 'vivo');
      expect(usageMaker('HMD Global'), 'hmd global');
      expect(usageMaker('Asus+'), 'asus');
      expect(usageMaker('_Lenovo'), 'lenovo');
      expect(usageMaker('  -OnePlus'), 'oneplus');
      expect(usageMaker('Nothing (London)'), 'nothing london');
      expect(usageMaker('华为'), 'unknown');
      expect(usageMaker(''), 'unknown');
      expect(usageMaker('a' * 40), hasLength(32));
      for (final raw in ['Sony Mobile Communications Inc.', 'x' * 80, ' . ', 'ZTE']) {
        expect(usageProblem(with_('maker', usageMaker(raw)), now), isNull, reason: raw);
      }
    });

    test('what each answer means', () {
      expect(UsageReply.of(204), UsageReply.sent);
      expect(UsageReply.of(200), UsageReply.sent);
      for (final s in [400, 413, 415]) {
        expect(UsageReply.of(s), UsageReply.refused, reason: '$s');
      }
      expect(UsageReply.of(404), UsageReply.closed);
      for (final s in [null, 429, 500, 502, 503, 301, 401, 403]) {
        expect(UsageReply.of(s), UsageReply.later, reason: '$s');
      }
    });
  });
}
