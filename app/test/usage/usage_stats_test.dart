// Anonymous usage statistics end to end on the phone's side, the network
// faked: on by default; each past day once, the day after; back 7 days at
// most; off leaves only Android's daily-activity base row, with its other
// counts and their local data gone; a new install id every 90 days; 3 quiet
// tries a day; a body with exactly the contract's fields; and the counts
// coming from where they happen.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/usage/usage_ledger.dart';
import 'package:dsh_app/usage/usage_net.dart';
import 'package:dsh_app/usage/usage_stats.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const noticed = {UsageStatsController.noticedKey: true};

late FakeUsageHttp http;
late DateTime now;
VoidCallback? resume;

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Future<ProviderContainer> start({
  Map<String, Object> prefs = const {},
  String? engine,
  PhoneChannel? phone,
  UsageDevice phoneFacts = testDevice,
  String? platform,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final container = ProviderContainer(
    overrides: [
      ...usageOverrides(
        clock: () => now,
        http: http,
        onResumes: (onResume) => resume = onResume,
        engine: engine,
        phone: phone,
        device: phoneFacts,
      ),
      if (platform != null) operatingSystemProvider.overrideWithValue(platform),
    ],
  );
  addTearDown(container.dispose);
  container.read(usageStatsProvider);
  await settle();
  return container;
}

extension on ProviderContainer {
  UsageStatsController get usage => read(usageStatsProvider.notifier);

  Future<void> count(UsageCount c, [int times = 1]) async {
    for (var i = 0; i < times; i++) {
      usage.count(c);
    }
    await settle();
  }

  /// Back to the app, the way Android says so.
  Future<void> comeBack() async {
    resume!();
    await settle();
  }
}

/// Answers the first request, then the network is gone.
class _RefusedThenOffline extends FakeUsageHttp {
  @override
  Future<int> post(Uri url, String json, {Duration timeout = const Duration(seconds: 10)}) {
    offline = requests.isNotEmpty;
    return super.post(url, json, timeout: timeout);
  }
}

/// Keeps the first answer until the test gives it.
class _FirstHeld extends FakeUsageHttp {
  final first = Completer<int>();

  @override
  Future<int> post(Uri url, String json, {Duration timeout = const Duration(seconds: 10)}) {
    if (requests.isNotEmpty) return super.post(url, json, timeout: timeout);
    urls.add(url);
    requests.add(jsonDecode(json) as Map<String, Object?>);
    return first.future;
  }
}

Future<Map<String, Object?>> stored() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final k in prefs.getKeys()) k: prefs.get(k)};
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final wasActive = UsageBuild.active;
  setUp(() {
    UsageBuild.active = true;
    http = FakeUsageHttp();
    now = DateTime(2026, 10, 28, 9);
    resume = null;
  });
  tearDown(() => UsageBuild.active = wasActive);

  test('Android daily activity is on by default; off leaves only that, on the same install id', () async {
    now = DateTime.utc(2026, 10, 28, 9);
    final c = await start(platform: 'android');
    await c.count(UsageCount.turns, 2);
    c.usage.chatLogUsage({'inputTokens': 123}, local: false);
    now = now.add(const Duration(days: 1));
    await c.comeBack();
    // The full statistics, without the switch ever having been shown.
    expect(http.urls.any((url) => url.path.endsWith('/v1')), isTrue);
    final v4 = http.requests.indexWhere((body) => body['v'] == 4);
    expect(v4, isNonNegative);
    expect(http.requests[v4]['base'], [1, 1]);
    expect(http.requests[v4]['chat_log'], isNotNull);
    final iid =
        (jsonDecode((await stored())[UsageStatsController.v4LedgerKey] as String) as Map<String, dynamic>)['iid'];

    await c.usage.setEnabled(false);
    await settle();
    final sent = http.requests.length;
    now = now.add(const Duration(days: 1));
    await c.comeBack();
    // The daily-activity package alone: no v1, no tokens, no device model.
    expect(http.requests, hasLength(sent + 1));
    final daily = http.requests.last;
    expect(daily['v'], 4);
    expect(daily['base'], [1, 0]);
    expect(daily.keys, isNot(contains('chat_log')));
    expect(daily.keys, isNot(contains('extra')));
    expect([daily['maker'], daily['model'], daily['rom']], ['', '', '']);
    expect(
      (jsonDecode((await stored())[UsageStatsController.v4LedgerKey] as String) as Map<String, dynamic>)['iid'],
      iid,
    );
  });

  test('on by default: counted and sent even before the switch was ever shown', () async {
    final c = await start();
    expect(c.read(usageStatsProvider).enabled, isTrue, reason: 'on by default');
    await c.count(UsageCount.turns, 3);
    now = DateTime(2026, 10, 29, 9);
    await c.comeBack();
    expect(http.days, ['2026-10-28']);
    expect((http.requests.single['counts']! as Map)['turns'], 3);
  });

  test('a past day goes out once, the day after; today waits for tomorrow', () async {
    final c = await start(prefs: noticed);
    await c.count(UsageCount.turns, 2);
    await c.count(UsageCount.voice);
    await c.comeBack();
    expect(http.requests, isEmpty, reason: 'today is still being counted');

    now = DateTime(2026, 10, 29, 8);
    await c.comeBack();
    await c.comeBack();
    now = DateTime(2026, 10, 29, 22);
    await c.comeBack();
    expect(http.days, ['2026-10-28'], reason: 'one request for the 28th, however often the app comes back');
    expect(http.requests.single['counts'], {'turns': 2, 'voice': 1, 'phone': 0, 'share': 0, 'gen': 0, 'plugins': 0});

    now = DateTime(2026, 10, 30, 8);
    await c.comeBack();
    expect(http.days, ['2026-10-28', '2026-10-29'], reason: 'the 29th was a day in use, with nothing counted');
  });

  test('a cold start sends what is due, at most 7 days back, oldest first', () async {
    final ledger = UsageLedger();
    for (var d = 15; d <= 27; d++) {
      ledger.count(UsageCount.share, DateTime(2026, 10, d, 20));
    }
    final c = await start(prefs: {...noticed, UsageStatsController.daysKey: ledger.encode()});
    expect(http.days, [for (var d = 21; d <= 27; d++) '2026-10-$d']);
    await c.comeBack();
    expect(http.requests, hasLength(7));
    // All sent, nothing older kept; today (in use) is all that is left.
    final left = UsageLedger.decode((await stored())[UsageStatsController.daysKey] as String?);
    expect(left.days.keys, ['2026-10-28']);
  });

  test('off: no request at all, and the install id and every count are gone at once', () async {
    final c = await start(prefs: noticed);
    await c.count(UsageCount.turns, 4);
    now = DateTime(2026, 10, 29, 9);
    await c.comeBack();
    expect(http.requests, hasLength(1));
    final firstId = http.requests.single['iid'];
    await c.count(UsageCount.gen);
    expect((await stored())[UsageStatsController.iidKey], firstId);

    await c.usage.setEnabled(false);
    await settle();
    final prefs = await stored();
    expect(prefs[UsageStatsController.enabledKey], isFalse);
    for (final key in [
      UsageStatsController.iidKey,
      UsageStatsController.iidSinceKey,
      UsageStatsController.daysKey,
      UsageStatsController.failedAtKey,
    ]) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }

    // Days go by with the app in use: still not a single request.
    for (var d = 29; d <= 31; d++) {
      now = DateTime(2026, 10, d, 12);
      await c.count(UsageCount.turns, 2);
      c.usage.plugins(3);
      await c.comeBack();
      await c.usage.send();
    }
    expect(http.requests, hasLength(1));
    expect((await stored()).containsKey(UsageStatsController.daysKey), isFalse);

    // A cold start remembers it is off.
    final again = await start(prefs: Map<String, Object>.from(await stored()));
    expect(again.read(usageStatsProvider).enabled, isFalse);
    now = DateTime(2026, 11, 2, 9);
    await again.comeBack();
    expect(http.requests, hasLength(1));

    // On again: a new id, nothing from before.
    await again.usage.setEnabled(true);
    await again.count(UsageCount.voice);
    now = DateTime(2026, 11, 3, 9);
    await again.comeBack();
    expect(http.requests, hasLength(2));
    expect(http.requests.last['iid'], isNot(firstId));
    expect(http.requests.last['day'], '2026-11-02');
  });

  test('the install id is kept 89 days and replaced on the 90th', () async {
    final c = await start(prefs: noticed);
    final made = DateTime(2026, 10, 29, 9);
    now = made;
    await c.comeBack();
    final first = http.requests.single['iid']! as String;
    expect(first, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));

    now = made.add(const Duration(days: 88));
    await c.comeBack();
    now = made.add(const Duration(days: 89));
    await c.comeBack();
    expect(http.requests.last['iid'], first);

    now = made.add(const Duration(days: 90));
    await c.comeBack();
    expect(http.requests, hasLength(3));
    expect(http.requests.last['iid'], isNot(first));
    expect(http.requests.last['iid'], matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
  });

  test('a failed send: quietly tried again later, 3 tries at most, never in a burst', () async {
    final c = await start(prefs: noticed);
    await c.count(UsageCount.turns);
    now = DateTime(2026, 10, 29, 9);
    await c.count(UsageCount.turns);
    http.offline = true;
    now = DateTime(2026, 10, 30, 9);
    await c.comeBack();
    // Two days due: the round stops at the first failure.
    expect(http.days, ['2026-10-28']);

    // Straight back: too soon to try again.
    await c.comeBack();
    await c.comeBack();
    expect(http.requests, hasLength(1));

    // Too many requests, and a server error: failures too.
    http
      ..offline = false
      ..replies.addAll([429, 503]);
    now = now.add(const Duration(minutes: 11));
    await c.comeBack();
    now = now.add(const Duration(minutes: 11));
    await c.comeBack();
    expect(http.days, ['2026-10-28', '2026-10-28', '2026-10-28']);

    // The 28th is given up after 3; the 29th still has all of its tries.
    http.offline = false;
    now = now.add(const Duration(minutes: 11));
    await c.comeBack();
    expect(http.days, ['2026-10-28', '2026-10-28', '2026-10-28', '2026-10-29']);
    await c.comeBack();
    expect(http.requests, hasLength(4));
  });

  test('400, 413, 415: that day is given up at once; the next one goes in the same round', () async {
    for (final refusal in [400, 413, 415]) {
      http = FakeUsageHttp()..replies.add(refusal);
      final ledger = UsageLedger()
        ..touch(DateTime(2026, 10, 26, 9))
        ..touch(DateTime(2026, 10, 27, 9));
      final c = await start(prefs: {...noticed, UsageStatsController.daysKey: ledger.encode()});
      expect(http.days, ['2026-10-26', '2026-10-27'], reason: '$refusal');
      now = now.add(const Duration(minutes: 30));
      await c.comeBack();
      expect(http.requests, hasLength(2), reason: '$refusal: never tried again');
      final left = UsageLedger.decode((await stored())[UsageStatsController.daysKey] as String?);
      expect(left.days.keys, ['2026-10-28'], reason: '$refusal');
      now = DateTime(2026, 10, 28, 9);
    }
  });

  test('404: the host collects nothing now; not again today, and no try used', () async {
    http.replies.add(404);
    final ledger = UsageLedger()..touch(DateTime(2026, 10, 27, 9));
    final prefs = {...noticed, UsageStatsController.daysKey: ledger.encode()};
    final c = await start(prefs: prefs);
    expect(http.days, ['2026-10-27']);
    for (final later in [const Duration(minutes: 11), const Duration(hours: 6)]) {
      now = DateTime(2026, 10, 28, 9).add(later);
      await c.comeBack();
    }
    expect(http.requests, hasLength(1));
    // A cold start the same day remembers it.
    final again = await start(prefs: Map<String, Object>.from(await stored()));
    await again.comeBack();
    expect(http.requests, hasLength(1));
    // The next day, it goes (with all of its tries).
    now = DateTime(2026, 10, 29, 9);
    await again.comeBack();
    expect(http.days, ['2026-10-27', '2026-10-27', '2026-10-28']);
  });

  test('a body the host would refuse is never sent', () async {
    // No native side: no build number, no ABI.
    final c = await start(
      prefs: noticed,
      phoneFacts: const UsageDevice(app: '0.9.9', sdk: 34, maker: 'vivo'),
    );
    await c.count(UsageCount.turns);
    now = DateTime(2026, 10, 29, 9);
    await c.comeBack();
    expect(http.requests, isEmpty);
    final left = UsageLedger.decode((await stored())[UsageStatsController.daysKey] as String?);
    expect(left.days.keys, ['2026-10-29'], reason: 'the 28th is dropped, not kept for ever');
  });

  test('every body sent passes the host\'s rules', () async {
    final ledger = UsageLedger();
    for (var d = 21; d <= 27; d++) {
      ledger
        ..count(UsageCount.turns, DateTime(2026, 10, d, 10))
        ..engine(d.isEven ? 'direct' : 'proot', DateTime(2026, 10, d, 10))
        ..plugins(d - 20, DateTime(2026, 10, d, 10));
    }
    await start(prefs: {...noticed, UsageStatsController.daysKey: ledger.encode()});
    expect(http.requests, hasLength(7));
    for (final body in http.requests) {
      expect(usageProblem(body, now), isNull, reason: '$body');
      expect(body['iid'], matches(RegExp(r'^[A-Za-z0-9_-]{21}[AQgw]$')));
    }
  });

  const phone = UsageDevice(
    app: '0.9.9',
    build: 10301000,
    sdk: 34,
    abi: 'arm64-v8a',
    maker: 'vivo',
    model: 'v2405a',
    rom: 'originos 5.0',
  );

  test(
    'v3 with the model, system and its counts; a host that refuses it gets v2, then v1, for the rest of the run',
    () async {
      http = FakeUsageHttp()..replies.addAll([400, 400]);
      final ledger = UsageLedger()
        ..touch(DateTime(2026, 10, 26, 9))
        ..touch(DateTime(2026, 10, 27, 9));
      await start(prefs: {...noticed, UsageStatsController.daysKey: ledger.encode()}, phoneFacts: phone);
      expect(
        [for (final r in http.requests) '${r['day']} v${r['v']}'],
        ['2026-10-26 v3', '2026-10-26 v2', '2026-10-26 v1', '2026-10-27 v1'],
      );
      expect(http.requests.first.keys.toSet(), usagePayloadKeysV2);
      expect((http.requests.first['counts']! as Map).keys.toSet(), usageCountKeysV3);
      expect([http.requests.first['model'], http.requests.first['rom']], ['v2405a', 'originos 5.0']);
      expect((http.requests[1]['counts']! as Map).keys.toSet(), usageCountKeys);
      expect(http.requests[2].keys.toSet(), usagePayloadKeys);
      final left = UsageLedger.decode((await stored())[UsageStatsController.daysKey] as String?);
      expect(left.days.keys, ['2026-10-28'], reason: 'both days went out');
    },
  );

  test('a host from before v3 takes v2 for the rest of the run', () async {
    http = FakeUsageHttp()..replies.add(400);
    final ledger = UsageLedger()
      ..touch(DateTime(2026, 10, 26, 9))
      ..touch(DateTime(2026, 10, 27, 9));
    await start(prefs: {...noticed, UsageStatsController.daysKey: ledger.encode()}, phoneFacts: phone);
    expect(
      [for (final r in http.requests) '${r['day']} v${r['v']}'],
      ['2026-10-26 v3', '2026-10-26 v2', '2026-10-27 v2'],
    );
  });

  test('off and on again while a v3 send waits: its 400 sends nothing from before again', () async {
    final held = _FirstHeld();
    http = held;
    final ledger = UsageLedger()..touch(DateTime(2026, 10, 26, 9));
    final c = await start(prefs: {...noticed, UsageStatsController.daysKey: ledger.encode()}, phoneFacts: phone);
    expect(held.requests, hasLength(1));
    await c.usage.setEnabled(false);
    await c.usage.setEnabled(true);
    await settle();
    held.first.complete(400);
    await settle();
    expect(held.requests, hasLength(1), reason: 'the old id and day are gone');
  });

  test('no answer to the lower contract is a failed send, not a refusal', () async {
    http = _RefusedThenOffline()..replies.add(400);
    final ledger = UsageLedger()..touch(DateTime(2026, 10, 26, 9));
    await start(prefs: {...noticed, UsageStatsController.daysKey: ledger.encode()}, phoneFacts: phone);
    expect([for (final r in http.requests) '${r['day']} v${r['v']}'], ['2026-10-26 v3', '2026-10-26 v2']);
    final left = UsageLedger.decode((await stored())[UsageStatsController.daysKey] as String?);
    expect(left.days['2026-10-26']?.tries, 1, reason: 'kept for another try');
  });

  test('the tavern, the room, calls and tokens go out in v3', () async {
    final c = await start(prefs: noticed, phoneFacts: phone);
    await c.count(UsageCount.tavern, 3);
    await c.count(UsageCount.room);
    await c.count(UsageCount.call, 2);
    c.usage
      ..tokens(1500, 200)
      ..tokens(500, 50);
    await settle();
    now = DateTime(2026, 10, 29, 9);
    await c.comeBack();
    final counts = http.requests.single['counts']! as Map<String, Object?>;
    expect(http.requests.single['v'], 3);
    expect(
      {
        for (final key in ['tavern', 'room', 'call', 'tok_in', 'tok_out']) key: counts[key],
      },
      {'tavern': 3, 'room': 1, 'call': 2, 'tok_in': 2000, 'tok_out': 250},
    );
  });

  test('the request: the endpoint, and nothing but the contract\'s fields', () async {
    final c = await start(prefs: noticed, engine: 'direct');
    await c.count(UsageCount.turns, 5);
    await c.count(UsageCount.voice, 2);
    await c.count(UsageCount.share);
    await c.count(UsageCount.gen);
    c.usage.plugins(3);
    await settle();
    now = DateTime(2026, 10, 29, 9);
    await c.comeBack();

    expect(http.urls.single, Uri.parse('https://go.dshtui.com/api/usage/v1'));
    final body = http.requests.single;
    expect(body.keys.toSet(), usagePayloadKeys);
    final counts = body['counts']! as Map<String, Object?>;
    expect(counts.keys.toSet(), usageCountKeys);
    expect(body, {
      'v': 1,
      'iid': body['iid'],
      'day': '2026-10-28',
      'app': '0.9.9',
      'build': 10301000,
      'sdk': 34,
      'abi': 'arm64-v8a',
      'maker': 'vivo',
      'lang': 'zh',
      'engine': 'direct',
      'counts': {'turns': 5, 'voice': 2, 'phone': 0, 'share': 1, 'gen': 1, 'plugins': 3},
    });
    // Nothing in it reads like content or an identifier of the phone.
    final text = jsonEncode(body);
    for (final word in ['model', 'android_id', 'imei', 'serial', 'host', 'key', 'token', 'text']) {
      expect(text.toLowerCase(), isNot(contains('"$word')), reason: word);
    }
  });

  test('a day the engine did not run says none', () async {
    final c = await start(prefs: noticed);
    now = DateTime(2026, 10, 29, 9);
    await c.comeBack();
    expect(http.requests.single['engine'], 'none');
  });

  test('phone control: each task counts once, when it starts', () async {
    final phone = FakePhone();
    final c = await start(prefs: noticed, phone: phone);
    PhoneStatus task(bool active, int id) => PhoneStatus(
      task: PhoneTaskStatus(id: id, active: active),
    );
    for (final s in [task(true, 1), task(true, 1), task(false, 1), task(true, 2), task(true, 3), task(false, 3)]) {
      phone.pushes.add(s);
      await settle();
    }
    now = DateTime(2026, 10, 29, 9);
    await c.comeBack();
    expect((http.requests.single['counts']! as Map)['phone'], 3);
  });

  test('phoneTaskStarted: a new number or active again', () {
    const idle = PhoneTaskStatus();
    expect(phoneTaskStarted(idle, const PhoneTaskStatus(active: true)), isTrue);
    expect(phoneTaskStarted(const PhoneTaskStatus(active: true), const PhoneTaskStatus(active: true)), isFalse);
    expect(
      phoneTaskStarted(const PhoneTaskStatus(id: 1, active: true), const PhoneTaskStatus(id: 2, active: true)),
      isTrue,
    );
    expect(phoneTaskStarted(const PhoneTaskStatus(id: 1, active: true), const PhoneTaskStatus(id: 1)), isFalse);
  });

  test('debug builds and tests count nothing and send nothing', () async {
    final c = await start(prefs: noticed);
    UsageBuild.active = false;
    await c.count(UsageCount.turns);
    now = DateTime(2026, 10, 29, 9);
    await c.usage.foreground();
    expect(http.requests, isEmpty);
  });
}
